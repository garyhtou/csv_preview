# frozen_string_literal: true

require "test_helper"
require "delegate"
require "stringio"
require "vips"
require_relative "support/fixtures"
require_relative "support/images"

# Records the name and options of every libvips operation called on the current thread while a log
# is installed. Installed once for the whole test process.
module PainterOperationSpy
  def call(name, supplied, optional = {}, option_string = "")
    log = Thread.current[:csv_preview_operation_log]
    log&.push([name, optional])
    super
  end
end
Vips::Operation.singleton_class.prepend(PainterOperationSpy)

# Answers +Vips.at_least_libvips?+ for a pretend libvips version while one is set on the thread.
module PainterFakeLibvipsVersion
  def at_least_libvips?(major, minor)
    fake = Thread.current[:csv_preview_fake_libvips]
    return super unless fake

    (fake <=> [major, minor]) >= 0
  end
end
Vips.singleton_class.prepend(PainterFakeLibvipsVersion)

# Makes one buffer saver look missing while a suffix is set on the thread.
module PainterMissingSaver
  def write_to_buffer(format_string, **options)
    missing = Thread.current[:csv_preview_missing_saver]
    raise Vips::Error, "No known buffer saver for '#{format_string}'" if missing && format_string.start_with?(missing)

    super
  end
end
Vips::Image.prepend(PainterMissingSaver)

# While set on the thread, sets GFlags arguments the way ruby-vips did before 2.2.5: the value goes
# straight to g_value_set_flags (an FFI :uint), so a Symbol such as :none raises TypeError and only an
# Integer works. ruby-vips 2.3 converts nicks first, which hides the problem on current installs.
module PainterOldRubyVipsFlags
  def set(value)
    if Thread.current[:csv_preview_old_ruby_vips_flags] &&
       ::GObject.g_type_fundamental(self[:gtype]) == ::GObject::GFLAGS_TYPE
      return ::GObject.g_value_set_flags(self, value)
    end

    super
  end
end
GObject::GValue.prepend(PainterOldRubyVipsFlags)

