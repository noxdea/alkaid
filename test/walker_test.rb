# frozen_string_literal: true

require_relative "test_helper"

class WalkerTest < Minitest::Test
  Ignore = Struct.new(:paths) do
    def ignored?(path, directory: false) = paths.include?([path, directory])
  end

  def test_walks_sorted_files_with_hidden_depth_and_duck_typed_ignore
    with_tree do |root|
      write(root, "b.txt", "b")
      write(root, "a/one.rb", "one")
      write(root, "a/deep/two.rb", "two")
      write(root, ".hidden", "hidden")
      write(root, ".git/config", "git")
      write(root, "skip/file", "skip")
      ignore = Ignore.new([["skip", true]])

      assert_equal %w[a/deep/two.rb a/one.rb b.txt], Alkaid::Walker.new(root, ignore: ignore).to_a
      assert_equal %w[a/one.rb b.txt], Alkaid::Walker.new(root, ignore: ignore, max_depth: 2).to_a
      assert_equal %w[.hidden a/one.rb b.txt], Alkaid::Walker.new(root, ignore: ignore, hidden: true, max_depth: 2).to_a
      assert_empty Alkaid::Walker.new(root, max_depth: 0).to_a
    end
  end

  def test_symlinks_are_opt_in_cycle_safe_and_confined_to_root
    skip "symlinks unavailable" if Gem.win_platform?

    with_tree do |root|
      outside = Dir.mktmpdir("alkaid-outside-")
      write(root, "real/file", "inside")
      write(outside, "secret", "outside")
      File.symlink("real/file", File.join(root, "alias"))
      File.symlink("..", File.join(root, "real", "cycle"))
      File.symlink(outside, File.join(root, "outside"))

      assert_equal ["real/file"], Alkaid::Walker.new(root).to_a
      assert_equal %w[alias real/file], Alkaid::Walker.new(root, follow_symlinks: true).to_a
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_rejects_invalid_options
    with_tree do |root|
      assert_raises(ArgumentError) { Alkaid::Walker.new(root, ignore: Object.new) }
      [-1, 1.5].each { |depth| assert_raises(ArgumentError) { Alkaid::Walker.new(root, max_depth: depth) } }
      assert_raises(ArgumentError) { Alkaid::Walker.new(root, hidden: nil) }
      write(root, "file", "x")
      assert_raises(ArgumentError) { Alkaid::Walker.new(File.join(root, "file")) }
    end
  end
end
