# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class SearchTest < Minitest::Test
  Worker = Alkaid.const_get(:SearchWorker, false)

  def test_serial_and_spawned_workers_match_unicode_byte_oracle
    with_tree do |root|
      corpus = {
        "b.rb" => "日本 apple apple\r\n😀 apple\n",
        "a.txt" => "Apple\n",
        "a/z.rb" => "apple\n",
        "a.rb" => "apple\n"
      }
      corpus.each { |path, text| write(root, path, text) }
      expected = [
        ["a.rb", 1, 0, "apple\n", [0...5]],
        ["a.txt", 1, 0, "Apple\n", [0...5]],
        ["a/z.rb", 1, 0, "apple\n", [0...5]],
        ["b.rb", 1, 7, "日本 apple apple\r\n", [7...12]],
        ["b.rb", 1, 13, "日本 apple apple\r\n", [13...18]],
        ["b.rb", 2, 25, "😀 apple\n", [5...10]]
      ]

      serial = Alkaid::Search.new(root, pattern: "apple", ignore_case: true, workers: 1, hidden: true).run
      record_children do |pids|
        parallel = Alkaid::Search.new(root, pattern: /apple/i, workers: 3, hidden: true).run
        assert_equal 3, pids.length
        assert_equal expected, parallel.map { |match| [match.path, match.line_number, match.byte_offset, match.line, match.ranges] }
        assert_equal serial, parallel
      end
    end
  end

  def test_literal_regexp_word_glob_extension_and_ignore_options
    with_tree do |root|
      write(root, "lib/a.rb", "cat cats CAT\n")
      write(root, "lib/a.txt", "cat\n")
      write(root, "vendor/a.rb", "cat\n")
      write(root, ".hidden.rb", "cat\n")
      ignore = Object.new
      ignore.define_singleton_method(:ignored?) do |candidate, directory: false|
        candidate == "vendor" || candidate.start_with?("vendor/")
      end

      options = {pattern: "cat", ignore_case: true, whole_word: true, include: ["**/*.rb"],
                 exclude: ["**/generated/**"], ignore: ignore, workers: 1}
      matches = Alkaid::Search.new(root, **options).run
      assert_equal ["lib/a.rb", "lib/a.rb"], matches.map(&:path)
      assert_equal [0...3, 9...12], matches.map { |match| match.ranges.first }

      regexp = Alkaid::Search.new(root, pattern: "c.t", regexp: true, extensions: ["txt"], workers: 1).run
      assert_equal ["lib/a.txt"], regexp.map(&:path)
    end
  end

  def test_binary_invalid_utf8_oversize_and_missing_files_are_skipped
    with_tree do |root|
      write(root, "binary", "needle\n\0")
      write(root, "invalid", "needle\n\xff".b)
      write(root, "large", "needle!!!")
      write(root, "valid", "needle\n")
      search = Alkaid::Search.new(root, pattern: "needle", max_file_size: 8, workers: 2,
        paths: %w[binary invalid large missing valid])
      assert_equal ["valid"], search.run.map(&:path)
      assert_equal Alkaid::Progress.new(files_scanned: 3, bytes_scanned: 23, matches: 1), search.progress
    end
  end

  def test_limit_is_deterministic_and_results_stream_in_order
    with_tree do |root|
      %w[a b c d].each { |path| write(root, path, "日x" * 1_000) }
      yielded = []
      search = Alkaid::Search.new(root, pattern: /x/, workers: 4, max_matches: 257, hidden: true)
      result = search.run { |match| yielded << match }

      assert_equal result, yielded
      assert_equal 257, result.length
      assert_equal ["a"], result.map(&:path).uniq
      assert_equal((0...257).map { |index| index * 4 + 3 }, result.map(&:byte_offset))
      assert_equal 257, search.progress.matches
    end
  end

  def test_zero_width_and_line_ending_matches_keep_byte_ranges
    with_tree do |root|
      write(root, "a", "日😀\r\n")
      assert_equal [0, 3, 7], Alkaid::Search.new(root, pattern: /(?=.)/, workers: 1).run.map(&:byte_offset)
      newline = Alkaid::Search.new(root, pattern: /\r?\n/, workers: 1).run.first
      assert_equal "日😀\r\n", newline.line
      assert_equal [7...9], newline.ranges
    end
  end

  def test_cancel_stops_children_discards_return_value_and_reaps_processes
    with_tree do |root|
      %w[a b c d].each { |path| write(root, path, "x" * 500_000) }
      before = Thread.list
      search = Alkaid::Search.new(root, pattern: /x/, workers: 4)
      streamed = []
      record_children do |pids|
        result = search.run do |match|
          streamed << match
          search.cancel
        end
        assert_empty result
        assert_equal 4, pids.length
      end
      refute_empty streamed
      assert_empty Thread.list - before
    end
  end

  def test_external_cancellation_discards_serial_results
    with_tree do |root|
      write(root, "large", "x" * 100_000)
      calls = 0
      search = Alkaid::Search.new(root, pattern: /x/, workers: 1, cancelled: -> { (calls += 1) >= 10 })
      assert_empty search.run
      assert_equal 10, calls
    end
  end

  def test_external_cancellation_interrupts_path_collection
    with_tree do |root|
      write(root, "one", "x")
      calls = 0
      paths = Array.new(1_000) { |index| "missing-#{index}" }
      search = Alkaid::Search.new(root, pattern: "x", workers: 1, paths: paths,
        cancelled: -> { (calls += 1) >= 5 })
      assert_empty search.run
      assert_equal 5, calls
      assert_equal 0, search.progress.files_scanned
    end
  end

  def test_callback_failure_still_reaps_workers
    with_tree do |root|
      %w[a b].each { |path| write(root, path, "x\n") }
      record_children do
        error = assert_raises(RuntimeError) do
          Alkaid::Search.new(root, pattern: "x", workers: 2).run { raise "stop" }
        end
        assert_equal "stop", error.message
      end
    end
  end

  def test_worker_crash_and_spawn_failure_do_not_leave_processes
    with_tree do |root|
      %w[a b].each { |path| write(root, path, "x") }
      spawn, pids = Process.method(:spawn), []
      replacement = lambda do |*args, **options|
        pid = spawn.call(*args[0...-1], "-e", "exit! 17", **options)
        pids << pid
        pid
      end
      Process.stub(:spawn, replacement) do
        assert_raises(IOError, EOFError, Errno::EPIPE) { Alkaid::Search.new(root, pattern: "x", workers: 2).run }
      end
      pids.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }

      count, children = 0, []
      Process.stub(:spawn, lambda { |*args, **options|
        (count += 1) == 2 ? (raise Errno::EAGAIN) : spawn.call(*args, **options).tap { |pid| children << pid }
      }) do
        assert_raises(Errno::EAGAIN) { Alkaid::Search.new(root, pattern: "x", workers: 2).run }
      end
      children.each { |pid| assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) } }
    end
  end

  def test_timeout_and_worker_frame_validation
    with_tree do |root|
      %w[a b].each { |path| write(root, path, "a" * 20_000 + "!") }
      expression = Regexp.new('^(a+)+\\1$', timeout: 0.001)
      assert_raises(Regexp::TimeoutError) { Alkaid::Search.new(root, pattern: expression, workers: 1).run }
      error = assert_raises(IOError) { Alkaid::Search.new(root, pattern: expression, workers: 2).run }
      assert_match(/Regexp::TimeoutError/, error.message)
    end

    value = [:line, "日本.rb", 1, 0, "file text\n"]
    io = StringIO.new("".b)
    Worker.write_frame(io, value)
    io.rewind
    assert_equal value, Worker.read_frame(io)
    ["", "\0", [12].pack("N") + "short"].each do |bytes|
      assert_raises(EOFError) { Worker.read_frame(StringIO.new(bytes)) }
    end
    [0, Worker::MAX_FRAME_BYTES + 1].each do |size|
      assert_raises(IOError) { Worker.read_frame(StringIO.new([size].pack("N"))) }
    end
    assert_raises(IOError) { Worker.read_frame(StringIO.new([3].pack("N") + "bad")) }
  end

  def test_rejects_untrusted_options_and_paths
    with_tree do |root|
      write(root, "one", "x")
      [0, -1, 33, 1.5].each { |workers| assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", workers: workers) } }
      [-1, "10"].each { |size| assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", max_file_size: size) } }
      [0, -1, 1.5].each { |limit| assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", max_matches: limit) } }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: Object.new) }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", regexp: nil) }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", cancelled: Object.new) }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", paths: ["../outside"]).run }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", paths: ["./one"]).run }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", paths: [File.join(root, "one")]).run }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", paths: ["nul\0path"]) }
      assert_raises(ArgumentError) { Alkaid::Search.new(root, pattern: "x", include: "*.rb") }
    end
  end
end
