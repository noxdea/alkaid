# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/alkaid"

files = Integer(ENV.fetch("FILES", "4096"))
bytes = Integer(ENV.fetch("BYTES", "4096"))
raise "FILES must be positive and BYTES must be at least 7" unless files.positive? && bytes >= 7

Dir.mktmpdir("alkaid-bench-") do |root|
  body = ("x" * (bytes - 1) + "\n").byteslice(0, bytes)
  files.times do |index|
    path = File.join(root, format("%06d.txt", index))
    File.binwrite(path, index.zero? ? "needle\n" + body.byteslice(7..) : body)
  end

  samples = 5.times.map do
    first_match = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    matches = Alkaid::Search.new(root, pattern: "needle", workers: 4, hidden: true).run do
      first_match ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    [Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, first_match - started, matches.length]
  end
  elapsed = samples.map(&:first).sort.fetch(samples.length / 2)
  first = samples.map { |sample| sample[1] }.sort.fetch(samples.length / 2)
  matches = samples.last[2]

  if ENV["BUDGET"] == "1"
    raise "search exceeded 3s: #{elapsed.round(3)}s" if elapsed > 3
    raise "first match exceeded 100ms: #{(first * 1000).round(1)}ms" if first > 0.1
  end

  puts "search #{files} files / #{files * bytes} bytes (5-run median): #{elapsed.round(3)}s, first match #{(first * 1000).round(1)}ms, #{matches} match"
end
