# frozen_string_literal: true

require "test_helper"
require "csv"
require "stringio"
require_relative "support/fixtures"

# Parser internals: normalisation, Records (Ruby's csv inside the gem's bounds), recovery and the field
# guard (parsing-and-safety.md sections 4.2 to 4.8 and appendix A).
class ParserTest < Minitest::Test
  Parser = CsvPreview::Parser
  Records = CsvPreview::Parser::Records

  # Records with the test-only hooks of PS-31: every record's offset is checked against csv.line, and
  # the field guard limit and the quote-free switch can be changed.
  class CheckedRecords < Records
    attr_reader :offsets_checked

    def initialize(*args, field_limit: MAX_RECORD_FIELDS, quote_free: true, **options)
      @test_field_limit = field_limit
      @test_quote_free = quote_free
      @offsets_checked = 0
      super(*args, **options)
    end

    private

    def field_limit = @test_field_limit
    def last_quote_offset = @test_quote_free ? super : @text.bytesize

    def record_end(pos, line)
      start = skip_blank_lines(pos)
      raise "offset mismatch at #{start}" unless @text.byteslice(start, line.bytesize) == line

      @offsets_checked += 1
      super
    end
  end

  # A deadline that never expires and records each stage it was asked about.
  class RecordingDeadline
    attr_reader :stages

    def initialize = @stages = []
    def check!(stage) = @stages << stage
  end

  # A deadline that expires on its n-th check.
  class ExpiringDeadline
    def initialize(n) = @left = n

    def check!(stage)
      @left -= 1
      raise CsvPreview::TimeoutExceeded, "csv_preview exceeded its timeout (#{stage})" if @left <= 0
    end
  end

  def deadline = CsvPreview::Deadline.new(60)
  def cap_for(max_cell_chars = 60) = (8 * (max_cell_chars + 1)) + 64

  def records(text, complete: true, delimiter: ",", keep_rows: 21, keep_columns: 12, raw_cap: cap_for, klass: Records,
              **options)
    klass.new(text, complete: complete, delimiter: delimiter, keep_rows: keep_rows, keep_columns: keep_columns,
                    raw_cap: raw_cap, deadline: deadline, **options).call
  end

  def texts(result) = result.kept.map { |cells| cells.map(&:text) }

  # --- 4.2 ---

  def test_normalize_rewrites_line_breaks_in_place
    text = +"a\r\nb\rc\n\n\nd\r\n\r\n"
    assert_same text, Parser.normalize!(text)
    assert_equal "a\nb\nc\nd\n", text
    quoted = Parser.normalize!(+"\"a\r\nb\",c\r\n")
    assert_equal "\"a\nb\",c\n", quoted
  end

  # --- 4.3 to 4.5 ---

  def test_records_basics
    r = records("h1,h2\n\n1,\"a\nb\"\n,,\n  \n2,x,,\n")
    assert_equal [%w[h1 h2], ["1", "a\nb"], ["2", "x", "", ""]], texts(r)
    assert_equal [2, 2, 2], r.widths
    assert_equal 3, r.count
    assert_equal 2, r.max_width
    assert r.complete
    refute r.too_wide
    refute r.recovered
  end

  def test_records_keeps_only_what_it_is_asked_to
    r = records("a,b,c\n1,2,3\n4,5,6\n7,8,9,10\n", keep_rows: 2, keep_columns: 2)
    assert_equal [%w[a b], %w[1 2]], texts(r)
    assert_equal [2, 2], r.widths
    assert_equal 4, r.count
    assert_equal 4, r.max_width
  end

  def test_records_caps_raw_cells
    r = records("#{"é" * 300},b\n", raw_cap: cap_for(10))
    cell = r.kept[0][0]
    assert cell.capped
    assert_operator cell.text.bytesize, :<=, cap_for(10)
    assert cell.text.valid_encoding?
    refute r.kept[0][1].capped
  end

  def test_kept_only_stops_after_the_kept_records
    r = records("a\nb\nc\nd\n", keep_rows: 2, kept_only: true)
    assert_equal 2, r.count
  end

  def test_offsets_match_csv_line_on_every_record
    text = "a,b\n\"x\ny\",z\nq\n"
    [true, false].each do |quote_free|
      r = CheckedRecords.new(text, complete: true, delimiter: ",", keep_rows: 21, keep_columns: 12,
                                   raw_cap: cap_for, deadline: deadline, quote_free: quote_free)
      assert_equal 3, r.call.count
      assert_equal quote_free ? 2 : 3, r.offsets_checked
    end
  end

  def test_PS_36_feed_is_not_a_stringio_and_csv_calls_only_its_io_methods
    owner = Records.new("", complete: true, delimiter: ",", keep_rows: 1, keep_columns: 1, raw_cap: 100,
                            deadline: deadline)
    feed = Records::Feed.new("a,\"b\nc\"\n1,2\n", 0, owner, guard: false)
    refute_kind_of StringIO, feed
    called = []
    trace = TracePoint.new(:call, :c_call) { |tp| called << tp.method_id if tp.self.equal?(feed) }
    rows = trace.enable do
      csv = CSV.new(feed, col_sep: ",", row_sep: "\n", quote_char: "\"", liberal_parsing: true, skip_blanks: true)
      Array.new(3) { csv.shift }
    end
    assert_equal [["a", "b\nc"], %w[1 2], nil], rows
    io_methods = %i[gets eof? eof external_encoding internal_encoding]
    assert_equal io_methods.sort, Records::Feed.public_instance_methods(false).sort
    assert_includes called, :gets
    # Anything else csv calls on the feed is plain Object introspection (is_a?, nil?, respond_to?).
    (called.uniq - io_methods).each do |name|
      assert Object.method_defined?(name) || Object.private_method_defined?(name), name
    end
  end

  def test_feed_checks_the_deadline_before_every_chunk
    text = "x" * 40_000
    r = Records.new(text, complete: true, delimiter: ",", keep_rows: 1, keep_columns: 1, raw_cap: cap_for,
                          deadline: ExpiringDeadline.new(3))
    error = assert_raises(CsvPreview::TimeoutExceeded) { r.call }
    assert_includes error.message, "(parse)"
  end

  def test_parser_checkpoints
    recorder = RecordingDeadline.new
    result = CsvPreview::Reader::Result.new(text: +"a,b\n1,2\n", encoding: "UTF-8", complete: true, bytes_read: 8)
    Parser.call(result, config: CsvPreview.config.resolve, deadline: recorder)
    assert_includes recorder.stages, :sniff
    assert_includes recorder.stages, :parse
    assert_includes recorder.stages, :sanitize
    assert_equal 4, recorder.stages.count(:sniff)
  end

  # A deadline that expires at the first check of one named stage.
  class StageDeadline
    def initialize(stage) = @stage = stage

    def check!(stage)
      raise CsvPreview::TimeoutExceeded, "csv_preview exceeded its timeout (#{stage})" if stage == @stage
    end
  end

  def test_parser_raises_timeout_from_its_own_stages
    result = CsvPreview::Reader::Result.new(text: +"a,b\n1,2\n", encoding: "UTF-8", complete: true, bytes_read: 8)
    %i[sniff sanitize].each do |stage|
      error = assert_raises(CsvPreview::TimeoutExceeded, stage.to_s) do
        Parser.call(result, config: CsvPreview.config.resolve, deadline: StageDeadline.new(stage))
      end
      assert_includes error.message, "(#{stage})"
    end
  end

  def test_quote_free_switch_gives_the_same_rows
    text = "\"h\",\"i\"\n#{"a,b\n" * 3_000}"
    fast = records(text, klass: CheckedRecords)
    slow = records(text, klass: CheckedRecords, quote_free: false)
    assert_equal slow, fast
    assert_equal 3_001, fast.count
  end

  # --- 4.6 recovery ---

  def test_rule_3_stray_quote_is_read_literally
    r = records("Date,Desc,Amount\n2026-03-01,\"Coffee,4.50\n2026-03-02,Tea,3.00\n2026-03-03,Juice,5.25\n")
    assert_equal [
      %w[Date Desc Amount], ["2026-03-01", "\"Coffee", "4.50"], %w[2026-03-02 Tea 3.00], %w[2026-03-03 Juice 5.25]
    ], texts(r)
    assert r.complete
    assert r.recovered
  end

  def test_rule_1_then_rule_4
    # The guard stops a multi-line quoted field (rule 1, then rule 3 on its first line); the quote
    # opened later is rejected again, so the rest is read without quotes (rule 4).
    r = records("\"a,b\nc,d\ne,f\ng,h\"\n\"x\ny\n", klass: CheckedRecords, field_limit: 3, chunk_limit: 1)
    assert_equal [["\"a", "b"], %w[c d], %w[e f], ["g", "h\""], ["\"x"], ["y"]], texts(r)
    assert r.complete
    refute r.too_wide
    assert r.recovered
  end

  def test_paired_stray_quotes_become_one_cell
    r = records("a,\"b\nc,d\ne,\"f\ng,h\n")
    assert_equal [["a", "\"b\nc,d\ne,\"f"], %w[g h]], texts(r)
    refute r.recovered
  end

  def test_rule_3_line_pass_is_guarded
    r = records("\"a,b,c,d,e,f\"\n\"x\ny\n", klass: CheckedRecords, field_limit: 3, chunk_limit: 1)
    assert_equal [["\"a", "b", "c", "d", ""]], texts(r)
    refute r.complete
    assert r.too_wide
  end

  def test_rule_2_cut_tail_closes_the_open_quote
    r = records("a,b\n1,\"open quote, cut", complete: false)
    assert_equal [%w[a b], ["1", "open quote, cut"]], texts(r)
    refute r.complete
    assert r.recovered
  end

  # --- PS-31 ---

  FUZZ_ALPHABET = [
    "a", "é", "漢", "🙂", ",", ";", "\"", "\"", "\n", "\r\n", "\r", " ", "\t", "\u0000", "\u0001"
  ].freeze
  FUZZ_DELIMITERS = [",", ";", "\t", "|", "a", " ", "\u0001"].freeze

  def test_PS_31_property_fuzz
    iterations = Integer(ENV.fetch("CSV_PREVIEW_FUZZ_ITERATIONS", "3000"))
    # PS-31 asks for at least 20,000 inputs per run; CI sets that, local runs default to 3,000 for speed.
    assert_operator iterations, :>=, 20_000, "set CSV_PREVIEW_FUZZ_ITERATIONS to 20000 on CI" if ENV["CI"]
    seed = Integer(ENV.fetch("CSV_PREVIEW_FUZZ_SEED", "20261115"))
    rng = Random.new(seed)
    iterations.times do |i|
      input = Array.new(rng.rand(0..60)) { FUZZ_ALPHABET[rng.rand(FUZZ_ALPHABET.size)] }.join
      options = {
        complete: rng.rand(2).zero?, delimiter: FUZZ_DELIMITERS[rng.rand(FUZZ_DELIMITERS.size)],
        keep_rows: rng.rand(1..4) + 1, keep_columns: rng.rand(1..4), raw_cap: cap_for(rng.rand(1..8))
      }
      chunk = rng.rand(1..9)
      guard = rng.rand(1..6)
      fuzz_one(input, options, chunk, guard)
    rescue Minitest::Assertion, StandardError => e
      raise e.exception("fuzz input #{i} (seed #{seed}): #{input.inspect} #{options.inspect} chunk #{chunk} " \
                        "guard #{guard}: #{e.message}")
    end
  end

  def fuzz_one(input, options, chunk, guard)
    text = Parser.normalize!(input.dup)
    run = ->(**extra) { CheckedRecords.new(text, deadline: deadline, **options, **extra).call }
    first = run.call
    assert_fuzz_bounds(first, options)
    assert_equal first, run.call, "deterministic"
    assert_equal first, run.call(chunk_limit: chunk), "chunk size #{chunk}"
    assert_equal first, run.call(quote_free: false), "quote-free switch disabled"
    assert_fuzz_bounds(run.call(field_limit: guard), options)
    assert_equal text, Parser.normalize!(input.dup), "text not modified by Records"
  end

  def assert_fuzz_bounds(r, options)
    assert_operator r.kept.size, :<=, options[:keep_rows]
    assert_equal r.kept.size, r.widths.size
    r.kept.each do |cells|
      assert_operator cells.size, :<=, options[:keep_columns]
      cells.each do |cell|
        assert cell.text.valid_encoding?
        assert_equal Encoding::UTF_8, cell.text.encoding
        assert_operator cell.text.bytesize, :<=, options[:raw_cap]
      end
    end
    r.widths.each { |w| assert_includes 1..options[:keep_columns], w }
    assert_equal r.count.zero?, r.max_width.zero?
    refute r.complete unless options[:complete]
  end

  # --- PS-34 ---

  def cut_sweep
    text = File.binread(Fixtures.generate("cut_sweep.csv")).force_encoding(Encoding::UTF_8)
    strict = CSV.parse(text).map { |row| row.map(&:to_s) }
    ends = []
    csv = CSV.new(text)
    pos = 0
    while csv.shift
      pos += csv.line.bytesize
      ends << pos
    end
    [text, strict, ends]
  end

  # Every offset when CSV_PREVIEW_CUT_SWEEP=full (a few minutes). By default, to keep the run fast: every
  # offset up to the end of the 22nd record (the kept records with their multi-line memos, where rule 3
  # applies), every offset in the last 64 bytes, and every 101st offset in between.
  def sweep_offsets(size, ends)
    return (0..size).to_a if ENV["CSV_PREVIEW_CUT_SWEEP"] == "full"

    head = ends[21]
    ((0..head).to_a + ((head + 1)...(size - 64)).step(101).to_a + ((size - 64)..size).to_a).uniq
  end

  def test_PS_34_cut_sweep
    text, strict, ends = cut_sweep
    assert_equal 400, strict.size
    width = strict.map(&:size).max
    sweep_offsets(text.bytesize, ends).each do |k|
      prefix = text.byteslice(0, k)
      complete_records = ends.count { |e| e <= k }
      [21, 3].each do |keep_rows|
        r = records(prefix, complete: false, keep_rows: keep_rows)
        message = "cut at #{k}, keep_rows #{keep_rows}"
        assert_operator r.max_width, :<=, width, message
        assert_operator r.count, :>=, complete_records, message
        assert_operator r.count, :<=, complete_records + 1, message if keep_rows == 3
        n = [complete_records, r.kept.size].min
        assert_equal strict.first(n), texts(r).first(n), message
        refute r.complete, message
      end
    end
  end

  def test_PS_34_crlf_export_cut_inside_a_quoted_field_on_its_last_line
    header = (1..23).map { |i| "Column #{i}" }.join(",")
    row = ->(i) { ([i, "2026-03-14", "\"-$1,284.50\"", "Shop #{i}"] + (5..23).map { |c| "v#{c}" }).join(",") }
    text = +"#{header}\r\n"
    i = 0
    text << "#{row.call(i += 1)}\r\n" while text.bytesize < 2_097_152 - 400
    last = "#{i + 1},2026-03-14,\"-$1,"
    text << last << ("9" * 1_000) << "\"\r\n"
    cut = 2_097_152
    assert_operator text.bytesize, :>, cut

    s = CsvPreview.sample(StringIO.new(text))
    assert_equal 23, s.total_columns
    assert_nil s.total_rows
    assert s.rows_truncated?

    prefix = Parser.normalize!(text.byteslice(0, cut))
    r = records(prefix, complete: false, keep_rows: i + 2, keep_columns: 23)
    assert_equal i + 2, r.count
    assert_equal 23, r.max_width
    assert r.recovered
    partial = texts(r).last
    assert_equal [(i + 1).to_s, "2026-03-14", "-$1,#{"9" * (cut - (text.bytesize - 1_003))}"], partial
  end

  def test_PS_34_one_long_line_cut_inside_a_quote
    r = records("#{"\"a,b\"," * 10}\"cut,here", complete: false)
    assert_equal [["a,b"] * 10 + ["cut,here"]], texts(r)
    assert_equal 11, r.max_width
    assert_equal 1, r.count
    s = CsvPreview.sample(StringIO.new("#{"\"a,b\"," * 10}\"cut,here,and more"), max_input_bytes: 69,
                                                                             header_row: false)
    assert_equal [["a,b"] * 10 + ["cut,here"]], s.rows
    assert_equal 11, s.total_columns
    assert_nil s.total_rows
  end

  # --- PS-35 ---

  def test_PS_35_stray_quote_wide
    path = Fixtures.generate("stray_quote_wide.csv")
    text = Parser.normalize!(File.binread(path).force_encoding(Encoding::UTF_8))
    r = records(text)
    assert_equal 349_526, r.count
    assert_equal 3, r.max_width
    assert r.complete
    refute r.too_wide
    assert r.recovered
    assert_equal [["a", "\"x"], %w[1 2 3]], texts(r).first(2)

    s = CsvPreview.sample(path, max_input_bytes: File.size(path), header_row: false)
    assert_equal 349_526, s.total_rows
    assert_equal 3, s.total_columns
  end

  def test_PS_35_guard_stops_inside_a_record_of_multi_line_fields
    text = "\"\n\"," * 524_288
    r = records(+text)
    refute r.complete
    assert r.too_wide
    s = CsvPreview.sample(StringIO.new(text))
    assert_nil s.total_rows
  end

  def test_field_guard_stops_a_very_wide_record
    text = "#{"x," * 100_000}x\n1,2\n"
    r = records(text)
    refute r.complete
    assert r.too_wide
    assert_equal 1, r.count
    assert_operator r.max_width, :>, 57_344
    assert_operator r.max_width, :<, 81_921
  end
end
