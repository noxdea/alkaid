# frozen_string_literal: true

require "rbconfig"
require "thread"
require_relative "search_worker"

module Alkaid
  class SearchPool
    BATCH_FILES = SearchWorker::MATCH_BATCH
    Child = Struct.new(:pid, :input, :output, :queue, :lock, :ready, :writer, :reader, :waiter)
    private_constant :Child

    def initialize(root, expression, timeout, max_size, limit, cancelled)
      @root = root
      @expression = expression
      @timeout = timeout
      @max_size = max_size
      @limit = limit
      @cancelled = cancelled
    end

    def run(files, count, progress:)
      children = []
      errors = []
      batches = file_batches(files, count)
      paths = Array.new(count) { [] }
      batch_sizes = Array.new(count) { [] }
      batches.each_with_index do |batch, index|
        owner = index % count
        paths[owner].concat(batch)
        batch_sizes[owner] << batch.length
      end
      count.times do |index|
        SearchWorker.check_cancelled(@cancelled)
        children << start_child(paths[index], batch_sizes[index], progress)
      end

      remaining = @limit
      active = Array.new(count, true)
      batches.each_index do |index|
        owner = index % count
        next unless active[owner]

        status, remaining = drain(children[owner], :batch, remaining, errors) { |message| yield message }
        raise errors.first if status == :limit && !errors.empty?
        return if status == :limit
        active[owner] = false if status == :failed
      end
      children.each_with_index do |child, index|
        next unless active[index]

        status, remaining = drain(child, :done, remaining, errors) { |message| yield message }
        raise errors.first if status == :limit && !errors.empty?
        return if status == :limit
      end
      raise errors.first unless errors.empty?
    ensure
      children&.each { |child| stop_child(child) }
    end

    private

    def file_batches(files, workers)
      size = [[files.length / workers, 1].max, BATCH_FILES].min
      files.each_slice(size).to_a
    end

    def drain(child, boundary, remaining, errors)
      loop do
        message = next_message(child)
        if message.is_a?(Exception)
          errors << message
          return [:failed, remaining]
        end
        if message[0] == :error
          errors << IOError.new("search worker: #{message[1]}")
          return [:failed, remaining]
        end
        return [:complete, remaining] if message[0] == boundary
        if [:batch, :done].include?(message[0]) || boundary == :done
          errors << IOError.new("invalid search worker sequence")
          return [:failed, remaining]
        end
        if message[0] == :matches && remaining
          message[1] = message[1].first(remaining)
          remaining -= message[1].length
        end
        yield message
        return [:limit, remaining] if remaining == 0
      end
    end

    def next_message(child)
      loop do
        SearchWorker.check_cancelled(@cancelled)
        child.lock.synchronize do
          begin
            return child.queue.pop(true)
          rescue ThreadError
            child.ready.wait(child.lock, 0.005)
          end
        end
      end
    end

    def start_child(files, batch_sizes, progress)
      child_input, input = IO.pipe
      output, child_output = IO.pipe
      child = Child.new(nil, input, output, SizedQueue.new(2), Mutex.new, ConditionVariable.new)
      config = [@root, files, @expression.source, @expression.options, @max_size, @limit, @timeout, batch_sizes]
      child.pid = Process.spawn({"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby, "--disable-gems",
        File.expand_path("search_worker/runner.rb", __dir__), in: child_input, out: child_output, err: File::NULL)
      child.waiter = Process.detach(child.pid)
      child_input.close
      child_output.close
      child.writer = Thread.new do
        SearchWorker.write_frame(input, config)
      rescue StandardError => error
        enqueue(child, error)
      ensure
        input.close unless input.closed?
      end
      child.reader = Thread.new do
        loop do
          message = SearchWorker.read_frame(output)
          SearchWorker.validate_message(message)
          if message[0] == :progress
            progress.call(message[1], message[2])
            next
          end
          break unless enqueue(child, message)
          break if message[0] == :done
        end
      rescue StandardError => error
        enqueue(child, error)
      end
      child
    rescue Exception
      stop_child(child) if child
      [child_input, child_output, input, output].compact.each { |io| io.close unless io.closed? }
      raise
    end

    def stop_child(child)
      child.queue.close
      [child.input, child.output].compact.each { |io| io.close unless io.closed? }
      [child.writer, child.reader].compact.each do |thread|
        thread.kill unless thread.join(0.2)
        thread.join(0.1)
      end
      if child.waiter && !child.waiter.join(0)
        signal(child, "TERM")
        unless child.waiter.join(0.2)
          signal(child, "KILL")
          child.waiter.join
        end
      elsif child.pid && !child.waiter
        signal(child, "KILL")
        Process.waitpid(child.pid)
      end
    end

    def enqueue(child, message)
      child.queue.push(message)
      child.lock.synchronize { child.ready.signal }
      true
    rescue ClosedQueueError
      false
    end

    def signal(child, name)
      Process.kill(name, child.pid)
    rescue Errno::ESRCH, Errno::EINVAL, Errno::ECHILD
      nil
    end
  end

  private_constant :SearchPool
end
