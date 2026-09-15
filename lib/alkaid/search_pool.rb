# frozen_string_literal: true

require "rbconfig"
require "thread"
require_relative "search_worker"

module Alkaid
  class SearchPool
    Child = Struct.new(:pid, :input, :output, :queue, :writer, :reader, :waiter)
    private_constant :Child

    def initialize(root, expression, max_size, limit, cancelled)
      @root = root
      @expression = expression
      @max_size = max_size
      @limit = limit
      @cancelled = cancelled
    end

    def run(files, count)
      children = []
      errors = []
      first = 0
      count.times do |index|
        SearchWorker.check_cancelled(@cancelled)
        length = files.length / count + (index < files.length % count ? 1 : 0)
        children << start_child(files.slice(first, length))
        first += length
      end

      remaining = @limit
      children.each do |child|
        loop do
          SearchWorker.check_cancelled(@cancelled)
          begin
            message = child.queue.pop(true)
          rescue ThreadError
            sleep(0.005)
            next
          end
          if message.is_a?(Exception)
            errors << message
            break
          end
          break if message[0] == :done
          if message[0] == :error
            errors << IOError.new("search worker: #{message[1]}")
            break
          end
          if message[0] == :matches && remaining
            message[1] = message[1].first(remaining)
            remaining -= message[1].length
          end
          yield message
          if remaining == 0
            raise errors.first unless errors.empty?

            return
          end
        end
      end
      raise errors.first unless errors.empty?
    ensure
      children&.each { |child| stop_child(child) }
    end

    private

    def start_child(files)
      child_input, input = IO.pipe
      output, child_output = IO.pipe
      child = Child.new(nil, input, output, SizedQueue.new(2))
      config = [@root, files, @expression.source, @expression.options, @max_size, @limit, @expression.timeout]
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
