# frozen_string_literal: true

require "test_helper"
require "digest"
require "pathname"
require "stringio"
require "vips"
require_relative "support/child_ruby"
require_relative "support/fixtures"
require_relative "support/images"

# Injects a clock into every Deadline created on the current thread, and counts them, while set.
module RenderDeadlineInjection
  def new(seconds, **options)
    Thread.current[:csv_preview_deadlines]&.push(seconds)
    clock = Thread.current[:csv_preview_clock]
    options[:clock] = clock if clock
    super
  end
end
CsvPreview::Deadline.singleton_class.prepend(RenderDeadlineInjection)

# Acceptance tests for CsvPreview.render: rendering.md section 12 (the render halves) and the render
# half of PS-21 in parsing-and-safety.md section 11.
class RenderApiTest < Minitest::Test
  MACOS = RUBY_PLATFORM.include?("darwin")
  FORMATS = %i[png webp jpeg].freeze
  WHITE = [255, 255, 255].freeze
  MINUS = "\u2212"
  ELLIPSIS = "\u2026"
  # Pixels that differ from their band's background by more than this many levels count as ink.
  INK = 64

  class << self
    # @return [Array<String>] every checked-in fixture that renders (binary files raise instead)
    def renderable
      @renderable ||= Dir[File.join(Fixtures::CHECKED_IN, "*.{csv,tsv}")].sort.select do |path|
        CsvPreview.sample(path)
        true
      rescue CsvPreview::UnreadableInput
        false
      end
    end

    # @return [String] the bytes of one unblocked render, made once per process
    def reference(path, format)
      (@references ||= {})[[path, format]] ||= CsvPreview.render(path, format: format)
    end
  end

  def teardown
    CsvPreview.reset_config!
  end

  def fixture(name) = Fixtures.path(name)
  def render(source, **options) = CsvPreview.render(source, **options)
  def layout(source, **options) = CsvPreview.layout(source, **options)

  def timed
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - start]
  end

  # Renders +keys+ ([path, format] pairs) in a fresh Ruby process after +preamble+, one
  # "name format sha256" line each. The child runs while this process makes its own reference renders.
  def digests_in_child_process(keys, preamble)
    child = Thread.new do
      ChildRuby.run(<<~RUBY)
        #{preamble}
        require "digest"
        #{keys.map { |path, format| [path, format.to_s] }.inspect}.each do |path, format|
          digest = Digest::SHA256.hexdigest(CsvPreview.render(path, format: format.to_sym))
          puts [File.basename(path), format, digest].join(" ")
        end
      RUBY
    end
    reference_digests(keys)
    child.value
  end

  def reference_digests(keys)
    keys.map do |path, format|
      [File.basename(path), format, Digest::SHA256.hexdigest(self.class.reference(path, format))].join(" ")
    end
  end

  def png_size(bytes)
    Images.png_chunks(bytes).first[1].unpack("NN")
  end

  # --- REN-1 --------------------------------------------------------------------------------------

  def test_REN_1_simple_csv_renders
    png = render(fixture("simple.csv"))
    l = layout(fixture("simple.csv"))

    width, height, depth, colour_type = Images.png_chunks(png).first[1].unpack("NNCC")
    assert_equal [l.width_px, l.height_px], [width, height]
    assert_equal [8, 2], [depth, colour_type], "8-bit RGB without alpha"
    image = Images.decode(png)
    assert_equal [l.width_px, l.height_px, 3, :uchar, :srgb],
                 [image.width, image.height, image.bands, image.format, image.interpretation]
    assert_operator l.width_px, :>, l.height_px
    assert_operator image.deviate, :>, 10
    assert_equal CsvPreview.sample(fixture("simple.csv")).headers[0], l.header_text(0)
    assert_nil l.footer_text
  end

  # --- REN-2 --------------------------------------------------------------------------------------

  # The rendered right ink edge of each number column's header label is within 3 px of its cells'.
  def test_REN_2_number_headers_align_with_their_cells_in_the_image
    l = layout(fixture("numbers.csv"))
    image = Images.decode(render(fixture("numbers.csv")))
    header_fill = l.theme.rgb(:header_fill)
    background = l.theme.rgb(:background)
    numbers = l.columns.select { |c| c.kind == :number }
    assert_equal 4, numbers.size

    numbers.each do |column|
      header = Images.ink_right(image, l.header_placement(column.index).box, header_fill, INK)
      cells = (0...l.rows_shown).filter_map do |r|
        placement = l.cell_placement(r, column.index)
        placement && Images.ink_right(image, placement.box, background, INK)
      end
      assert_equal l.rows_shown, cells.size
      cells.each do |right|
        assert_in_delta header, right, 3, "column #{column.index}: header ink edge #{header}, cell #{right}"
      end
    end
  end

  # --- REN-4 --------------------------------------------------------------------------------------

  def test_REN_4_markup_renders_as_literal_text
    %w[markup.csv minus.csv].each do |name|
      png = render(fixture(name))
      assert_equal Images::PNG_SIGNATURE, png.byteslice(0, 8), name
      l = layout(fixture(name))
      l.columns.each do |column|
        l.rows_shown.times do |r|
          source = l.sample.rows[r][column.index]
          text = l.cell_text(r, column.index)
          next if text.end_with?(ELLIPSIS) && text != source

          text = text.tr(MINUS, "-") if column.kind == :number
          assert_equal source, text, "#{name} row #{r} column #{column.index}"
        end
      end
    end
    l = layout(fixture("minus.csv"))
    note = l.columns.find { |c| l.header_text(c.index) == "Note" }
    assert_equal ["-2+3", "x < y & z", "<b>bold</b>"], (0..2).map { |r| l.cell_text(r, note.index) }
  end

  # --- REN-5 --------------------------------------------------------------------------------------

  def test_REN_5_emoji_and_cjk_render
    l = layout(fixture("emoji_cjk.csv"))
    image = Images.decode(render(fixture("emoji_cjk.csv")))
    assert_equal [l.width_px, l.height_px], [image.width, image.height]
    # The dark text colour is slightly blue (saturation 0.23, and no more at its antialiased edges, which
    # are greyscale on every host: rendering.md section 9); a colour emoji is far above 0.45.
    assert_operator Images.max_saturation(image, l.cell_placement(0, 2).box), :<, 0.45, "plain figures are not coloured"
    # A colour emoji font is part of macOS and of the pinned CI image (rendering.md 4.8 and 11).
    return unless MACOS || ENV["CSV_PREVIEW_GOLDEN"] == "exact"

    emoji = l.cell_placement(0, 1) # "Morning" and U+1F642
    assert_includes emoji.run.string, "\u{1F642}"
    assert_operator Images.max_saturation(image, emoji.box), :>, 0.45
  end

  # --- REN-6 --------------------------------------------------------------------------------------

  def test_REN_6_right_to_left
    l = layout(fixture("rtl.csv"))
    image = Images.decode(render(fixture("rtl.csv")))
    assert_equal [l.width_px, l.height_px], [image.width, image.height]
    name, amount = l.columns
    assert_equal [:text, :left], [name.kind, name.align]
    assert_equal [:number, :right], [amount.kind, amount.align]
    assert_operator amount.width_px, :<, 600
    arabic = (0...l.rows_shown).find { |r| l.cell_text(r, amount.index) == "غير متوفر" }
    refute_nil arabic
    right = Images.ink_right(image, l.cell_placement(arabic, amount.index).box, WHITE, INK)
    assert_in_delta amount.x_px + amount.width_px - l.theme.px(:cell_padding, l.scale), right, 3,
                    "the right-to-left cell ends at the column's text edge"
  end

  # --- REN-10 (pixels) ----------------------------------------------------------------------------

  def test_REN_10_fade_pixels
    l = layout(fixture("wide_long.csv"))
    image = Images.decode(render(fixture("wide_long.csv")))
    g = l.geometry
    fade = g.fade
    inner_right = l.width_px - g.frame
    band = Struct.new(:x, :y, :width, :height)
    rows = (0...l.rows_shown).map do |r|
      rule = r.zero? ? 0 : g.row_rule
      band.new(0, g.frame + g.header_height + (r * g.row_height) + rule, l.width_px, g.row_height - rule)
    end

    rows.each do |row|
      last = image.crop(inner_right - 4, row.y, 4, row.height)
      assert_operator last.min, :>=, 253, "the last 4 px before the frame, row at y #{row.y}, are within 2 levels of white"
    end
    inked = rows.any? { |row| Images.ink_right(image, band.new(fade.x, row.y, 4, row.height), WHITE, 8) }
    assert inked, "the start of the fade shows the peek column's text"
  end

  # --- REN-11 -------------------------------------------------------------------------------------

  def test_REN_11_empty_file_renders_a_message_image
    assert_equal 0, File.size(fixture("empty.csv"))
    [StringIO.new(+""), fixture("empty.csv"), fixture("whitespace_only.csv")].each do |source|
      png = render(source)
      image = Images.decode(png)
      assert_equal [640, 292], [image.width, image.height]
      body = Struct.new(:x, :y, :width, :height).new(2, 74, 636, 216)
      right = Images.ink_right(image, body, WHITE, INK)
      refute_nil right, "the message is drawn"
      assert_operator right, :<, 640 - 2 - 100, "and centred, not stretched across"
    end
    assert_equal "Empty file", layout(fixture("empty.csv")).message
  end

  def test_REN_11_nothing_read_renders
    path = Fixtures.generate("blank_then_data.csv")
    assert_equal "No data in the first 2 MB", layout(path).message
    assert_equal [640, 292], png_size(render(path))
  end

  # --- REN-14 (decoded size) ----------------------------------------------------------------------

  def test_REN_14_decoded_size_equals_the_layout_and_the_caps
    defaults = CsvPreview.config.resolve
    cases = self.class.renderable.flat_map { |path| [[path, 320, 220], [path, defaults.max_width_px, defaults.max_height_px]] }
    %w[statement.csv wide_long.csv numbers.csv].each do |name|
      [[777, 999], [320, 2600]].each { |w, h| cases << [fixture(name), w, h] }
    end
    cases.each do |path, max_width_px, max_height_px|
      options = { max_width_px: max_width_px, max_height_px: max_height_px }
      l = layout(path, **options)
      bytes = if options == { max_width_px: defaults.max_width_px, max_height_px: defaults.max_height_px }
                self.class.reference(path, :png)
              else
                render(path, **options)
              end
      width, height = png_size(bytes)
      label = "#{File.basename(path)} at #{max_width_px} by #{max_height_px}"
      assert_equal [l.width_px, l.height_px], [width, height], label
      assert_operator width, :<=, max_width_px, label
      assert_operator height, :<=, max_height_px, label
    end
  end

  # --- REN-15 (pixels) ----------------------------------------------------------------------------

  def test_REN_15_header_band_spans_the_full_inner_width
    l = layout(fixture("single_column.csv"))
    image = Images.decode(render(fixture("single_column.csv")))
    fill = l.theme.rgb(:header_fill)
    [2, 3, l.width_px / 2, l.width_px - 4, l.width_px - 3].each do |x|
      assert_equal fill, Images.pixel(image, x, 6), "header band at x #{x}"
    end
  end

  # --- REN-17 -------------------------------------------------------------------------------------

  def test_REN_17_same_bytes_twice_in_one_process
    self.class.renderable.each do |path|
      assert_equal self.class.reference(path, :png), render(path), File.basename(path)
    end
  end

  def test_REN_17_same_bytes_in_a_child_process
    keys = self.class.renderable.map { |path| [path, :png] }
    out, err, status = digests_in_child_process(keys, <<~RUBY)
      require "csv_preview"
    RUBY
    assert status.success?, err
    assert_equal reference_digests(keys), out.lines(chomp: true)
  end

  def test_REN_17_same_bytes_from_8_threads
    names = %w[simple.csv numbers.csv emoji_cjk.csv minus.csv rtl.csv]
    serial = names.to_h { |name| [name, self.class.reference(fixture(name), :png)] }
    results = Array.new(8) do |t|
      Thread.new do
        Array.new(10) do |i|
          name = names[(t + i) % names.size]
          [name, render(fixture(name))]
        end
      end
    end.flat_map(&:value)
    assert_equal 80, results.size
    results.each { |name, bytes| assert_equal serial.fetch(name), bytes, name }
  end

  # --- REN-18 -------------------------------------------------------------------------------------

  def test_REN_18_formats
    %w[statement.csv simple.csv emoji_cjk.csv].each do |name|
      png = render(fixture(name))
      webp = render(fixture(name), format: :webp)
      jpeg = render(fixture(name), format: :jpeg)
      png_image = Images.decode(png)
      webp_image = Images.decode(webp)
      jpeg_image = Images.decode(jpeg)

      assert_equal [png_image.width, png_image.height, 3], [webp_image.width, webp_image.height, webp_image.bands], name
      assert_equal 0, (png_image - webp_image).abs.max, "#{name}: lossless WebP has the PNG's pixels"
      assert_equal [png_image.width, png_image.height], [jpeg_image.width, jpeg_image.height], name

      types = Images.png_chunks(png).map(&:first)
      assert_equal %w[IHDR pHYs], types.first(2), name
      assert_equal "IEND", types.last, name
      assert_equal ["IDAT"], types[2...-1].uniq, name
      phys = Images.png_chunks(png).assoc("pHYs")[1].unpack("NNC")
      assert_equal [5_669, 5_669, 1], phys, "#{name}: 144 dpi at scale 2"

      assert_equal ["VP8L"], Images.webp_chunks(webp), "#{name}: no VP8X, EXIF, XMP or ICCP chunk"
      markers = Images.jpeg_segments(jpeg)
      refute markers.any? { |marker, data| marker == 0xE1 }, "#{name}: no APP1 (EXIF or XMP)"
      refute markers.any? { |marker, data| marker == 0xE2 && data.start_with?("ICC_PROFILE") }, "#{name}: no ICC"

      [png_image, webp_image, jpeg_image].each do |image|
        fields = image.get_fields
        %w[exif-data xmp-data icc-profile-data].each { |field| refute_includes fields, field, name }
      end
    end
  end

  def test_REN_18_default_format_and_global_configuration
    assert_equal Images::PNG_SIGNATURE, render(fixture("simple.csv")).byteslice(0, 8)
    CsvPreview.configure { |config| config.format = :webp }
    assert_equal "RIFF", render(fixture("simple.csv")).byteslice(0, 4)
    assert_equal "\xFF\xD8".b, render(fixture("simple.csv"), format: :jpeg).byteslice(0, 2), "per-call wins"
  end

  # --- REN-20 -------------------------------------------------------------------------------------

  def test_REN_20_budget
    path = fixture("wide_long.csv")
    render(path)
    _, seconds = timed { render(path) }
    assert_operator seconds, :<, 1.0, "warm render of wide_long.csv"
    assert_operator layout(path).text_calls, :<=, 400
    assert_operator layout(Fixtures.generate("long_text.csv")).text_calls, :<=, 700
  end

  # --- REN-22 -------------------------------------------------------------------------------------

  def test_REN_22_untrusted_operations_blocked
    skip "block_untrusted needs libvips 8.13" unless Vips.at_least_libvips?(8, 13)

    # A fresh process blocks untrusted operations before it loads the gem, so font registration and
    # warm-up run blocked too, as in an application that blocks them at boot.
    keys = self.class.renderable.product(FORMATS)
    out, err, status = digests_in_child_process(keys, <<~RUBY)
      require "vips"
      Vips.block_untrusted(true)
      require "csv_preview"
    RUBY
    assert status.success?, err
    assert_equal reference_digests(keys), out.lines(chomp: true)
  end

  # --- PS-21 (render half) ------------------------------------------------------------------------

  def test_PS_21_tiny_timeout_on_wide_long_raises
    error = assert_raises(CsvPreview::TimeoutExceeded) { render(fixture("wide_long.csv"), timeout: 0.001) }
    assert_match(/\A[^\n]*\(\w+\)\. [^\n]*\z/, error.message)
  end

  # A clock that reads zero at creation and for the next nth - 1 readings, then a moment past any budget.
  def expiring_clock(nth)
    readings = -1
    lambda do
      readings += 1
      readings < nth ? 0.0 : 1_000_000.0
    end
  end

  def test_PS_21_every_render_stage_raises_from_its_own_checkpoint
    stages = {}
    (1..500).each do |nth|
      Thread.current[:csv_preview_clock] = expiring_clock(nth)
      render(StringIO.new("name,amount\nAlice,1.00\nBob,2.00\n"))
      break
    rescue CsvPreview::TimeoutExceeded => e
      stages[e.message[/\((\w+)\)\. /, 1]] = true
    ensure
      Thread.current[:csv_preview_clock] = nil
    end
    assert_equal %w[decode layout paint parse read sanitize sniff], stages.keys.sort
  end

  # --- CsvPreview.render --------------------------------------------------------------------------

  def test_render_uses_one_deadline_for_the_whole_call
    log = []
    Thread.current[:csv_preview_deadlines] = log
    render(fixture("simple.csv"), timeout: 7)
    assert_equal [7], log
  ensure
    Thread.current[:csv_preview_deadlines] = nil
  end

  def test_render_returns_binary_bytes
    bytes = render(fixture("simple.csv"))
    assert_instance_of String, bytes
    assert_equal Encoding::BINARY, bytes.encoding
  end

  def test_render_accepts_paths_pathnames_and_streams
    expected = self.class.reference(fixture("simple.csv"), :png)
    assert_equal expected, render(Pathname.new(fixture("simple.csv")))
    assert_equal expected, File.open(fixture("simple.csv"), "rb") { |file| render(file) }
    assert_equal expected, render(StringIO.new(File.binread(fixture("simple.csv"))))
  end

  def test_render_validates_options_before_reading
    source = Object.new
    def source.read(*) = raise("read before options were validated")
    assert_raises(ArgumentError) { render(source, format: :gif) }
    assert_raises(ArgumentError) { render(source, scale: 0) }
    assert_raises(ArgumentError) { render(source, nope: 1) }
  end

  def test_render_raises_unreadable_input_for_binary_files
    assert_raises(CsvPreview::UnreadableInput) { render(fixture("png_renamed.csv")) }
  end

  def test_render_passes_options_through
    l = layout(fixture("wide_long.csv"), max_rows: 3, scale: 1)
    assert_equal [l.width_px, l.height_px], png_size(render(fixture("wide_long.csv"), max_rows: 3, scale: 1))
  end
end
