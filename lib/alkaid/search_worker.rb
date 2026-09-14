# frozen_string_literal: true

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

    def write_frame(io, value)
      bytes = Marshal.dump(value)
      raise IOError, "search frame exceeds safety limit" if bytes.bytesize > MAX_FRAME_BYTES

      io.write([bytes.bytesize].pack("N"))
      io.write(bytes)
      io.flush
    end

    def read_frame(io)
      header = io.read(4)
      raise EOFError, "search worker ended before completion" unless header && header.bytesize == 4

      size = header.unpack1("N")
      raise IOError, "invalid search frame size" unless size.between?(1, MAX_FRAME_BYTES)

      bytes = io.read(size)
      raise EOFError, "truncated search frame" unless bytes && bytes.bytesize == size

      # The peer is always this gem's own child process, never an external source.
      Marshal.load(bytes)
    rescue TypeError, ArgumentError => error
      raise IOError, "invalid search frame: #{error.message}"
    end

    def scan(root, paths, expression, max_size, limit, cancelled: nil)
      total = 0
      files_scanned = bytes_scanned = 0
      paths.each do |relative|
        check_cancelled(cancelled)
        read = read_source(root, relative, max_size, cancelled)
        next unless read

        source, bytes = read
        files_scanned += 1
        bytes_scanned += bytes
        next unless source

        offset = 0
        source.each_line.with_index(1) do |line, number|
          check_cancelled(cancelled)
          matches, sent_line = [], false
          Alkaid.with_regexp_timeout(expression) do
            line.to_enum(:scan, expression).each do
              match = Regexp.last_match
              check_cancelled(cancelled)
              unless sent_line
                unless files_scanned.zero?
                  yield [:progress, files_scanned, bytes_scanned]
                  files_scanned = bytes_scanned = 0
                end
                yield [:line, relative, number, offset, line]
                sent_line = true
              end
              first, last = match.byteoffset(0)
              matches << [match.begin(0) + 1, first, last]
              total += 1
              if matches.length == MATCH_BATCH || (limit && total >= limit)
                yield [:matches, matches]
                matches = []
              end
              return if limit && total >= limit
            end
          end
          yield [:matches, matches] unless matches.empty?
          offset += line.bytesize
        end
        if files_scanned == MATCH_BATCH
          yield [:progress, files_scanned, bytes_scanned]
          files_scanned = bytes_scanned = 0
        end
      end
      yield [:progress, files_scanned, bytes_scanned] unless files_scanned.zero?
    end

    def read_source(root, relative, max_size, cancelled)
      absolute = File.expand_path(relative, root)
      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      raise ArgumentError, "path outside root" unless absolute.start_with?(prefix)

      real = File.realpath(absolute)
      raise ArgumentError, "path outside root" unless real == root || real.start_with?(prefix)

      flags = File::RDONLY
      # Windows defines NONBLOCK as 1, which aliases WRONLY in File.open.
      flags |= File::NONBLOCK unless RUBY_PLATFORM.match?(/mswin|mingw/)
      File.open(real, flags) do |file|
        file.binmode
        return unless file.stat.file? && file.size <= max_size

        source = +"".b
        while (chunk = file.read(READ_BYTES))
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
      root, paths, source, options, max_size, limit, timeout = read_frame(STDIN)
      expression = Regexp.new(source, options, timeout: timeout)
      scan(root, paths, expression, max_size, limit) { |message| write_frame(STDOUT, message) }
      write_frame(STDOUT, [:done])
    rescue StandardError => error
      write_frame(STDOUT, [:error, "#{error.class}: #{error.message}".byteslice(0, 4096)])
      write_frame(STDOUT, [:done])
    end
  end
end

require_relative "search_worker/cancelled"
Alkaid.send(:private_constant, :SearchWorker)
