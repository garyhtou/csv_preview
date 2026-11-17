# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"
require_relative "support/fixtures"
require_relative "support/hostile_shapes"
require_relative "support/memory"

# Bounds on hostile input for the data path: time, memory and results for the shapes of
# parsing-and-safety.md section 7.3 (PS-18 to PS-21), and privacy of error messages (PS-33).
class BoundsTest < Minitest::Test
  SHAPES = HostileShapes.build.freeze
  HOSTILE_SHAPES = File.expand_path("support/hostile_shapes.rb", __dir__)

  def sample(source, **options) = CsvPreview.sample(source, **options)
  # Each hostile shape is sampled once per run; the result and its time are shared by the PS-18 tests.
  SHAPE_RESULTS = {}
  SHAPE_LOCK = Mutex.new

  def shape(name)
    SHAPE_LOCK.synchronize do
      SHAPE_RESULTS[name] ||= timed { sample(StringIO.new(SHAPES.fetch(name))) }
    end
  end

  def shape_sample(name) = shape(name).first
  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def timed
    started = clock
    result = yield
    [result, clock - started]
  end

  # --- PS-18 ---

  # Row counts the spec lists for the shapes whose counts it pins (section 7.3 and 4.6).
  PINNED_ROWS_READ = {
    "a_lf" => 1_048_576, "a_crlf" => 699_051, "quoted_rows" => 262_144, "stray_quote_then_rows" => 349_525
  }.freeze

  def test_PS_18_every_hostile_shape_completes_within_bounds
    assert_equal 30, SHAPES.size
    SHAPES.each do |name, bytes|
      s, seconds = shape(name)
      assert_operator seconds, :<, 5.0, "#{name} took #{seconds.round(2)} s"
      assert_operator s.column_count, :<=, 12, name
      assert_operator s.rows.size, :<=, 20, name
      assert s.rows.all? { |row| row.size == s.column_count }, name
      assert_operator s.total_columns, :<=, 81_921, "#{name} field guard"
      assert_nil s.total_rows, name if bytes.bytesize == HostileShapes::SIZE
    end
  end

  def test_PS_18_pinned_row_counts
    PINNED_ROWS_READ.each do |name, rows|
      assert_equal rows, shape_sample(name).rows_read, name
    end
  end

  def test_PS_18_field_guard_shapes_stop_inside_the_line
    %w[one_line_x_comma quoted_a_comma text_after_quotes space_before_quotes mid_field_quotes multibyte
       comma_quote].each do |name|
      s = shape_sample(name)
      assert s.columns_truncated?, name
      assert_operator s.total_columns, :>=, 34_817, name
      assert_equal 12, s.column_count, name
    end
    assert_equal 69_632, shape_sample("one_line_x_comma").total_columns
  end

  def test_PS_18_blank_and_empty_shapes_are_empty_samples
    %w[only_commas only_lf only_crlf only_spaces space_comma empty_quoted_fields blank_quoted_records
       multiline_quoted_fields].each do |name|
      s = shape_sample(name)
      assert s.empty?, name
      assert_equal 0, s.rows_read, name
    end
  end

  def test_PS_18_single_giant_cell_is_cut
    %w[one_unquoted_cell one_quoted_cell quote_then_letters quoted_pairs].each do |name|
      s = shape_sample(name)
      cell = s.headers.first
      assert_operator cell.each_grapheme_cluster.count, :<=, 60, name
      assert_equal 1, s.column_count, name
    end
  end

  def test_PS_18_cut_realistic_exports_keep_the_columns
    %w[realistic realistic_cut_mid_record realistic_crlf_cut cut_inside_quoted_field].each do |name|
      s = shape_sample(name)
      assert_equal 23, s.total_columns, name
      assert_equal 12, s.column_count, name
      assert s.columns_truncated?, name
      assert s.rows_truncated?, name
    end
  end

  def reader_result(name)
    CsvPreview::Reader.call(StringIO.new(SHAPES.fetch(name)), config: CsvPreview.config.resolve,
                            deadline: CsvPreview::Deadline.new(60))
  end

  def test_PS_18_cut_shapes_are_cut_by_the_reader_not_complete_files
    %w[realistic_cut_mid_record realistic_crlf_cut cut_inside_quoted_field].each do |name|
      assert_operator SHAPES.fetch(name).bytesize, :>, HostileShapes::SIZE, name
      result = reader_result(name)
      refute result.complete, name
      assert_equal HostileShapes::SIZE, result.bytes_read, name
    end
  end

  def test_PS_18_cut_inside_a_quoted_field_uses_the_cut_tail_recovery
    result = reader_result("cut_inside_quoted_field")
    text = CsvPreview::Parser.normalize!(+result.text)
    records = CsvPreview::Parser::Records.new(text, complete: false, delimiter: ",", keep_rows: 21,
                                                    keep_columns: 12, raw_cap: 552,
                                                    deadline: CsvPreview::Deadline.new(60)).call
    assert records.recovered, "rule 2 not applied"
    refute records.complete
    assert_equal 12_558, shape_sample("cut_inside_quoted_field").rows_read
  end

  def test_PS_18_shapes_that_end_inside_a_quote_are_complete_files_not_hangs
    s = shape_sample("only_quote")
    assert_equal 0, s.total_rows
    refute s.rows_truncated?
  end

  def test_PS_18_memory_growth_over_all_shapes
    # The inputs are built before the baseline is taken: the growth is that of parsing them.
    result = Memory.measure("shapes.each_value { |bytes| CsvPreview.sample(StringIO.new(bytes)) }; nil",
                            warmup: "require \"stringio\"; shapes = HostileShapes.build; " \
                                    "CsvPreview.sample(StringIO.new(\"a,b\\n1,2\\n\"))",
                            requires: [HOSTILE_SHAPES])
    assert_operator result[:growth], :<, 200 * 1024 * 1024, "growth #{result[:growth] / 1024 / 1024} MB"
  end

  # --- PS-19 (the sample half; the read bound itself is in reader_test) ---

  def test_PS_19_huge_file_sample_memory_growth_under_200_mb
    huge = Fixtures.generate("huge.csv")
    simple = Fixtures.path("simple.csv")
    result = Memory.measure(<<~RUBY, warmup: "CsvPreview.sample(#{simple.inspect})")
      s = CsvPreview.sample(#{huge.inspect})
      [s.total_rows.nil?, s.rows_truncated?]
    RUBY
    assert_equal [true, true], result[:output]
    assert_operator result[:growth], :<, 200 * 1024 * 1024, "growth #{result[:growth] / 1024 / 1024} MB"
  end

  def test_PS_19_huge_file_sample_is_truncated_with_unknown_total
    s, seconds = timed { sample(Fixtures.generate("huge.csv")) }
    assert_nil s.total_rows
    assert s.rows_truncated?
    assert_operator seconds, :<, 5.0
  end

  # --- PS-20 ---

  def test_PS_20_million_columns_on_one_line
    path = Fixtures.generate("one_line_million_columns.csv")
    assert_equal 2_000_000, File.size(path)
    s, seconds = timed { sample(path, header_row: false) }
    assert_equal 12, s.column_count
    assert_includes 57_345..81_921, s.total_columns
    assert_equal 1, s.rows_read
    assert_nil s.total_rows
    assert s.columns_truncated?
    assert_operator seconds, :<, 1.0
  end

  def test_PS_20_with_auto_header_the_single_record_becomes_the_header
    s = sample(Fixtures.generate("one_line_million_columns.csv"))
    assert_equal 12, s.headers.size
    assert_equal 0, s.rows_read
  end

  def test_PS_20_memory_growth_under_30_mb
    path = Fixtures.generate("one_line_million_columns.csv")
    result = Memory.measure("CsvPreview.sample(#{path.inspect}, header_row: false).total_columns",
                            warmup: "CsvPreview.sample(#{Fixtures.path("simple.csv").inspect})")
    assert_operator result[:growth], :<, 30 * 1024 * 1024, "growth #{result[:growth] / 1024 / 1024} MB"
  end

  # --- PS-21 (sample half) ---

  # A deadline whose clock reads zero (at creation and for the first nth - 1 checks), then a moment past
  # any budget, so the nth checkpoint is the first to raise.
  def expiring_deadline(nth)
    readings = -1
    clock = lambda do
      readings += 1
      readings < nth ? 0.0 : 1_000_000.0
    end
    CsvPreview::Deadline.new(1, clock: clock)
  end

  def run_pipeline(source, deadline)
    config = CsvPreview.config.resolve
    CsvPreview::Parser.call(CsvPreview::Reader.call(source, config: config, deadline: deadline),
                            config: config, deadline: deadline)
  end

  def test_PS_21_tiny_timeout_on_huge_file_raises_quickly
    path = Fixtures.generate("huge.csv")
    error, seconds = timed { assert_raises(CsvPreview::TimeoutExceeded) { sample(path, timeout: 0.001) } }
    assert_operator seconds, :<, 0.1
    assert_match(/\((read|decode|sniff)\)/, error.message) # whichever checkpoint is reached first
  end

  def test_PS_21_each_stage_raises_from_its_own_checkpoint
    stages = {}
    (1..400).each do |nth|
      run_pipeline(StringIO.new("a,b\n1,2\n3,4\n"), expiring_deadline(nth))
      break
    rescue CsvPreview::TimeoutExceeded => e
      stages[e.message[/\((\w+)\)/, 1]] = true
    end
    assert_equal %w[decode parse read sanitize sniff], stages.keys.sort
  end

  def test_PS_21_timeout_inside_one_two_mib_record_comes_out_of_csv_unchanged
    deadline_class = Class.new do
      def check!(stage)
        raise CsvPreview::TimeoutExceeded, "csv_preview exceeded its timeout (#{stage})" if stage == :parse
      end
    end
    config = CsvPreview.config.resolve
    result = CsvPreview::Reader.call(StringIO.new(SHAPES.fetch("one_unquoted_cell")), config: config,
                                     deadline: CsvPreview::Deadline.new(60))
    error = assert_raises(CsvPreview::TimeoutExceeded) do
      CsvPreview::Parser.call(result, config: config, deadline: deadline_class.new)
    end
    assert_equal "csv_preview exceeded its timeout (parse)", error.message
  end

  def test_PS_21_generous_timeout_does_not_raise
    assert_equal "a", sample(StringIO.new("a\n1\n"), timeout: 30).headers.first
  end

  # --- PS-33 ---

  MARKER = "SECRET-7f3a"

  def with_file(bytes)
    Tempfile.create(["secret", ".csv"], binmode: true) do |file|
      file.write(bytes)
      file.flush
      yield file.path
    end
  end

  def assert_private(error, label)
    refute_includes error.message, MARKER, label
    refute_includes error.message, "SECRET", label
    refute_includes error.message, "7f3a", label
    refute_includes error.backtrace.to_a.join, MARKER, label
    refute_includes error.inspect, MARKER, label
  end

  def test_PS_33_unreadable_input_never_quotes_the_input
    inputs = {
      "nul" => "#{MARKER},b\n1,2\n\x00#{MARKER}\n".b,
      "png" => "\x89PNG\r\n\x1A\n#{MARKER}".b,
      "gzip" => "\x1F\x8B#{MARKER}".b,
      "zip" => "PK\x03\x04#{MARKER}".b,
      "controls" => (("\x01" + MARKER) * 400).b
    }
    inputs.each do |label, bytes|
      with_file(bytes) do |path|
        [path, StringIO.new(bytes)].each do |source|
          error = assert_raises(CsvPreview::UnreadableInput, label) { sample(source) }
          assert_private(error, label)
          refute_includes error.message, File.basename(path), label if source.is_a?(String)
        end
      end
    end
  end

  def test_PS_33_timeout_never_quotes_the_input
    bytes = ("#{MARKER},b\n" * 100_000).b
    with_file(bytes) do |path|
      [path, StringIO.new(bytes)].each do |source|
        error = assert_raises(CsvPreview::TimeoutExceeded) { sample(source, timeout: 1e-9) }
        assert_private(error, "timeout")
      end
    end
  end

  def test_PS_33_timeout_from_the_parse_stage_never_quotes_the_input
    deadline = expiring_deadline(6)
    error = assert_raises(CsvPreview::TimeoutExceeded) do
      run_pipeline(StringIO.new("#{MARKER}\n" * 5_000), deadline)
    end
    assert_private(error, "parse timeout")
  end

  def test_PS_33_invalid_option_and_source_errors_do_not_quote_input_content
    error = assert_raises(ArgumentError) { sample(StringIO.new(MARKER), delimiter: MARKER) }
    refute_includes error.message, MARKER
    error = assert_raises(ArgumentError) { sample(Object.new) }
    refute_includes error.message, MARKER
  end
end
