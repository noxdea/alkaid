# frozen_string_literal: true

require "strscan"
require_relative "regexp_compat"
require_relative "match_data_compat"

module Alkaid
  module SearchWorker
    MAX_FILE_BYTES = 64 << 20
    MAX_FRAME_BYTES = MAX_FILE_BYTES + (64 << 10)
    READ_BYTES = 64 << 10
    MATCH_BATCH = 128

    module_function

    def check_cancelled(callback)
      raise Cancelled if callback&.call
    end

    def scan(root, paths, expression, max_size, limit, cancelled: nil, batch_sizes: nil)
      total = 0
      files_scanned = bytes_scanned = 0
      cursor = 0
      batches = batch_sizes ? batch_sizes.map { |size| paths.slice(cursor, size).tap { cursor += size } } : [paths]
      batches.each do |batch|
        limited = false
        batch.each do |relative|
          check_cancelled(cancelled)
          read = read_source(root, relative, max_size, cancelled)
          next unless read

          source, bytes = read
          files_scanned += 1
          bytes_scanned += bytes
          next unless source

          line_scanner = StringScanner.new(source)
          line_start = 0
          line_end = next_line_end(line_scanner, line_start)
          line_number = 1
          group = nil
          matches = []
          each_match(source, expression, cancelled) do |match|
            first, last = match.byteoffset(0)
            while line_end < source.bytesize && first >= line_end
              line_start = line_end
              line_end = next_line_end(line_scanner, line_start)
              line_number += 1
            end
            if first == source.bytesize && !source.empty? && source.end_with?("\n")
              line_start = line_end = source.bytesize
              line_number += 1
            end

            number = line_number
            offset = line_start
            target = last > first ? last - 1 : first
            while line_end < source.bytesize && target >= line_end
              line_start = line_end
              line_end = next_line_end(line_scanner, line_start)
              line_number += 1
            end
            current_group = [number, offset, line_end]
            unless group == current_group
              yield [:matches, matches] unless matches.empty?
              matches = []
              yield [:line, relative, number, offset, source.byteslice(offset, line_end - offset)]
              group = current_group
            end

            relative_first = first - offset
            column = source.byteslice(offset, relative_first).length + 1
            matches << [column, relative_first, last - offset]
            total += 1
            if matches.length == MATCH_BATCH || (limit && total >= limit)
              yield [:matches, matches]
              matches = []
            end
            if limit && total >= limit
              limited = true
              break
            end
          end
          yield [:matches, matches] unless matches.empty?
          break if limited
        end
        unless files_scanned.zero?
          yield [:progress, files_scanned, bytes_scanned]
          files_scanned = bytes_scanned = 0
        end
        yield [:batch] if batch_sizes
        return if limited
      end
    end

    def read_source(root, relative, max_size, cancelled)
      absolute = File.expand_path(relative, root)
      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      raise ArgumentError, "path outside root" unless absolute.start_with?(prefix)

      real = File.realpath(absolute)
      raise ArgumentError, "path outside root" unless real == root || real.start_with?(prefix)

      flags = File::RDONLY
      # Windows defines NONBLOCK as 1, which aliases WRONLY in File.open.
      windows = RUBY_PLATFORM.match?(/mswin|mingw/)
      flags |= File::NONBLOCK unless windows
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW) && !windows
      File.open(real, flags) do |file|
        file.binmode
        return unless file.stat.file? && file.size <= max_size

        source = +"".b
        while (chunk = file.read([READ_BYTES, max_size - source.bytesize + 1].min))
          check_cancelled(cancelled)
          source << chunk
          return [nil, source.bytesize] if source.bytesize > max_size || chunk.include?("\0")
        end
        source.force_encoding(Encoding::UTF_8)
        [source.valid_encoding? ? source : nil, source.bytesize]
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ELOOP
      nil
    end

    def run
      STDIN.binmode
      STDOUT.binmode
      root, paths, source, options, max_size, limit, timeout, batch_sizes = validate_config(read_frame(STDIN))
      expression = Regexp.new(source, options, timeout: timeout)
      scan(root, paths, expression, max_size, limit, batch_sizes: batch_sizes) do |message|
        write_frame(STDOUT, message)
      end
      write_frame(STDOUT, [:done])
    rescue StandardError => error
      message = "#{error.class}: #{error.message}".encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      write_frame(STDOUT, [:error, message.byteslice(0, 4093).scrub])
      write_frame(STDOUT, [:done])
    end

    def each_match(source, expression, cancelled)
      position = 0
      loop do
        check_cancelled(cancelled)
        match = Alkaid.with_regexp_timeout(expression) { expression.match(source, position) }
        break unless match

        yield match
        ending = match.end(0)
        break if match.begin(0) == ending && ending == source.length

        position = ending + (match.begin(0) == ending ? 1 : 0)
      end
    end

    def next_line_end(scanner, offset)
      scanner.pos = offset
      scanner.skip_until(/\n/) ? scanner.pos : scanner.string.bytesize
    end
  end
end

require_relative "search_worker/protocol"
require_relative "search_worker/cancelled"
Alkaid.send(:private_constant, :SearchWorker)
