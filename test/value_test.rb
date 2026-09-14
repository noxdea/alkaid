# frozen_string_literal: true

require_relative "test_helper"

class ValueTest < Minitest::Test
  def test_values_are_immutable_and_support_data_construction
    progress = Alkaid::Progress.new(1, 2, 3)
    assert_equal Alkaid::Progress.new(files_scanned: 1, bytes_scanned: 2, matches: 3), progress
    assert_equal 4, progress.with(matches: 4).matches
    assert_same progress, progress.with
    assert_predicate progress, :frozen?
    refute_respond_to progress, :matches=
    assert_raises(ArgumentError) { Alkaid::Progress.new(files_scanned: 1, bytes_scanned: 2) }
    assert_raises(ArgumentError) { progress.with(unknown: 1) }
  end
end
