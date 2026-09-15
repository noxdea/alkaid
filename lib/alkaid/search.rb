# frozen_string_literal: true

require "thread"
require_relative "search_worker"
require_relative "search_pool"

module Alkaid
  class Search
    DEFAULT_MAX_FILE_SIZE = 16 * 1024 * 1024

    def initialize(root, pattern:, regexp: false, ignore_case: false, whole_word: false,
      include: [], exclude: [], ignore: nil, workers: 4, max_file_size: DEFAULT_MAX_FILE_SIZE,
      max_matches: nil, follow_symlinks: false, hidden: false, max_depth: nil,
      extensions: nil, paths: nil, cancelled: nil)
      validate_options(pattern, include, exclude, ignore, workers, max_file_size, max_matches, extensions, paths,
        cancelled, regexp, ignore_case, whole_word, follow_symlinks, hidden)
      @root = File.realpath(root)
      raise ArgumentError, "root must be a directory" unless File.directory?(@root)

      @expression, @timeout = expression(pattern, regexp, ignore_case, whole_word)
      @include = include.map(&:dup).map(&:freeze).freeze
      @exclude = exclude.map(&:dup).map(&:freeze).freeze
      @workers = workers
      @max_file_size = [max_file_size || SearchWorker::MAX_FILE_BYTES, SearchWorker::MAX_FILE_BYTES].min
      @max_matches = max_matches
      @extensions = extensions&.map { |extension| (extension.start_with?(".") ? extension.dup : ".#{extension}").freeze }&.freeze
      @paths = paths&.map(&:dup)&.map(&:freeze)&.freeze
      @external_cancelled = cancelled
      @walker = Walker.new(@root, ignore: ignore, follow_symlinks: follow_symlinks, hidden: hidden,
        max_depth: max_depth, cancelled: method(:cancelled?))
      @mutex = Mutex.new
      @progress = Progress.new(files_scanned: 0, bytes_scanned: 0, matches: 0)
      @cancelled = false
      @running = false
    end

    def run
      started = false
      begin_run
      started = true
      files = search_paths
      return [] if files.empty?

      results = []
      receive = receiver(results) { |match| yield match if block_given? }
      if @workers > 1 && files.length > 1
        parallel(files, [@workers, files.length].min, &receive)
      else
        SearchWorker.scan(@root, files, @expression, @max_file_size, @max_matches,
          cancelled: method(:cancelled?), &receive)
      end
      SearchWorker.check_cancelled(method(:cancelled?))
      results
    rescue SearchWorker::Cancelled
      []
    ensure
      @mutex.synchronize { @running = false } if started
    end

    def cancel
      @mutex.synchronize { @cancelled = true }
      nil
    end

    def progress = @mutex.synchronize { @progress }

    private

    def validate_options(pattern, includes, excludes, ignore, workers, max_file_size, max_matches, extensions, paths,
      cancelled, *flags)
      raise ArgumentError, "pattern must be a String or Regexp" unless pattern.is_a?(String) || pattern.is_a?(Regexp)
      raise ArgumentError, "pattern must use a valid encoding" if pattern.is_a?(String) && !pattern.valid_encoding?
      raise ArgumentError, "search flags must be boolean" unless flags.all? { |value| value == true || value == false }
      raise ArgumentError, "workers must be between 1 and 32" unless workers.is_a?(Integer) && workers.between?(1, 32)
      if max_file_size && (!max_file_size.is_a?(Integer) || max_file_size.negative?)
        raise ArgumentError, "max_file_size must be nonnegative"
      end
      if max_matches && (!max_matches.is_a?(Integer) || !max_matches.positive?)
        raise ArgumentError, "max_matches must be positive"
      end
      raise ArgumentError, "ignore must respond to ignored?" if ignore && !ignore.respond_to?(:ignored?)
      raise ArgumentError, "cancelled must respond to call" if cancelled && !cancelled.respond_to?(:call)

      {include: includes, exclude: excludes, extensions: extensions, paths: paths}.each do |name, values|
        next if values.nil?
        unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.valid_encoding? && !value.include?("\0") }
          raise ArgumentError, "#{name} must contain valid strings"
        end
      end
    end

    def expression(pattern, regexp, ignore_case, whole_word)
      source = pattern.is_a?(Regexp) || regexp ? pattern.to_s : Regexp.escape(pattern)
      source = pattern.source if pattern.is_a?(Regexp)
      source = "\\b(?:#{source})\\b" if whole_word
      options = pattern.is_a?(Regexp) ? pattern.options : 0
      options |= Regexp::IGNORECASE if ignore_case
      timeout = pattern.respond_to?(:timeout) ? pattern.timeout : nil
      timeout ||= 0.25
      [Regexp.new(source, options, timeout: timeout), timeout]
    end

    def begin_run
      @mutex.synchronize do
        raise Error, "search is already running" if @running

        @running = true
        @cancelled = false
        @progress = Progress.new(files_scanned: 0, bytes_scanned: 0, matches: 0)
      end
    end

    def cancelled? = @cancelled || @external_cancelled&.call

    def search_paths
      files = []
      (@paths || @walker.each).each do |relative|
        SearchWorker.check_cancelled(method(:cancelled?))
        validate_path(relative)
        next if @extensions && !@paths && !@extensions.include?(File.extname(relative))
        next unless selected?(relative)

        files << relative
      end
      SearchWorker.check_cancelled(method(:cancelled?))
      files.sort!.uniq!
      files
    end

    def validate_path(relative)
      unless relative.is_a?(String) && relative.valid_encoding? && !relative.include?("\0")
        raise ArgumentError, "invalid search path"
      end
      normalized = File::ALT_SEPARATOR ? relative.tr(File::ALT_SEPARATOR, "/") : relative
      pieces = normalized.split("/", -1)
      if normalized.match?(/\A(?:\/|[A-Za-z]:\/)/) || pieces.any? { |piece| piece.empty? || piece == "." || piece == ".." }
        raise ArgumentError, "invalid search path"
      end

      absolute = File.expand_path(relative, @root)
      raise ArgumentError, "path outside root" unless inside_root?(absolute)
    end

    def selected?(path)
      (@include.empty? || @include.any? { |pattern| glob?(pattern, path) }) &&
        @exclude.none? { |pattern| glob?(pattern, path) }
    end

    def glob?(pattern, path)
      File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    end

    def inside_root?(path)
      path == @root || path.start_with?(@root.end_with?(File::SEPARATOR) ? @root : @root + File::SEPARATOR)
    end

    def receiver(results)
      path = number = offset = raw = line = nil
      lambda do |message|
        SearchWorker.validate_message(message)
        case message[0]
        when :line
          _, path, number, offset, raw = message
          validate_path(path)
          line = raw.freeze
        when :matches
          unless path && message[1].all? { |_column, first, last| last <= line.bytesize }
            raise IOError, "invalid search worker response"
          end
          message[1].each do |_column, first, last|
            match = Match.new(path: path.freeze, line_number: number, byte_offset: offset + first,
              line: line, ranges: [first...last].freeze)
            results << match
            update_progress(matches: 1)
            yield match
          end
        when :progress
          update_progress(files_scanned: message[1], bytes_scanned: message[2])
        when :error
          raise IOError, "search worker: #{message[1]}"
        when :done
          nil
        else
          raise IOError, "invalid search worker response"
        end
      end
    end

    def update_progress(files_scanned: 0, bytes_scanned: 0, matches: 0)
      @mutex.synchronize do
        @progress = Progress.new(files_scanned: @progress.files_scanned + files_scanned,
          bytes_scanned: @progress.bytes_scanned + bytes_scanned, matches: @progress.matches + matches)
      end
    end

    def parallel(files, count)
      progress = ->(scanned, bytes) { update_progress(files_scanned: scanned, bytes_scanned: bytes) }
      SearchPool.new(@root, @expression, @timeout, @max_file_size, @max_matches, method(:cancelled?)).run(files, count,
        progress: progress) do |message|
        yield message
      end
    end
  end
end