# rendering.md section 7: canvas, fills, rules and frame; text placement and clipping; fade; one
# composite; encoding; caps.
class PainterTest < Minitest::Test
  Painter = CsvPreview::Painter
  Layout = CsvPreview::Layout
  Theme = CsvPreview::Theme

  WHITE = "#FFFFFF"
  HEADER_FILL = "#EEF0F3"
  HEADER_RULE = "#DDE1E6"
  ROW_RULE = "#EDEFF2"
  FOOTER_RULE = "#E3E6EA"
  FRAME = "#E3E6EA"

  # Every placement cut to its cell, then one deadline check before compositing and one before encoding.
  EXTRA_PAINT_CHECKS = 2

  class CountingDeadline
    attr_reader :stages

    def initialize = @stages = []
    def check!(stage) = @stages << stage
  end

  # Raises at the +nth+ check (1-based).
  class ExpiringDeadline
    def initialize(nth) = (@nth = nth) && (@count = 0)

    def check!(stage)
      @count += 1
      raise CsvPreview::TimeoutExceeded, "csv_preview exceeded its timeout (#{stage})" if @count == @nth
    end
  end

  def deadline = CsvPreview::Deadline.new(60)
  def layout(fixture, **options) = CsvPreview.layout(Fixtures.path(fixture), **options)
  def layout_of(text, **options) = CsvPreview.layout(StringIO.new(text), **options)
  def paint(layout, format: :png) = Painter.call(layout, format: format, deadline: deadline)
  def decode(bytes) = Images.decode(bytes)
  def color(image, x, y) = Images.hex(Images.pixel(image, x, y))

  def build(fixture, theme:, **options)
    config = CsvPreview.config.resolve(**options)
    Layout.build(CsvPreview.sample(Fixtures.path(fixture), **options), config: config, theme: theme, deadline: deadline)
  end

  # @return [Array] [name, options] of every libvips operation the block calls on this thread
  def operations
    log = []
    Thread.current[:csv_preview_operation_log] = log
    yield
    log
  ensure
    Thread.current[:csv_preview_operation_log] = nil
  end

  def with_thread_local(key, value)
    Thread.current[key] = value
    yield
  ensure
    Thread.current[key] = nil
  end

  # --- 7.1 canvas, fills, rules, frame ------------------------------------------------------------

  def test_canvas_is_the_layout_size_in_8_bit_srgb
    l = layout("simple.csv")
    image = decode(paint(l))
    assert_equal [l.width_px, l.height_px], [image.width, image.height]
    assert_equal [3, :uchar, :srgb], [image.bands, image.format, image.interpretation]
  end

  # In-place drawing (MutableImage#draw_*!, draw_rect and friends) is not safe in a threaded host:
  # each draw makes libvips signal every earlier draw operation on the image while holding no
  # reference to them, and Ruby's GC on another thread can free one mid-signal (a SIGSEGV seen in
  # PS-30 on CI). rendering.md 7.1.
  def test_painting_never_draws_in_place
    names = operations { paint(layout("wide_long.csv")) }.map(&:first)

    assert_empty names.grep(/\Adraw_/), "the painter must not draw in place"
  end

  def test_header_band_rules_footer_rule_and_frame
    l = layout("statement.csv")
    g = l.geometry
    image = decode(paint(l))
    w = l.width_px
    h = l.height_px
    x = (g.frame + l.columns[0].x_px) / 2 # inside the frame, left of the first column: never text

    assert_equal [2048, 1588, 2, 72, 72, 2, 1514], [w, h, g.frame, g.header_height, g.row_height, g.row_rule, g.footer_top]
    # Header band [2, 74), its rule in the last 2 px.
    assert_equal HEADER_FILL, color(image, x, 2)
    assert_equal HEADER_FILL, color(image, x, 71)
    assert_equal [HEADER_RULE, HEADER_RULE], [color(image, x, 72), color(image, x, 73)]
    # Row 0 has no rule of its own; rows 1 to 19 have one at their top.
    assert_equal WHITE, color(image, x, 74)
    assert_equal [WHITE, ROW_RULE, ROW_RULE, WHITE], (145..148).map { |y| color(image, x, y) }
    (1...l.rows_shown).each do |i|
      top = 2 + 72 + (i * 72)
      assert_equal ROW_RULE, color(image, x, top), "row #{i} rule"
      assert_equal WHITE, color(image, x, top + 2), "row #{i} body"
    end
    # Footer band [1514, 1586), its rule in the first 2 px; the bottom frame below it.
    assert_equal [WHITE, FOOTER_RULE, FOOTER_RULE, WHITE], (1513..1516).map { |y| color(image, x, y) }
    # Frame: 2 px on all four sides, drawn over the header band.
    [[0, 0], [1, 1], [w - 1, h - 1], [w - 2, h - 2], [0, 40], [1, 40], [w - 1, 40], [w - 2, 40], [w / 2, 0],
     [w / 2, 1], [w / 2, h - 1], [w / 2, h - 2], [0, h / 2], [w - 1, h / 2]].each do |px, py|
      assert_equal FRAME, color(image, px, py), "frame at #{px},#{py}"
    end
    assert_equal HEADER_FILL, color(image, 2, 40), "inside the frame"
  end

  def test_rules_run_the_full_inner_width
    l = layout("simple.csv")
    image = decode(paint(l))
    row_1_rule = 2 + 72 + 72
    [2, l.width_px / 2, l.width_px - 3].each do |x|
      assert_equal HEADER_RULE, color(image, x, 73), "header rule at #{x}"
      assert_equal ROW_RULE, color(image, x, row_1_rule), "row rule at #{x}"
    end
  end

  def test_no_footer_rule_without_a_footer
    l = layout("simple.csv")
    assert_nil l.geometry.footer_top
    image = decode(paint(l))
    last_row_bottom = l.height_px - 2
    assert_equal WHITE, color(image, 8, last_row_bottom - 1)
    assert_equal FRAME, color(image, 8, last_row_bottom)
  end

  def test_empty_file_has_the_header_band_and_no_body_rules
    l = layout("empty.csv")
    image = decode(paint(l))
    assert_equal [640, 292], [image.width, image.height]
    assert_equal HEADER_FILL, color(image, 8, 10)
    assert_equal HEADER_RULE, color(image, 8, 73)
    (74...290).each { |y| assert_equal WHITE, color(image, 8, y), "body at y #{y}" }
  end

  def test_header_only_has_no_row_rules
    l = layout("header_only.csv")
    assert_equal 0, l.rows_shown
    image = decode(paint(l))
    (74...(l.height_px - 2)).each { |y| assert_equal WHITE, color(image, 8, y), "body at y #{y}" }
  end

  def test_zero_rule_and_frame_widths_are_not_drawn
    theme = Theme::LEDGER.with(frame_width: 0, header_rule_width: 0, row_rule_width: 0, footer_rule_width: 0)
    l = build("simple.csv", theme: theme)
    image = decode(paint(l))
    assert_equal HEADER_FILL, color(image, 0, 0)
    assert_equal HEADER_FILL, color(image, 8, 71), "no header rule"
    assert_equal WHITE, color(image, 8, 72 + 72), "no row rule"
    assert_equal WHITE, color(image, 0, l.height_px - 1), "no frame"
  end

  def test_colours_come_from_the_theme
    theme = Theme::LEDGER.with(header_fill: "#102030", frame_color: "#405060", row_rule_color: "#708090",
                               background: "#FAF0E6")
    l = build("simple.csv", theme: theme)
    image = decode(paint(l))
    assert_equal "#405060", color(image, 0, 0)
    assert_equal "#102030", color(image, 8, 10)
    assert_equal "#708090", color(image, 8, 2 + 72 + 72)
    assert_equal "#FAF0E6", color(image, 8, 2 + 72 + 72 + 10)
  end

  # --- 7.2 text placement and clipping ------------------------------------------------------------

  def test_runs_are_drawn_at_their_placements
    l = layout("simple.csv")
    image = decode(paint(l))
    placement = l.cell_placement(0, 0)
    box = placement.box
    right = Images.ink_right(image, box, [255, 255, 255], 64)
    refute_nil right, "the cell has ink"
    assert_in_delta placement.x + placement.run.image.width, right, 1
  end

  def test_tall_runs_are_clipped_to_their_cell
    above = "e\u0301\u0302\u0303\u0304\u0306\u0307\u0308\u030A" # eight stacked marks above, all in Inter
    l = layout_of("Name,Note\nAlpha,plain\nBeta,#{above}\nGamma,x\nDelta,x\n")
    up = l.cell_placement(1, 1)
    assert_operator up.y, :<, up.box.y, "the stacked marks reach above the row"

    # Inter does not stack marks below the baseline, and the fallback font that draws such marks varies
    # by host (DejaVu Sans, a system Inter, Apple's fonts), so the run that reaches below its row is made
    # by hand: an opaque block in Gamma's cell, one row taller than the cell above it and one below.
    down = l.cell_placement(2, 1)
    row = down.box.height
    block = (Vips::Image.black(down.box.width, row * 3, bands: 4) + [31, 35, 40, 255]).cast(:uchar)
                                                                              .copy(interpretation: :srgb)
    tall = down.with(run: down.run.with(image: block), x: down.box.x, y: down.box.y - row)
    placements = l.placements.map { |placement| placement.equal?(down) ? tall : placement }
    painted = Class.new(SimpleDelegator) { define_method(:placements) { placements } }.new(l)

    image = decode(paint(painted))
    column = l.columns[1]
    rule = Theme::LEDGER.rgb(:row_rule_color)
    [2 + 72 + 72, 2 + 72 + (2 * 72), 2 + 72 + (3 * 72)].each do |y|
      strip = image.crop(column.x_px, y, column.width_px, 2)
      assert_equal 0, (strip - rule).abs.max, "the rule at y #{y} is untouched across the column"
    end
    inside = image.crop(down.box.x, down.box.y + 4, down.box.width, row - 8)
    assert_operator inside.max, :<, 64, "the block still fills its own cell"
  end

  def test_runs_never_paint_outside_the_frame
    l = layout("wide_long.csv")
    image = decode(paint(l))
    frame = Theme::LEDGER.rgb(:frame_color)
    right = image.crop(l.width_px - 2, 0, 2, l.height_px)
    assert_equal 0, (right - frame).abs.max, "the right frame is untouched by the peek and the fade"
  end

  # --- 7.3 fade -----------------------------------------------------------------------------------

  def test_fade_follows_the_theme_ramp_over_the_header_band
    l = layout("wide_long.csv")
    fade = l.geometry.fade
    image = decode(paint(l))
    y = fade.y + 4 # in the header band, above the labels
    fill = Theme::LEDGER.rgb(:header_fill)
    [0, 36, 72, 108, 140, fade.width - 1].each do |i|
      alpha = (255 * ((i / (fade.width - 1).to_f)**Theme::LEDGER.fade_exponent)).floor
      expected = fill.map { |c| c + ((255 - c) * alpha / 255.0) }
      actual = Images.pixel(image, fade.x + i, y)
      expected.zip(actual).each { |e, a| assert_in_delta e, a, 1, "fade at #{i} px" }
    end
    assert_equal HEADER_FILL, color(image, fade.x - 1, y), "before the fade"
    assert_equal WHITE, color(image, fade.x + fade.width - 1, y), "fully faded at the frame"
  end

  def test_fade_stops_above_the_footer
    l = layout("wide_long.csv")
    fade = l.geometry.fade
    assert_equal l.geometry.footer_top, fade.y + fade.height
    image = decode(paint(l))
    x = fade.x + fade.width - 1
    assert_equal FOOTER_RULE, color(image, x, l.geometry.footer_top), "the footer rule is not faded"
    assert_equal WHITE, color(image, x, l.geometry.footer_top - 1), "the last row is"
  end

  def test_no_fade_without_a_peek
    l = layout("simple.csv")
    assert_nil l.geometry.fade
    image = decode(paint(l))
    assert_equal HEADER_FILL, color(image, l.width_px - 3, 6)
  end

  # --- 7.4 compositing ----------------------------------------------------------------------------

  def test_one_composite_and_no_text_calls
    l = layout("statement.csv")
    log = operations { paint(l) }
    names = log.map(&:first)
    assert_equal 1, names.count("composite"), names.tally.inspect
    assert_equal 0, names.count("text")
    refute_match(/\.text\b/, File.read(File.expand_path("../lib/csv_preview/painter.rb", __dir__)))
  end

  def test_deadline_is_checked_per_cell_and_before_compositing_and_encoding
    l = layout("simple.csv")
    counting = CountingDeadline.new
    Painter.call(l, format: :png, deadline: counting)
    assert_equal [:paint], counting.stages.uniq
    assert_equal l.placements.size + EXTRA_PAINT_CHECKS, counting.stages.size
  end

  def test_an_expired_deadline_raises_from_the_paint_checkpoints
    l = layout("simple.csv")
    checks = l.placements.size + EXTRA_PAINT_CHECKS
    (1..checks).each do |nth|
      error = assert_raises(CsvPreview::TimeoutExceeded) { Painter.call(l, format: :png, deadline: ExpiringDeadline.new(nth)) }
      assert_match(/\(paint\)\z/, error.message)
    end
  end

  def test_the_last_check_comes_before_encoding
    l = layout("simple.csv")
    log = operations do
      assert_raises(CsvPreview::TimeoutExceeded) do
        Painter.call(l, format: :png, deadline: ExpiringDeadline.new(l.placements.size + EXTRA_PAINT_CHECKS))
      end
    end
    names = log.map(&:first)
    assert_includes names, "composite"
    assert_empty names.grep(/save/i)
  end

  # --- 7.5 encoding -------------------------------------------------------------------------------

  def saver_options(layout, format)
    log = operations { Painter.call(layout, format: format, deadline: deadline) }
    savers = log.select { |name, _| name.match?(/save/i) }
    assert_equal 1, savers.size
    savers.first
  end

  def test_encode_settings
    l = layout("simple.csv")
    skip "keep needs libvips 8.15" unless Vips.at_least_libvips?(8, 15)

    name, options = saver_options(l, :png)
    assert_match(/save.*png|png.*save/i, name)
    assert_equal({ compression: 6, keep: 0 }, options)

    name, options = saver_options(l, :webp)
    assert_match(/save.*webp|webp.*save/i, name)
    assert_equal({ lossless: true, keep: 0 }, options)

    name, options = saver_options(l, :jpeg)
    assert_match(/save.*jpeg|jpeg.*save/i, name)
    assert_equal({ Q: 90, optimize_coding: true, subsample_mode: :off, interlace: false, keep: 0 }, options)
  end

  # Regression: keep was passed as :none, which ruby-vips 2.1.0 to 2.2.4 cannot convert for a flags
  # argument (TypeError from every render on libvips 8.15 or newer, outside the RenderFailed contract).
  def test_keep_is_the_integer_flags_value_so_older_ruby_vips_can_set_it
    skip "keep needs libvips 8.15" unless Vips.at_least_libvips?(8, 15)

    l = layout("simple.csv")
    %i[png webp jpeg].each do |format|
      _, options = saver_options(l, format)
      assert_same 0, options[:keep], "#{format}: keep is VIPS_FOREIGN_KEEP_NONE as an Integer"
    end

    references = %i[png webp jpeg].to_h { |format| [format, paint(l, format: format)] }
    with_thread_local(:csv_preview_old_ruby_vips_flags, true) do
      assert_raises(TypeError, "the emulation rejects a Symbol, as ruby-vips before 2.2.5 did") do
        Vips::Image.black(2, 2).write_to_buffer(".png", keep: :none)
      end
      references.each do |format, expected|
        assert_equal expected, paint(l, format: format), "#{format} renders, identically, with old flag handling"
      end
    end
  end

  def test_strip_before_libvips_8_15_gives_the_same_bytes
    l = layout("simple.csv")
    current = paint(l)
    with_thread_local(:csv_preview_fake_libvips, [8, 14]) do
      _, options = saver_options(l, :png)
      assert_equal({ compression: 6, strip: true }, options)
      assert_equal current, paint(l)
    end
  end

  def test_formats_have_their_signatures_and_are_binary
    l = layout("simple.csv")
    png = paint(l, format: :png)
    jpeg = paint(l, format: :jpeg)
    webp = paint(l, format: :webp)
    assert_equal Images::PNG_SIGNATURE, png.byteslice(0, 8)
    assert_equal "\xFF\xD8\xFF".b, jpeg.byteslice(0, 3)
    assert_equal ["RIFF", "WEBP"], [webp.byteslice(0, 4), webp.byteslice(8, 4)]
    [png, jpeg, webp].each { |bytes| assert_equal Encoding::BINARY, bytes.encoding }
  end

  def test_resolution_follows_the_scale
    { 1 => 2_835, 2 => 5_669, 3 => 8_504, 4 => 11_339 }.each do |scale, per_metre|
      png = paint(layout("single_column.csv", scale: scale, max_width_px: 1024 * scale))
      phys = Images.png_chunks(png).assoc("pHYs")
      assert_equal [per_metre, per_metre, 1], phys[1].unpack("NNC"), "scale #{scale}"
    end
  end

  def test_a_missing_saver_raises_render_failed_naming_the_format
    l = layout("simple.csv")
    with_thread_local(:csv_preview_missing_saver, ".webp") do
      error = assert_raises(CsvPreview::RenderFailed) { paint(l, format: :webp) }
      assert_match(/webp/i, error.message)
      refute_match(/Apple|Fruit/, error.message)
      assert_equal Images::PNG_SIGNATURE, paint(l, format: :png).byteslice(0, 8), "other formats still work"
    end
  end

  def test_unknown_format_raises
    assert_raises(ArgumentError) { paint(layout("simple.csv"), format: :gif) }
  end

  # --- 7.6 caps -----------------------------------------------------------------------------------

  def test_layout_carries_its_caps
    l = layout("simple.csv", max_width_px: 777, max_height_px: 999)
    assert_equal [777, 999], [l.max_width_px, l.max_height_px]
  end

  def test_caps_are_checked_before_encoding
    l = layout("simple.csv")
    narrow = Class.new(SimpleDelegator) { def max_width_px = width_px - 1 }.new(l)
    short = Class.new(SimpleDelegator) { def max_height_px = height_px - 1 }.new(l)
    [narrow, short].each do |bad|
      log = operations do
        error = assert_raises(CsvPreview::RenderFailed) { paint(bad) }
        refute_match(/Apple|Fruit/, error.message)
      end
      assert_empty log.map(&:first).grep(/save/i), "nothing is encoded"
    end
  end

  def test_output_is_deterministic
    l = layout("numbers.csv")
    assert_equal paint(l), paint(l)
    assert_equal paint(l, format: :webp), paint(l, format: :webp)
    assert_equal paint(l, format: :jpeg), paint(l, format: :jpeg)
  end
end
