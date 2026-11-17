# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "support/fixtures"

class LayoutTest < Minitest::Test
  Layout = CsvPreview::Layout
  Theme = CsvPreview::Theme
  MINUS = "−"
  ELLIPSIS = "…"
  # Pixel values that depend on glyph widths were measured on macOS; other platforms may differ by a
  # pixel or a column.
  MACOS = RUBY_PLATFORM.include?("darwin")

  # Theme::LEDGER at the default scale 2 (rendering.md 2.2 and 6.1), device px.
  FRAME = 2
  HEADER = 72
  ROW = 72
  FOOTER = 72
  PAD = 24
  EDGE = 40
  INSET = 16
  FADE = 144
  PEEK = 240
  MIN_COLUMN = 112
  MAX_COLUMN = 520
  MIN_WIDTH = 640
  MAX_WIDTH = 2048

  def layout(fixture, **options) = CsvPreview.layout(Fixtures.path(fixture), **options)
  def layout_of(text, **options) = CsvPreview.layout(StringIO.new(text), **options)

  def build(sample, theme: Theme::LEDGER, deadline: nil, **options)
    config = CsvPreview.config.resolve(**options)
    Layout.build(sample, config: config, theme: theme, deadline: deadline || CsvPreview::Deadline.new(config.timeout))
  end

  # A Sample built directly, for counts no small file can produce.
  def sample(rows:, headers: nil, total_columns: nil, total_rows: rows.size, rows_read: rows.size,
             rows_truncated: false, kinds: nil)
    column_count = (rows.first || headers).size
    total_columns ||= column_count
    CsvPreview::Sample.new(
      headers: headers, rows: rows, column_count: column_count, total_columns: total_columns,
      total_rows: total_rows, rows_read: rows_read, rows_truncated: rows_truncated,
      columns_truncated: total_columns > column_count, column_kinds: kinds || Array.new(column_count, :text),
      delimiter: ",", encoding: "UTF-8", empty: false
    )
  end

  def short_rows(count, columns) = Array.new(count) { |r| Array.new(columns) { |c| "r#{r}c#{c}" } }

  # --- REN-2 alignment --------------------------------------------------------------------------

  def test_REN_2_alignment_follows_column_kinds
    l = layout("numbers.csv")
    assert_equal 6, l.visible_columns
    assert_equal %i[text number number number number text], l.columns.map(&:kind)
    assert_equal %i[left right right right right left], l.columns.map(&:align)
    l.columns.each do |column|
      assert_equal l.sample.column_kinds[column.index], column.kind
      assert_equal(column.kind == :number ? :right : :left, column.align)
    end
  end

  def test_REN_2_number_columns_share_one_right_edge
    l = layout("numbers.csv")
    l.columns.select { |c| c.align == :right }.each do |column|
      right = column.x_px + column.width_px - PAD
      header = l.header_placement(column.index)
      cells = (0...l.rows_shown).filter_map { |r| l.cell_placement(r, column.index) }
      assert_equal l.rows_shown, cells.size

      # Logical edges coincide exactly; ink edges stop short of them by the glyphs' side bearings
      # (a closing parenthesis by 3 px at 26 px), and SemiBold "t" overshoots by 1 px.
      [header, *cells].each do |placement|
        assert_equal :right, placement.run.align
        assert_equal right, placement.x + placement.run.extent, "logical right edge of #{placement.run.string}"
        assert_in_delta right, placement.x + placement.run.image.width, MACOS ? 3 : 4, "ink of #{placement.run.string}"
      end
    end
  end

  def test_text_columns_start_at_the_text_left_edge
    l = layout("simple.csv")
    column = l.columns[0]
    placement = l.cell_placement(0, 0)
    assert_equal column.x_px + PAD + placement.run.xoffset, placement.x
  end

  # --- REN-3 true minus ---------------------------------------------------------------------------

  def test_REN_3_true_minus_in_number_cells_only
    l = layout("minus.csv")
    assert_equal %i[number text], l.sample.column_kinds
    assert_equal ["#{MINUS}12.00", "#{MINUS}$0.99", "$#{MINUS}12.00", "12.00#{MINUS}", "(45.00)",
                  "1.234,56 €", "-"], (0...7).map { |r| l.cell_text(r, 0) }
    assert_equal ["-2+3", "x < y & z", "<b>bold</b>", "", "", "", ""], (0...7).map { |r| l.cell_text(r, 1) }
    assert_equal ["Amount", "Note"], [l.header_text(0), l.header_text(1)]
  end

  def test_true_minus_follows_the_theme
    l = build(CsvPreview.sample(Fixtures.path("minus.csv")), theme: Theme::LEDGER.with(true_minus: false))
    assert_equal ["-12.00", "-$0.99", "$-12.00", "12.00-"], (0...4).map { |r| l.cell_text(r, 0) }
  end

  # --- REN-7 truncation ---------------------------------------------------------------------------

  def test_REN_7_text_cells_are_truncated_by_measuring
    l = CsvPreview.layout(Fixtures.generate("long_text.csv"), header_row: true)
    assert_equal 20, l.rows_shown
    assert_operator l.visible_columns, :>=, 3
    l.columns.each do |column|
      assert_equal :text, column.kind
      assert_operator column.width_px, :>=, MAX_COLUMN, "60-character text reaches the cap"
      checks = (0...l.rows_shown).map { |r| [l.cell_text(r, column.index), l.sample.rows[r][column.index], l.cell_placement(r, column.index)] }
      checks << [l.header_text(column.index), l.sample.headers[column.index], l.header_placement(column.index)]
      checks.each do |text, source, placement|
        assert text.end_with?(ELLIPSIS), text
        prefix = text.delete_suffix(ELLIPSIS).grapheme_clusters
        assert_equal source.grapheme_clusters.first(prefix.size), prefix, "a grapheme-cluster prefix of the source"
        refute_match(/ \z/, prefix.join, "no space before the ellipsis")
        assert_equal text, placement.run.string
        assert_operator placement.run.extent, :<=, column.width_px - 2 * PAD
      end
    end
  end

  def test_REN_7_a_100_000_character_cell_lays_out_in_under_a_second
    path = Fixtures.generate("long_cell.csv")
    CsvPreview.layout(path) # warm the fonts and the libvips cache-free path once
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    l = CsvPreview.layout(path)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
    assert l.cell_text(0, 1).end_with?(ELLIPSIS)
    assert_operator l.cell_placement(0, 1).run.extent, :<=, l.columns[1].width_px - 2 * PAD
  end

  # --- REN-8 numbers never truncate ---------------------------------------------------------------

  def test_REN_8_numbers_are_never_truncated
    l = layout_of(%(Item,Amount\nBig,"-$1,234,567,890.12"\nSmall,$1.00\n))
    assert_equal :right, l.columns[1].align
    assert_equal "#{MINUS}$1,234,567,890.12", l.cell_text(0, 1)
    placement = l.cell_placement(0, 1)
    assert_equal l.cell_text(0, 1), placement.run.string
    assert_operator placement.run.extent, :<=, l.columns[1].width_px - 2 * PAD
  end

  def test_REN_8_number_columns_grow_past_the_text_cap
    huge = "-$1,234,567,890,123,456,789,012,345.12"
    l = layout_of(%(Item,Amount\nBig,"#{huge}"\nSmall,$1.00\n))
    column = l.columns[1]
    assert_equal :number, column.kind
    assert_equal huge.tr("-", MINUS), l.cell_text(0, 1)
    assert_operator column.width_px, :>, MAX_COLUMN
    assert_equal l.cell_placement(0, 1).run.extent + 2 * PAD, column.width_px
  end

  def test_long_header_over_a_number_column_is_capped_like_text
    header = "Amount in the original currency before every fee and tax was applied"
    l = layout_of(%(Item,#{header}\nCoffee,1.00\nTea,2.00\n), header_row: true)
    assert_equal MAX_COLUMN, l.columns[1].width_px
    assert l.header_text(1).end_with?(ELLIPSIS)
    assert_equal ["1.00", "2.00"], [l.cell_text(0, 1), l.cell_text(1, 1)]
  end

  # --- step 3: natural widths ---------------------------------------------------------------------

  def test_natural_column_widths
    l = layout("numbers.csv") # wider than min_width, so nothing is distributed
    assert_operator l.width_px, :>, MIN_WIDTH
    assert_equal 2 * INSET + l.columns.sum(&:width_px), l.width_px
    l.columns.each do |column|
      cells = (0...l.rows_shown).filter_map { |r| l.cell_placement(r, column.index)&.run&.extent }.max || 0
      header = l.header_placement(column.index)&.run&.extent || 0
      expected = if column.kind == :number
                   [[cells, [header, MAX_COLUMN - 2 * PAD].min].max + 2 * PAD, MIN_COLUMN].max
                 else
                   ([cells, header].max + 2 * PAD).clamp(MIN_COLUMN, MAX_COLUMN)
                 end
      assert_equal expected, column.width_px, l.header_text(column.index)
    end
  end

  def test_columns_are_contiguous_from_the_inset
    l = layout("statement.csv")
    x = INSET
    l.columns.each do |column|
      assert_equal x, column.x_px
      assert_equal column.width_px / 2.0, column.width
      assert_instance_of Float, column.width
      x += column.width_px
    end
    assert_equal x, l.peek_column.x_px
  end

  # --- REN-9 footer -------------------------------------------------------------------------------

  def test_REN_9_footer_nil_when_nothing_is_hidden
    l = layout("simple.csv")
    assert_nil l.footer_text
    assert_nil l.footer_placement
    assert_equal FRAME * 2 + HEADER + 4 * ROW, l.height_px
  end

  def test_REN_9_footer_wording_statement
    l = layout("statement.csv")
    assert_match(/\A20 rows · (\d+) of 23 columns\z/, l.footer_text)
    assert_equal l.visible_columns, l.footer_text[/(\d+) of 23/, 1].to_i
    assert_equal 7, l.visible_columns if MACOS
  end

  def test_statement_fixture_is_the_mockup_data
    mockup = File.expand_path("../docs/design/mockups/statement.csv", __dir__)
    assert_equal File.binread(mockup), File.binread(Fixtures.path("statement.csv"))
  end

  def test_REN_9_footer_wording_wide_long
    l = layout("wide_long.csv")
    assert_match(/\A20 of 1,284 rows · (\d+) of 31 columns\z/, l.footer_text)
    assert_equal l.visible_columns, l.footer_text[/(\d+) of 31/, 1].to_i
  end

  def test_REN_9_footer_wording_max_columns
    assert_equal "4 rows · 2 of 3 columns", layout("simple.csv", max_columns: 2).footer_text
    assert_equal "1 row · 1 of 3 columns", layout_of("a,b,c\n1,2,3\n", max_columns: 1, header_row: true).footer_text
  end

  def test_REN_9_footer_wording_total_unknown
    l = CsvPreview.layout(Fixtures.generate("five_mb.csv"))
    assert_nil l.sample.total_rows
    assert_match(/\A20 of [\d,]+\+ rows · /, l.footer_text)
    assert_equal "20 of #{l.sample.rows_read.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}+ rows · 3 columns",
                 l.footer_text
  end

  def test_REN_9_footer_wording_every_case
    six = Array.new(6, :text)
    cases = {
      "4 rows · 2 of 6 columns" => sample(rows: short_rows(4, 2), total_columns: 6),
      "1 row · 1 of 3 columns" => sample(rows: short_rows(1, 1), total_columns: 3),
      "20 of 1,284 rows · 6 columns" => sample(rows: short_rows(20, 6), total_rows: 1_284, rows_read: 1_284,
                                                   rows_truncated: true, kinds: six),
      "20 of 1,234,567 rows · 1 column" => sample(rows: short_rows(20, 1), total_rows: 1_234_567,
                                                      rows_read: 1_234_567, rows_truncated: true),
      "20 of 18,402+ rows · 6 columns" => sample(rows: short_rows(20, 6), total_rows: nil, rows_read: 18_402,
                                                     rows_truncated: true, kinds: six),
      "20+ rows · 6 columns" => sample(rows: short_rows(20, 6), total_rows: nil, rows_read: 20,
                                           rows_truncated: true, kinds: six),
      "1+ rows · 1 column" => sample(rows: short_rows(1, 1), total_rows: nil, rows_read: 1, rows_truncated: true)
    }
    cases.each { |expected, s| assert_equal expected, build(s).footer_text }
    assert_nil build(sample(rows: short_rows(4, 6))).footer_text
  end

  def test_rows_hidden_by_the_height_cap
    l = layout("statement.csv", max_height_px: 999)
    assert_equal 11, l.rows_shown # (999 - 4 - 72 - 72) / 72
    assert_match(/\A11 of 20 rows · \d+ of 23 columns\z/, l.footer_text)
    assert_equal FRAME * 2 + HEADER + 11 * ROW + FOOTER, l.height_px
  end

  def test_footer_is_truncated_when_wider_than_the_image
    l = layout("wide_long.csv", max_width_px: 320)
    assert_equal 320, l.width_px
    assert_match(/\A20 of 1,284 rows · \d of 31 columns\z/, l.footer_text, "footer_text keeps the full wording")
    run = l.footer_placement.run
    assert run.string.end_with?(ELLIPSIS), run.string
    assert_operator run.extent, :<=, 320 - 2 * EDGE
    assert_equal EDGE + run.xoffset, l.footer_placement.x
  end

  def test_narrow_table_widens_for_its_footer
    s = sample(rows: short_rows(20, 1), total_columns: 31, total_rows: 1_284, rows_read: 1_284, rows_truncated: true)
    l = build(s, theme: Theme::LEDGER.with(min_width: 60))
    footer = l.footer_placement.run
    assert_equal footer.extent + 2 * EDGE, l.width_px
    assert_equal l.width_px - 2 * INSET, l.columns[0].width_px
  end

  def test_footer_style_and_placement
    l = layout("wide_long.csv")
    placement = l.footer_placement
    styles = Theme::LEDGER.styles(scale: 2)
    footer_top = FRAME + HEADER + 20 * ROW
    assert_equal EDGE + placement.run.xoffset, placement.x
    assert_equal CsvPreview::Text.metrics(styles.footer).line_top(footer_top, FOOTER) + placement.run.yoffset, placement.y
    assert_equal footer_top, l.geometry.footer_top
    assert_equal Layout::Box.new(x: FRAME, y: footer_top + 2, width: l.width_px - 2 * FRAME, height: FOOTER - 2),
                 placement.box
  end

  # --- REN-10 peek and fade -----------------------------------------------------------------------

  def test_REN_10_peek_column_and_fade
    l = layout("wide_long.csv")
    peek = l.peek_column
    refute_nil peek
    assert_equal l.visible_columns, peek.index
    assert_equal :left, peek.align
    assert_equal MAX_WIDTH, l.width_px
    assert_equal l.columns.last.x_px + l.columns.last.width_px, peek.x_px
    assert_equal MAX_WIDTH - FRAME, peek.x_px + peek.width_px
    assert_operator peek.width_px, :<=, PEEK

    fade = l.geometry.fade
    assert_equal Layout::Box.new(x: MAX_WIDTH - FRAME - FADE, y: FRAME, width: FADE, height: HEADER + 20 * ROW), fade
    l.columns.each { |c| assert_operator c.x_px + c.width_px - PAD, :<=, fade.x, "text of #{c.index} stops before the fade" }

    peek_cells = (0...l.rows_shown).filter_map { |r| l.cell_placement(r, peek.index) }
    refute_empty peek_cells
    peek_cells.each do |placement|
      assert_equal peek.x_px + PAD + placement.run.xoffset, placement.x
      assert_equal Layout::Box.new(x: peek.x_px, y: placement.box.y, width: peek.width_px, height: placement.box.height),
                   placement.box
    end
    assert_equal l.sample.rows[0][peek.index], l.cell_text(0, peek.index), "the peek is never ellipsis-truncated"
    assert_nil l.cell_text(0, peek.index + 1)
    assert_nil l.header_text(peek.index + 1)
  end

  def test_REN_10_no_peek_or_fade_when_everything_fits
    l = layout("simple.csv")
    assert_nil l.peek_column
    assert_nil l.geometry.fade
    assert_equal 3, l.visible_columns
  end

  def test_columns_hidden_only_by_max_columns_have_no_peek
    l = layout("simple.csv", max_columns: 2)
    assert_nil l.peek_column
    assert_nil l.geometry.fade
  end

  def test_peek_is_capped_and_left_aligned_whatever_its_kind
    words = "receipt transfer pending vendor office lunch refund payout airport hotel software"
    csv = +"Description,Memo,Amount\n"
    ["-1,234,567,890,123.45", "987,654,321,000.00", "-5.00"].each { |amount| csv << %(#{words},#{words},"#{amount}"\n) }
    l = layout_of(csv, max_width_px: 1400, header_row: true)

    peek = l.peek_column
    assert_equal 2, l.visible_columns
    assert_equal 2, peek.index
    assert_equal :number, peek.kind
    assert_equal :left, peek.align
    # Before the cap the peek had (1400 - 2) - (16 + 520 + 520) = 342 px; the 102 px excess is shared.
    assert_equal [571, 571], l.columns.map(&:width_px)
    assert_equal [1158, PEEK], [peek.x_px, peek.width_px]
    (0...3).each do |r|
      placement = l.cell_placement(r, 2)
      assert_equal peek.x_px + PAD, placement.x, "ink starts at the text left edge"
    end
    assert_equal "#{MINUS}1,234,567,890,123.45", l.cell_text(0, 2)
    assert_equal "Amount", l.header_text(2)
    assert_equal peek.x_px + PAD, l.header_placement(2).x
  end

  def test_column_0_is_clamped_when_it_alone_is_too_wide
    huge = "-$1,234,567,890,123,456.78"
    l = layout_of(%(Amount\n"#{huge}"\n$1.00\n), max_width_px: 320, header_row: true)
    assert_equal 320, l.width_px
    assert_equal 1, l.visible_columns
    assert_nil l.peek_column
    assert_nil l.geometry.fade
    assert_equal 320 - 2 * INSET, l.columns[0].width_px
    assert l.cell_text(0, 0).end_with?(ELLIPSIS), "the one case where a number is truncated"
    assert_operator l.cell_placement(0, 0).run.extent, :<=, 320 - 2 * INSET - 2 * PAD

    l = layout_of(%(Amount,Note\n"#{huge}",x\n$1.00,y\n), max_width_px: 320, header_row: true)
    limit = 320 - FRAME - FADE
    assert_equal limit - INSET + PAD, l.columns[0].width_px
    assert_equal 1, l.peek_column.index
    assert_equal [limit + PAD, 320 - FRAME - limit - PAD], [l.peek_column.x_px, l.peek_column.width_px]
    assert l.cell_text(0, 0).end_with?(ELLIPSIS)
  end

  # --- REN-11 and REN-12 special layouts ----------------------------------------------------------

  def test_REN_11_empty_file
    %w[empty.csv whitespace_only.csv].each do |fixture|
      l = layout(fixture)
      assert l.sample.empty?
      assert_equal "Empty file", l.message
      assert_equal [640, 292], [l.width_px, l.height_px]
      assert_equal 0, l.visible_columns
      assert_empty l.columns
      assert_nil l.peek_column
      assert_nil l.footer_text
      assert_nil l.header_text(0)
      assert_nil l.cell_text(0, 0)
      assert_equal 0, l.rows_shown

      placement = l.message_placement
      assert_equal "Empty file", placement.run.string
      assert_in_delta 320, placement.x + placement.run.image.width / 2.0, 1, "centred horizontally"
      body_top = FRAME + HEADER
      styles = Theme::LEDGER.styles(scale: 2)
      assert_equal CsvPreview::Text.metrics(styles.message).line_top(body_top, 3 * ROW) + placement.run.yoffset,
                   placement.y
    end
  end

  def test_REN_11_nothing_read_when_the_first_bytes_are_blank
    path = Fixtures.generate("blank_then_data.csv")
    l = CsvPreview.layout(path)
    assert l.sample.empty?
    assert_nil l.sample.total_rows
    assert_equal "No data in the first 2 MB", l.message
    assert_equal "No data in the first 1.5 MB", CsvPreview.layout(path, max_input_bytes: 1_572_864).message
    assert_equal "No data in the first 512 KB", CsvPreview.layout(path, max_input_bytes: 524_288).message
  end

  def test_size_wording
    assert_equal "2 MB", Layout.format_size(2_097_152)
    assert_equal "1.5 MB", Layout.format_size(1_572_864)
    assert_equal "2.9 MB", Layout.format_size(3_000_000)
    assert_equal "1 MB", Layout.format_size(1_048_576)
    assert_equal "512 KB", Layout.format_size(524_288)
    assert_equal "1.5 KB", Layout.format_size(1_536)
    assert_equal "1,024 KB", Layout.format_size(1_048_575)
    assert_equal "100 bytes", Layout.format_size(100)
    assert_equal "1 byte", Layout.format_size(1)
  end

  def test_empty_file_uses_fewer_body_rows_when_the_height_cap_is_small
    l = layout("empty.csv", max_height_px: 220)
    assert_equal 220, l.height_px # 4 + 72 + 2 * 72
    assert_equal 2, l.geometry.body_rows
    l = layout("empty.csv", max_width_px: 320, max_height_px: 220)
    assert_equal [320, 220], [l.width_px, l.height_px]
    assert_operator l.message_placement.run.extent, :<=, 320 - 2 * EDGE
  end

  def test_REN_12_header_only
    l = layout("header_only.csv")
    assert_equal "No rows", l.message
    assert_equal 148, l.height_px
    assert_equal 0, l.rows_shown
    assert_nil l.footer_text
    assert_equal ["Name", "Amount", "Date"], (0...3).map { |c| l.header_text(c) }
    assert_nil l.cell_text(0, 0)

    placement = l.message_placement
    assert_equal "No rows", placement.run.string
    assert_equal EDGE + placement.run.xoffset, placement.x
    row_top = FRAME + HEADER
    styles = Theme::LEDGER.styles(scale: 2)
    assert_equal CsvPreview::Text.metrics(styles.message).line_top(row_top, ROW) + placement.run.yoffset, placement.y
  end

  def test_header_only_footer_reports_hidden_columns
    l = layout_of("a,b,c\n", max_columns: 1, header_row: true)
    assert_equal "No rows", l.message
    assert_equal "0 rows · 1 of 3 columns", l.footer_text
    assert_equal FRAME * 2 + HEADER + ROW + FOOTER, l.height_px
    assert_equal FRAME + HEADER + ROW, l.geometry.footer_top
  end

  # --- REN-13 column letters ----------------------------------------------------------------------

  def test_REN_13_column_letters_without_a_header_row
    l = layout("simple.csv", header_row: false)
    assert_nil l.sample.headers
    assert_equal ["A", "B", "C"], (0..2).map { |c| l.header_text(c) }
    assert_equal 5, l.rows_shown
    assert_equal :right, l.columns[1].align
    assert_equal :right, l.header_placement(1).run.align, "letters are aligned like their columns"
  end

  def test_column_letters
    assert_equal %w[A B Z AA AB AZ BA ZZ AAA], [0, 1, 25, 26, 27, 51, 52, 701, 702].map { |i| Layout.column_letters(i) }
  end

  # --- REN-14 dimension caps ----------------------------------------------------------------------

  def test_REN_14_dimension_caps
    fixtures = Dir[File.join(Fixtures::CHECKED_IN, "*.{csv,tsv}")].sort
    fixtures << Fixtures.generate("long_text.csv")
    [320, 777, 2048].product([220, 999, 2600]).each do |max_width_px, max_height_px|
      fixtures.each do |path|
        l = begin
          CsvPreview.layout(path, max_width_px: max_width_px, max_height_px: max_height_px)
        rescue CsvPreview::UnreadableInput
          next
        end
        label = "#{File.basename(path)} at #{max_width_px} by #{max_height_px}"
        assert_operator l.width_px, :<=, max_width_px, label
        assert_operator l.height_px, :<=, max_height_px, label
        assert_operator l.width_px, :>=, [MIN_WIDTH, max_width_px].min, label
        assert_equal expected_height(l), l.height_px, label
        l.placements.each { |p| assert_inside(p.box, l, label) }
      end
    end
  end

  def test_REN_14_rows_stop_at_the_height_cap
    l = layout("wide_long.csv", max_rows: 50)
    assert_equal 50, l.sample.rows.size
    assert_equal 34, l.rows_shown
    assert_equal 2_596, l.height_px
    assert_match(/\A34 of 1,284 rows/, l.footer_text)
  end

  def test_full_render_size_at_the_defaults
    l = layout("statement.csv")
    assert_equal [2048, 1588], [l.width_px, l.height_px]
    assert_equal 1024, layout("statement.csv", scale: 1).width_px, "theme max_width keeps the layout at scale 1"
  end

  def test_a_theme_that_cannot_fit_raises_instead_of_exceeding_the_cap
    theme = Theme::LEDGER.with(header_height: 120)
    error = assert_raises(CsvPreview::RenderFailed) do
      build(CsvPreview.sample(Fixtures.path("simple.csv")), theme: theme, max_height_px: 220)
    end
    refute_match(/Apple|Fruit/, error.message)
  end

  # --- REN-15 small tables ------------------------------------------------------------------------

  def test_REN_15_small_tables_fill_the_frame
    l = layout("single_column.csv")
    assert_equal MIN_WIDTH, l.width_px
    assert_equal [INSET, MIN_WIDTH - 2 * INSET], [l.columns[0].x_px, l.columns[0].width_px]
  end

  def test_small_table_width_is_shared_evenly
    natural = build(CsvPreview.sample(Fixtures.path("simple.csv")), theme: Theme::LEDGER.with(min_width: 60))
    l = layout("simple.csv")
    extra = MIN_WIDTH - natural.width_px
    assert_operator extra, :>, 0
    shares = [extra / 3, extra / 3, extra / 3 + extra % 3]
    assert_equal natural.columns.map(&:width_px).zip(shares).map(&:sum), l.columns.map(&:width_px)
    assert_equal MIN_WIDTH - INSET, l.columns.last.x_px + l.columns.last.width_px
  end

  # --- REN-16 invisible cells ---------------------------------------------------------------------

  def test_REN_16_invisible_cells_draw_nothing
    l = layout("invisible.csv")
    assert_equal ["", "⠀", "", "normal"], (0...4).map { |r| l.cell_text(r, 1) }
    (0...3).each { |r| assert_nil l.cell_placement(r, 1), "row #{r}" }
    assert_equal "normal", l.cell_placement(3, 1).run.string
    assert_equal (0...4).map { |r| l.sample.rows[r][1] }, (0...4).map { |r| l.cell_text(r, 1) }
  end

  # --- review focus -------------------------------------------------------------------------------

  def test_rows_wider_than_header
    l = CsvPreview.layout(StringIO.new("A,B\n1,2,3,4\n5,6,7,8\n"), header_row: true)
    assert_equal ["A", "B", "", ""], (0...4).map { |c| l.header_text(c) }
    assert_equal 4, l.sample.column_count
    assert_equal "3", l.cell_text(0, 2)
    assert_nil l.header_placement(2)
    assert_equal 4, l.visible_columns
    assert_nil l.footer_text
  end

  def test_blank_and_duplicate_headers
    l = layout_of(",Amount,Amount\nx,1.00,2.00\ny,3.00,4.00\n", header_row: true)
    assert_equal "", l.header_text(0)
    assert_equal ["Amount", "Amount"], [l.header_text(1), l.header_text(2)]
    assert_nil l.header_placement(0), "a blank header draws nothing"
    assert_equal 3, l.visible_columns
    assert_equal %i[left right right], l.columns.map(&:align)
  end

  # --- text calls, vertical placement, boxes ------------------------------------------------------

  def test_one_text_call_per_distinct_drawn_string
    l = layout("simple.csv")
    assert_equal 15, l.text_calls, "3 headers and 12 distinct cells, no truncation, no footer"
    assert_equal 15, l.placements.size
  end

  def test_runs_in_a_band_share_one_baseline
    l = layout("statement.csv")
    styles = Theme::LEDGER.styles(scale: 2)
    header_line = CsvPreview::Text.metrics(styles.header).line_top(FRAME, HEADER)
    l.columns.each do |c|
      placement = l.header_placement(c.index) or next
      assert_equal header_line, placement.y - placement.run.yoffset
    end
    (0...l.rows_shown).each do |r|
      line = CsvPreview::Text.metrics(styles.body).line_top(FRAME + HEADER + r * ROW, ROW)
      l.columns.each do |c|
        placement = l.cell_placement(r, c.index) or next
        assert_equal line, placement.y - placement.run.yoffset
      end
    end
  end

  def test_cell_boxes_are_the_column_box_and_the_band_without_its_rule
    l = layout("simple.csv")
    column = l.columns[1]
    assert_equal Layout::Box.new(x: column.x_px, y: FRAME, width: column.width_px, height: HEADER - 2),
                 l.header_placement(1).box
    assert_equal Layout::Box.new(x: column.x_px, y: FRAME + HEADER, width: column.width_px, height: ROW),
                 l.cell_placement(0, 1).box
    assert_equal Layout::Box.new(x: column.x_px, y: FRAME + HEADER + ROW + 2, width: column.width_px, height: ROW - 2),
                 l.cell_placement(1, 1).box
  end

  def test_geometry
    l = layout("statement.csv")
    expected = Layout::Geometry.new(frame: 2, header_height: 72, row_height: 72, footer_height: 72, header_rule: 2,
                                    row_rule: 2, footer_rule: 2, body_rows: 20, footer_top: FRAME + HEADER + 20 * ROW,
                                    fade: Layout::Box.new(x: 2048 - 2 - 144, y: 2, width: 144, height: 72 + 20 * 72))
    assert_equal expected, l.geometry
  end

  # --- deadline, API, strings ---------------------------------------------------------------------

  class CountingDeadline
    attr_reader :checks

    def initialize = @checks = 0
    def check!(_stage) = @checks += 1
  end

  def test_deadline_is_checked_per_cell
    deadline = CountingDeadline.new
    l = build(CsvPreview.sample(Fixtures.path("simple.csv")), deadline: deadline)
    assert_operator deadline.checks, :>=, 3 * (l.rows_shown + 1)

    error = assert_raises(CsvPreview::TimeoutExceeded) do
      build(CsvPreview.sample(Fixtures.path("simple.csv")), deadline: CsvPreview::Deadline.new(0))
    end
    assert_match(/\(layout\)\. /, error.message)
  end

  def test_layout_api
    l = CsvPreview.layout(Fixtures.path("simple.csv"), scale: 1)
    assert_instance_of Layout, l
    assert_equal 1, l.scale
    assert_same Theme::LEDGER, l.theme
    assert_equal CsvPreview.sample(Fixtures.path("simple.csv")), l.sample
    assert_equal 320, l.width_px
    assert_equal l.columns[0].width_px.to_f, l.columns[0].width
    assert_predicate l, :frozen?
    assert_predicate l.columns, :frozen?
    assert_predicate l.placements, :frozen?
    assert_nil l.cell_text(4, 0)
    assert_nil l.cell_text(0, 3)
    assert_nil l.cell_text(-1, 0)
    assert_nil l.header_text(3)
    assert_nil l.message
    refute_match(/Vips|Image/, l.inspect)
  end

  def test_layout_validates_options_before_reading
    assert_raises(ArgumentError) { CsvPreview.layout(StringIO.new("a\n"), theme: :grid) }
    assert_raises(ArgumentError) { CsvPreview.layout(StringIO.new("a\n"), scale: 5) }
  end

  def test_font_option_lays_out_with_a_system_family
    l = layout("simple.csv", font: "DejaVu Sans")
    assert_equal 3, l.visible_columns
    assert_equal ["Fruit", "Qty", "Price"], (0..2).map { |c| l.header_placement(c).run.string }
    assert_equal 15, l.text_calls
  end

  def test_strings_live_in_one_frozen_hash
    assert_predicate Layout::STRINGS, :frozen?
    Layout::STRINGS.each_value { |value| assert_predicate value, :frozen? }
    assert_equal "Empty file", Layout::STRINGS[:empty]
    assert_equal "No rows", Layout::STRINGS[:no_rows]
    assert_equal " · ", Layout::STRINGS[:separator]
  end

  private

  def expected_height(l)
    body = l.message ? l.geometry.body_rows : l.rows_shown
    (FRAME * 2) + HEADER + (body * ROW) + (l.footer_text ? FOOTER : 0)
  end

  def assert_inside(box, l, label)
    assert_operator box.x, :>=, 0, label
    assert_operator box.y, :>=, 0, label
    assert_operator box.width, :>, 0, label
    assert_operator box.height, :>, 0, label
    assert_operator box.x + box.width, :<=, l.width_px, label
    assert_operator box.y + box.height, :<=, l.height_px, label
  end
end
