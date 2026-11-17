# frozen_string_literal: true

module CsvPreview
  # A cooperative wall-clock budget for one call. Code calls {#check!} at checkpoints; nothing is
  # interrupted asynchronously.
  # @api private
  class Deadline
    # The default clock: monotonic seconds, unaffected by changes to the wall clock.
    CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    # @param seconds [Numeric] the budget
    # @param clock [#call] monotonic clock returning seconds (for tests)
    def initialize(seconds, clock: CLOCK)
      @seconds = seconds
      @clock = clock
      @expires_at = clock.call + seconds
    end

    # @param stage [String, Symbol] name of the checkpoint (never input content)
    # @raise [TimeoutExceeded] when the budget is spent
    def check!(stage)
      return if @clock.call <= @expires_at

      raise TimeoutExceeded, "csv_preview exceeded its #{@seconds}s timeout (#{stage}). Pass a larger timeout " \
                             "option or render previews in a background job, see #{Help::ERRORS}"
    end

    # @return [Float] seconds left, never negative
    def remaining = [@expires_at - @clock.call, 0.0].max
  end
end
