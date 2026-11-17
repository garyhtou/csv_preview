# frozen_string_literal: true

require "test_helper"

class DeadlineTest < Minitest::Test
  def clock_at(time)
    -> { time[:now] }
  end

  def test_check_raises_timeout_exceeded_after_expiry
    time = { now: 100.0 }
    deadline = CsvPreview::Deadline.new(5, clock: clock_at(time))
    deadline.check!(:parse)
    time[:now] = 105.0
    deadline.check!(:parse)
    time[:now] = 105.1
    assert_raises(CsvPreview::TimeoutExceeded) { deadline.check!(:parse) }
  end

  def test_remaining_counts_down
    time = { now: 10.0 }
    deadline = CsvPreview::Deadline.new(5, clock: clock_at(time))
    assert_in_delta 5.0, deadline.remaining
    time[:now] = 12.0
    assert_in_delta 3.0, deadline.remaining
    time[:now] = 99.0
    assert_equal 0.0, deadline.remaining
  end

  def test_timeout_message_names_stage_not_content
    time = { now: 0.0 }
    deadline = CsvPreview::Deadline.new(2, clock: clock_at(time))
    time[:now] = 3.0
    error = assert_raises(CsvPreview::TimeoutExceeded) { deadline.check!("layout") }
    assert_equal "csv_preview exceeded its 2s timeout (layout). Pass a larger timeout option or render previews " \
                 "in a background job, see https://github.com/garyhtou/csv_preview#errors", error.message
  end

  def test_default_clock_is_monotonic_and_error_hierarchy
    assert_operator CsvPreview::Deadline.new(60).remaining, :>, 0
    [CsvPreview::UnreadableInput, CsvPreview::TimeoutExceeded, CsvPreview::RenderFailed].each do |klass|
      assert_operator klass, :<, CsvPreview::Error
    end
    assert_operator CsvPreview::Error, :<, StandardError
  end
end
