# frozen_string_literal: true

module Alkaid::SearchWorker
  module_function

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

  def validate_config(value)
    unless value.is_a?(Array) && value.length == 8
      raise IOError, "invalid search worker configuration"
    end

    root, paths, source, options, max_size, limit, timeout, batch_sizes = value
    valid_root = root.is_a?(String) && root.valid_encoding? && !root.include?("\0") && File.directory?(root)
    valid_paths = paths.is_a?(Array) && paths.all? { |path| valid_path?(path) }
    valid_source = source.is_a?(String) && source.valid_encoding?
    valid_options = options.is_a?(Integer) && options >= 0
    valid_size = max_size.is_a?(Integer) && max_size.between?(0, MAX_FILE_BYTES)
    valid_limit = limit.nil? || (limit.is_a?(Integer) && limit.positive?)
    valid_timeout = timeout.is_a?(Numeric) && timeout.positive?
    valid_batches = batch_sizes.is_a?(Array) && batch_sizes.all? do |size|
      size.is_a?(Integer) && size.between?(1, MATCH_BATCH)
    end && batch_sizes.sum == paths.length
    unless valid_root && valid_paths && valid_source && valid_options && valid_size && valid_limit && valid_timeout && valid_batches
      raise IOError, "invalid search worker configuration"
    end

    value
  end

  def validate_message(value)
    raise IOError, "invalid search worker response" unless value.is_a?(Array)

    valid = case value[0]
    when :line
      value.length == 5 && valid_path?(value[1]) && positive_integer?(value[2]) &&
        nonnegative_integer?(value[3]) && value[4].is_a?(String) && value[4].valid_encoding?
    when :matches
      value.length == 2 && value[1].is_a?(Array) && value[1].length <= MATCH_BATCH &&
        value[1].all? do |entry|
          entry.is_a?(Array) && entry.length == 3 && positive_integer?(entry[0]) &&
            nonnegative_integer?(entry[1]) && nonnegative_integer?(entry[2]) && entry[1] <= entry[2]
        end
    when :progress
      value.length == 3 && nonnegative_integer?(value[1]) && nonnegative_integer?(value[2])
    when :batch
      value.length == 1
    when :error
      value.length == 2 && value[1].is_a?(String) && value[1].valid_encoding? && value[1].bytesize <= 4096
    when :done
      value.length == 1
    else
      false
    end
    raise IOError, "invalid search worker response" unless valid

    value
  end

  def valid_path?(path)
    return false unless path.is_a?(String) && path.valid_encoding? && !path.include?("\0")

    normalized = File::ALT_SEPARATOR ? path.tr(File::ALT_SEPARATOR, "/") : path
    pieces = normalized.split("/", -1)
    !normalized.match?(/\A(?:\/|[A-Za-z]:\/)/) && pieces.none? { |piece| piece.empty? || piece == "." || piece == ".." }
  end

  def positive_integer?(value) = value.is_a?(Integer) && value.positive?
  def nonnegative_integer?(value) = value.is_a?(Integer) && value >= 0
end
