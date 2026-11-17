# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "support/child_ruby"
require_relative "support/fixtures"
require_relative "support/wide_long"

# CsvPreview.sample and the Sample value object (parsing-and-safety.md sections 4.7 to 4.12 and 11).
class SampleApiTest < Minitest::Test
  BINARY_FIXTURES = %w[
    png_renamed.csv gif_renamed.csv jpeg_renamed.csv pdf_renamed.csv zip_renamed.csv xlsx_renamed.csv
    xls_renamed.csv gzip_renamed.csv
  ].freeze
  BIDI_CONTROLS = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/

  def sample(source, **options) = CsvPreview.sample(source, **options)
  def fixture(name, **options) = sample(Fixtures.path(name), **options)
  def text(string, **options) = sample(StringIO.new(string.b), **options)

  def assert_empty_sample(s, delimiter: ",", encoding: "UTF-8")
    assert s.empty?
    assert_nil s.headers
    assert_equal [], s.rows
    assert_equal 0, s.column_count
    assert_equal 0, s.total_columns
    assert_equal 0, s.rows_read
    assert_equal 0, s.total_rows
    refute s.rows_truncated?
    refute s.columns_truncated?
    assert_equal [], s.column_kinds
    assert_equal delimiter, s.delimiter
    assert_equal encoding, s.encoding
  end

  # --- PS-1 ---

  def test_PS_1_wide_long_counts
    s = fixture("wide_long.csv")
    assert_equal 12, s.column_count
    assert_equal 31, s.total_columns
    assert_equal 20, s.rows.size
    assert_equal 1_284, s.rows_read
    assert_equal 1_284, s.total_rows
    assert s.rows_truncated?
    assert s.columns_truncated?
    assert_equal WideLong::HEADER.first(12), s.headers
    assert(s.rows.all? { |r| r.size == 12 })
    assert_equal ",", s.delimiter
  end

  def test_PS_1_wide_long_fixture_matches_its_generator
    assert_equal WideLong.generate.b, File.binread(Fixtures.path("wide_long.csv"))
  end

  # --- PS-5 ---

  def test_PS_5_semicolon_decimal_comma
    s = fixture("semicolon_decimal_comma.csv")
    assert_equal ";", s.delimiter
    assert_equal %w[Datum Beschreibung Betrag Saldo], s.headers
    assert_equal ["14.03.2026", "Kaffee, Bäckerei", "-4,50", "1.284,50"], s.rows[0]
    assert_equal ["12.03.2026", "Miete", "-1.284,50", "-1.211,00"], s.rows[2]
    assert_equal %i[text text number number], s.column_kinds
  end

  def test_PS_5_semicolon_two_columns_with_decimal_commas
    s = fixture("semicolon_2col_decimal.csv")
    assert_equal ";", s.delimiter
    assert_nil s.headers
    assert_equal [["1,5", "2,5"], ["3,5", "4,5"], ["10,25", "7,75"]], s.rows
  end

  def test_PS_5_tabs
    s = fixture("tabs.tsv")
    assert_equal "\t", s.delimiter
    assert_equal %w[Name City Note], s.headers
    assert_equal ["Alice", "Seattle, WA", "Likes tea, coffee"], s.rows[0]
  end

  def test_PS_5_pipes
    s = fixture("pipes.csv")
    assert_equal "|", s.delimiter
    assert_equal %w[id name amount], s.headers
    assert_equal ["3", "Thing; small", "1.00"], s.rows[2]
  end

  def test_PS_5_single_column
    s = fixture("single_column.csv")
    assert_equal ",", s.delimiter
    assert_equal ["Name"], s.headers
    assert_equal [["Alice"], ["Bob"], ["Carol"]], s.rows
  end

  def test_PS_5_explicit_delimiter_gives_the_same_cells
    auto = fixture("semicolon_decimal_comma.csv")
    explicit = fixture("semicolon_decimal_comma.csv", delimiter: ";")
    assert_equal auto, explicit
  end

  def test_sniffing_cases_of_section_4_9
    statement = +"Date,Description,Amount,Balance\n"
    20.times { |i| statement << "2026-03-#{10 + i},Store #{i},\"-$1,#{100 + i}.50\",\"$12,#{300 + i}.00\"\n" }
    {
      statement => ",",
      "Datum;Betrag\n14.03.2026;-1.284,50\n15.03.2026;12,00\n" => ";",
      "1,5;2,5\n3,5;4,5\n" => ";",
      "Name;Amount\nFoo, Inc;1,50\n" => ";",
      "a\tb, c\td\ne\tf, g\th\n" => "\t",
      "a|b|c\n1|2|3\n" => "|",
      "one\ntwo\nthree\n" => ",",
      "name,note\nAda,likes; semicolons\nBob,uses; them; too\n" => ",",
      "\"a;b\",c\n\"d;e\",f\n" => ",",
      "a,b,c\n1,\"2,3\n4,5,6\n7,8,9\n" => ","
    }.each do |input, expected|
      assert_equal expected, text(input).delimiter, input.inspect
    end
  end

  # --- PS-6 ---

  def test_PS_6_quoted_newlines
    s = fixture("quoted_newlines.csv")
    assert_equal %w[id note amount], s.headers
    assert_equal [
      ["1", "Line one Line two", "10"],
      ["2", "Has, comma", "20"],
      ["3", "Say \"hi\"", "30"],
      ["4", "", "40"],
      ["5", "a b c", "50"]
    ], s.rows
    assert_equal 5, s.total_rows
  end

  def test_PS_6_mixed_line_endings
    s = fixture("mixed_line_endings.csv")
    assert_equal %w[a b c], s.headers
    assert_equal [%w[1 2 3], %w[4 5 6], %w[7 8 9], %w[10 11 12], %w[13 14 15]], s.rows
    assert_equal 5, s.rows_read
    lf_only = File.binread(Fixtures.path("mixed_line_endings.csv")).gsub(/\r\n?/n, "\n")
    assert_equal text(lf_only), s
  end

  # --- PS-7 ---

  def test_PS_7_ragged
    s = fixture("ragged.csv")
    assert_equal 5, s.total_columns
    assert_equal 5, s.column_count
    assert_nil s.headers
    assert_equal [["a", "b", "", "", ""], %w[c d e f g], ["h", "i", "j", "", ""]], s.rows
    refute s.columns_truncated?
  end

  def test_PS_7_unbalanced_quote
    s = fixture("unbalanced_quote.csv")
    assert_equal %w[Date Desc Amount], s.headers
    assert_equal [
      ["2026-03-01", "\"Coffee", "4.50"],
      ["2026-03-02", "Tea", "3.00"],
      ["2026-03-03", "Juice", "5.25"]
    ], s.rows
    assert_equal 3, s.rows_read
    assert_equal 3, s.total_rows
  end

  def test_PS_7_junk_after_quote
    s = fixture("junk_after_quote.csv")
    assert_equal %w[id text more], s.headers
    assert_equal [
      ["1", "\"Big\" Bob's Diner", "x"],
      ["2", "\"a,b\" c", "d"],
      ["3", "5\" monitor", "a\"\"b"],
      ["4", "\"Smith", "John\""]
    ], s.rows
  end

  def test_lenient_results_of_section_4_7
    s = text("\"a\" ,b\n\"x\"\"y\",\"p,q\"\n", header_row: false)
    assert_equal [["\"a\"", "b"], ["x\"y", "p,q"]], s.rows
    s = text("a,b,c,,,\n,,\n \t, \n1,,\n", header_row: false)
    assert_equal 3, s.total_columns
    assert_equal [%w[a b c], ["1", "", ""]], s.rows
    assert_equal 2, s.rows_read
  end

  # --- PS-8 and section 4.12 ---

  def test_PS_8_header_only
    s = fixture("header_only.csv")
    assert_equal %w[Name Amount Date], s.headers
    assert_equal [], s.rows
    refute s.empty?
    assert_equal 0, s.rows_read
    assert_equal 0, s.total_rows
    assert_equal 3, s.column_count
  end

  def test_PS_8_blank_lines
    s = fixture("blank_lines.csv")
    assert_equal %w[Name Amount], s.headers
    assert_equal [%w[Coffee 4.50], %w[Tea 3.00], %w[Juice 5.25]], s.rows
    assert_equal 3, s.rows_read
    assert_equal 2, s.total_columns
  end

  def test_PS_8_empty_shapes
    %w[whitespace_only.csv delimiters_only.csv empty.csv].each do |name|
      assert_empty_sample(fixture(name))
    end
  end

  def test_PS_8_single_row_data
    s = fixture("single_row_data.csv")
    assert_nil s.headers
    assert_equal [["Coffee", "4.50", "2026-03-14"]], s.rows
    assert_equal 1, s.rows_read
  end

  def test_empty_input_rules_of_section_4_12
    assert_empty_sample(text(""))
    assert_empty_sample(text("\xEF\xBB\xBF"))
    assert_empty_sample(text(" \t\r\n\r\n \n"))
    assert_empty_sample(text(",,,\n,,"))
    assert_empty_sample(text("", delimiter: ";", encoding: "Windows-1252"), delimiter: ";", encoding: "Windows-1252")
  end

  # --- PS-10 ---

  def test_PS_10_header_row_option
    auto = fixture("numbers.csv")
    forced = fixture("numbers.csv", header_row: true)
    none = fixture("numbers.csv", header_row: false)
    header = %w[Item Amount Price Change Other Note]
    assert_equal header, auto.headers
    assert_equal auto.headers, forced.headers
    assert_nil none.headers
    assert_equal header, none.rows[0]
    assert_equal auto.rows, none.rows.drop(1)
    assert_equal auto.rows_read + 1, none.rows_read
  end

  def test_header_detection_cases_of_section_4_10
    {
      "Name,Amount,Date\n" => true,
      "Coffee,4.50,2026-03-14\n" => false,
      "Item,Amount\nTea,3.00\nJuice,5.25\n" => true,
      "Date,Item\n2026-03-14,Tea\n2026-03-15,Juice\n" => true,
      "1,2,3\n4,5,6\n7,8,9\n" => false,
      "2026-03-14,Tea,3.00\n2026-03-15,Juice,5.25\n" => false,
      "Name\nAlice\nBob\nCarol\n" => true,
      "a,a\nb,c\nd,e\n" => false,
      ",Amount\nTea,3.00\nJuice,5.25\n" => true,
      "Alice,Smith\nBob,Jones\n" => true
    }.each do |input, header|
      assert_equal header, !text(input).headers.nil?, input.inspect
    end
  end

  def test_header_row_true_on_empty_input_gives_no_header
    assert_empty_sample(text("\n\n", header_row: true))
  end

  # --- PS-11 to PS-16 (sample halves) ---

  def test_PS_11_number_columns
    s = fixture("numbers.csv")
    assert_equal %i[text number number number number text], s.column_kinds
    s.rows.each do |row|
      row[1..4].each { |cell| assert_equal :number, CsvPreview::CellKind.cell(cell), cell.inspect }
    end
  end

  def test_PS_12_identifier_columns_are_text
    s = fixture("identifiers.csv")
    assert_equal ["ZIP", "MCC", "Last 4", "Reference", "Phone", "Date", "Year"], s.headers
    assert_equal [:text] * 7, s.column_kinds
  end

  def test_PS_13_formulas_are_literal
    s = fixture("formulas.csv")
    assert_equal [
      "=HYPERLINK(\"http://example.com\",\"x\")", "+cmd|' /C calc'!A0", "@SUM(A1:A2)", "-2+3"
    ], s.rows.map(&:first)
    assert_equal :text, CsvPreview::CellKind.cell("-2+3")
    assert_equal ",", s.delimiter
  end

  def test_PS_14_markup_is_literal
    s = fixture("markup.csv")
    assert_equal ["<b>bold</b>", "&amp;", "<span foreground=\"red\">x</span>", "a & b"], s.rows.map(&:first)
  end

  def test_PS_15_bidi_controls_removed
    s = fixture("bidi.csv")
    assert_equal [
      %w[rlo 00.001$], %w[lro abc], %w[embeddings abc], %w[isolates abcd], %w[marks xyz],
      ["family", "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"]
    ], s.rows
    s.rows.flatten.each { |cell| refute_match BIDI_CONTROLS, cell }
  end

  def test_PS_16_controls
    s = fixture("controls.csv")
    assert_equal [
      %w[esc_bel abc], %w[del ab], ["nel", "a b"], %w[c1 ab], ["vt_ff", "a b c"], ["separators", "a b c"],
      ["tabs", "a b c"], %w[zwsp ab], %w[inner_bom ab], ["zalgo", "Z#{"\u0301" * 8}a"]
    ], s.rows
  end

  def test_PS_16_nul_after_window
    s = sample(Fixtures.generate("nul_after_window.csv"), max_rows: 3_000)
    assert_equal %w[xy z], s.rows.last
    assert_equal 2_501, s.rows_read
  end

  # --- PS-17 ---

  def test_PS_17_long_cells
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    s = sample(Fixtures.generate("long_cell.csv"))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
    ascii, multibyte = s.rows.map(&:last)
    assert_equal "#{"abcdefghij" * 5}abcdefghi…", ascii
    assert_equal "#{"é" * 59}…", multibyte
    [ascii, multibyte].each { |cell| assert_equal 60, cell.each_grapheme_cluster.count }
  end

  # --- PS-32 ---

  def test_PS_32_sampling_twice_gives_equal_samples
    Dir.glob(File.join(Fixtures::CHECKED_IN, "*")).sort.each do |path|
      name = File.basename(path)
      if BINARY_FIXTURES.include?(name)
        assert_raises(CsvPreview::UnreadableInput, name) { sample(path) }
      else
        assert_equal sample(path), sample(path), name
      end
    end
    %w[nul_after_window.csv long_cell.csv stray_quote_wide.csv cut_sweep.csv].each do |name|
      path = Fixtures.generate(name)
      assert_equal sample(path), sample(path), name
    end
  end

  # --- Review focus ---

  def test_excel_sep_directive
    s = CsvPreview.sample(StringIO.new("sep=;\nName;Amount\nTea;3,50\n"))
    assert_equal ";", s.delimiter
    assert_equal ["Name", "Amount"], s.headers
    assert_equal [["Tea", "3,50"]], s.rows
  end

  def test_excel_sep_directive_details
    s = text("\xEF\xBB\xBFsep=|\r\nName|Amount\r\nTea|3,50\r\n")
    assert_equal "|", s.delimiter
    assert_equal [["Tea", "3,50"]], s.rows
    assert_equal 1, s.rows_read

    s = text("sep=;\nName;Amount\nTea;3,50\n", header_row: false)
    assert_equal [%w[Name Amount], ["Tea", "3,50"]], s.rows
    assert_equal 2, s.rows_read

    explicit = text("sep=;\nName;Amount\n", delimiter: ";", header_row: false)
    assert_equal [["sep=", ""], %w[Name Amount]], explicit.rows

    later = text("Name;Amount\nsep=,\nTea;3,50\n", header_row: false)
    assert_equal ";", later.delimiter
    assert_equal ["sep=,", ""], later.rows[1]

    refused = text("sep=\"\na,b\n", header_row: false)
    assert_equal ",", refused.delimiter
    assert_equal ["sep=\"", ""], refused.rows[0]
  end

  def test_blank_and_duplicate_headers
    s = CsvPreview.sample(StringIO.new(",Amount,Amount\nx,1,2\n"), header_row: true)
    assert_equal ["", "Amount", "Amount"], s.headers
    assert_equal [["x", "1", "2"]], s.rows
  end

  # --- Sample value object and the entry point ---

  def test_sample_is_a_frozen_value_object
    s = fixture("simple.csv")
    assert s.frozen?
    assert s.headers.frozen?
    assert s.rows.frozen?
    assert(s.rows.all? { |r| r.frozen? && r.all?(&:frozen?) })
    assert s.headers.all?(&:frozen?)
    assert s.column_kinds.frozen?
    assert s.delimiter.frozen?
    assert s.encoding.frozen?
    assert_equal fixture("simple.csv"), s
    assert_equal fixture("simple.csv").hash, s.hash
    assert s.eql?(fixture("simple.csv"))
    refute_equal fixture("simple.csv", max_rows: 2), s
  end

  def test_sample_members
    s = fixture("simple.csv")
    assert_equal %w[Fruit Qty Price], s.headers
    assert_equal [%w[Apple 3 1.20], %w[Banana 12 0.50], %w[Cherry 7 4.75], %w[Durian 1 9.99]], s.rows
    assert_equal 3, s.column_count
    assert_equal 3, s.total_columns
    assert_equal 4, s.total_rows
    assert_equal 4, s.rows_read
    refute s.rows_truncated?
    refute s.columns_truncated?
    assert_equal %i[text number number], s.column_kinds
    assert_equal ",", s.delimiter
    assert_equal "UTF-8", s.encoding
    refute s.empty?
  end

  def test_truncation_flags_and_padding
    s = fixture("simple.csv", max_rows: 2, max_columns: 2)
    assert_equal %w[Fruit Qty], s.headers
    assert_equal [%w[Apple 3], %w[Banana 12]], s.rows
    assert_equal 2, s.column_count
    assert_equal 3, s.total_columns
    assert_equal 4, s.rows_read
    assert s.rows_truncated?
    assert s.columns_truncated?
  end

  def test_cut_input_has_unknown_total_rows
    s = fixture("simple.csv", max_input_bytes: 30)
    assert_nil s.total_rows
    assert s.rows_truncated?
    assert_operator s.rows_read, :>=, 1
  end

  def test_max_cell_chars_applies_to_every_cell
    s = text("Name,Note\nAda,#{"x" * 100}\n", max_cell_chars: 5)
    assert_equal "xxxx…", s.rows[0][1]
  end

  def test_sample_checks_the_deadline
    error = assert_raises(CsvPreview::TimeoutExceeded) { fixture("wide_long.csv", timeout: 1e-9) }
    refute_includes error.message, "TXN"
  end

  def test_invalid_options_raise_before_reading
    io = Object.new
    def io.read(*) = raise("must not be read")
    assert_raises(ArgumentError) { sample(io, delimiter: "ab") }
  end

  def test_sample_works_without_libvips_and_never_loads_it
    out, err, status = ChildRuby.run(<<~RUBY)
      module NoVips
        private def require(name)
          raise LoadError, "cannot load such file -- vips" if name == "vips"

          super
        end
      end
      Kernel.prepend(NoVips)

      require "csv_preview"
      s = CsvPreview.sample(#{Fixtures.path("simple.csv").inspect})
      print s.headers.inspect, " ", s.rows.size, " ", $LOADED_FEATURES.any? { |f| f.include?("/vips") }
    RUBY
    assert status.success?, err
    assert_equal '["Fruit", "Qty", "Price"] 4 false', out
  end
end
