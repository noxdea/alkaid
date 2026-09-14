# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "tmpdir"
require "alkaid"

module AlkaidTestHelpers
  def with_tree
    Dir.mktmpdir("alkaid-") { |root| yield root }
  end

  def write(root, path, contents)
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def record_children
    pids = []
    spawn = Process.method(:spawn)
    Process.stub(:spawn, ->(*args, **options) { spawn.call(*args, **options).tap { |pid| pids << pid } }) do
      yield pids
    end
  ensure
    pids.each do |pid|
      assert_raises(Errno::ECHILD, "child #{pid} was not reaped") { Process.waitpid(pid, Process::WNOHANG) }
    end
  end
end

class Minitest::Test
  include AlkaidTestHelpers
end
