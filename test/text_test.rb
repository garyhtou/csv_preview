# frozen_string_literal: true

require "test_helper"
require "vips"
require_relative "support/child_ruby"

# Records every Vips::Image.text call made on the current thread while a log is installed, and can
# inject a libvips error. Installed once for the whole test process.
module TextCallSpy
  def text(*args, **kwargs)
    log = Thread.current[:csv_preview_text_log]
    log&.push([args.first, kwargs])
    error = Thread.current[:csv_preview_text_error]
    raise error if error

    super
  end
end
Vips::Image.singleton_class.prepend(TextCallSpy)

class TextTest < Minitest::Test
  T = CsvPreview::Text
  ELLIPSIS = "\u2026"
  # Pixel values marked verified in rendering.md were measured on macOS; other platforms (different
  # FreeType hinting) get a pixel of slack.
  MACOS = RUBY_PLATFORM.include?("darwin")

  def setup
    T.warm_up!
  end

  def style(size: 26, weight: 400, tnum: false, color: "#1F2328")
    T::Style.new(family: "Inter", fontfile: weight == 600 ? T::SEMIBOLD : T::REGULAR,
                 size_px: size, weight: weight, color: color, tnum: tnum)
  end

  def render(string, align: :left, **style_options)
    T.render(string, style: style(**style_options), align: align)
  end

  # @return [Array] the [markup, options] of every libvips text call made by the block
  def text_calls
    log = []
    Thread.current[:csv_preview_text_log] = log
    yield
    log
  ensure
    Thread.current[:csv_preview_text_log] = nil
  end

  # --- 4.2 escaping ---------------------------------------------------------------------------

  def test_REN_4_escape_markup_characters
    assert_equal "&amp;&lt;&gt;&quot;&apos;", T.escape(%(&<>"'))
    assert_equal "a &lt; b &amp;amp; &lt;b&gt;c&lt;/b&gt;", T.escape("a < b &amp; <b>c</b>")
    assert_equal "plain é 日本 😀", T.escape("plain é 日本 😀")
  end

  def test_markup_in_cells_is_drawn_as_literal_text
    inputs = ["<b>bold</b>", "&amp;", %(<span foreground="red">x</span>), "a < b", "AT&T", %(say "hi" & 'bye')]
    inputs.each do |input|
      run = render(input)
      assert_instance_of T::Run, run, input
      assert_equal input, run.string
    end

    assert_operator render("<b>bold</b>").extent, :>, 2 * render("bold").extent
    assert_operator render("&amp;").extent, :>, 2 * render("&").extent
  end

  def test_escaped_span_does_not_change_the_colour
    image = render(%(<span foreground="red">x</span>)).image
    refute_operator max_red_excess(image), :>, 50, "markup in the cell was applied"

    control = Vips::Image.text(%(<span foreground="red">x</span>), dpi: 72, rgba: true)
    assert_operator max_red_excess(control), :>, 200, "the red check cannot see red"
  end

  # Only pixels that are mostly opaque count: on Linux, nearly transparent anti-aliasing pixels carry
  # arbitrary colour (for example red 255, green 0 at alpha 2) that is not visible.
  def max_red_excess(image)
    excess = image[0].cast(:int) - image[1].cast(:int)
    (image[3] > 128).ifthenelse(excess, 0).max
  end

  def test_markup_attributes_come_only_from_the_style
    calls = text_calls { render("1 < 2", tnum: true, weight: 600, color: "#5B6472") }
    markup, options = calls.fetch(0)
    assert_equal %(<span weight="600" foreground="#5B6472" font_features="tnum">1 &lt; 2</span>), markup
    assert_equal "Inter, 26", options[:font]
    assert_equal T::SEMIBOLD, options[:fontfile]
    assert_equal 72, options[:dpi]
    assert_equal true, options[:rgba]
    refute options.key?(:width), "left-aligned strings are rendered without a width"

    plain = text_calls { render("x y") }.fetch(0).first
    assert_equal %(<span weight="400" foreground="#1F2328">x y</span>), plain
  end

  def test_nul_and_invalid_utf8_never_reach_libvips
    assert_equal "a\uFFFDb", render("a\u0000b").string
    assert_equal "a\uFFFDb", render("a\xFFb".b).string
    assert_equal "caf\uFFFD", render((+"caf\xC3").force_encoding(Encoding::UTF_8)).string
  end

  # --- 4.3 one call measures and draws --------------------------------------------------------

  def test_one_call_measures_and_draws
    run = nil
    calls = text_calls { run = render("AMZN Mktp US") }
    assert_equal 1, calls.size

    assert_instance_of Vips::Image, run.image
    assert_equal 4, run.image.bands
    assert_equal "AMZN Mktp US", run.string
    assert_equal :left, run.align
    assert_equal run.image.xoffset, run.xoffset
    assert_equal run.image.yoffset, run.yoffset
    assert_equal run.xoffset + run.image.width, run.extent
    assert run.frozen?
  end

  def test_tnum_changes_the_width_of_1_111_11
    proportional = render("1,111.11").extent
    tabular = render("1,111.11", tnum: true).extent
    assert_in_delta 74, proportional, 2
    assert_in_delta 114, tabular, 2
  end

  def test_left_aligned_run_is_placed_from_the_text_left_edge
    run = render("Coffee")
    x = run.x_in(100, 400)
    assert_equal 100 + run.xoffset, x
    assert_equal 100 + run.extent, x + run.image.width
  end

  def test_right_aligned_extent_reaches_the_logical_right_edge
    assert_equal 32_768, T::RIGHT_BOX
    runs = %w[10.00 10.01 10.11 $4,200.00].to_h { |s| [s, render(s, align: :right, tnum: true)] }

    runs.each do |string, run|
      gap = run.extent - run.image.width
      assert_includes MACOS ? 1..2 : 0..3, gap, "#{string}: the ink stops 1 to 2 px short of the logical edge"
      refute run.right_to_left?
      x = run.x_in(0, 500)
      assert_equal 500 - T::RIGHT_BOX + run.xoffset, x
      assert_equal 500, x + run.extent, "#{string}: the logical right edge sits on the text edge"
    end

    tabular = runs.values_at("10.00", "10.01", "10.11")
    assert_equal 1, tabular.map(&:extent).uniq.size, "tabular figures share one logical width"
    if MACOS
      assert_operator tabular.map { |r| r.image.width }.uniq.size, :>, 1, "while their ink widths differ"
    end
  end

  def test_right_to_left_guard
    run = render("غير متوفر", align: :right)
    assert_operator run.extent, :<, 500, "a right-to-left paragraph must not report the box width"
    assert run.right_to_left?
    assert_equal run.xoffset + run.image.width, run.extent
    assert_equal 500 - run.image.width, run.x_in(0, 500), "its ink right edge sits on the text edge"
    assert_equal :right, run.align
  end

  def test_fallback_scripts_and_missing_glyphs_render
    strings = ["日本語の明細", "עברית", "عربي text mixed", "\u{10FFFD}", "\u{1F600} \u{1F1EF}\u{1F1F5}"]
    strings.each do |string|
      run = render(string)
      assert_instance_of T::Run, run, string.dump
      assert_operator run.extent, :>, 0
    end
  end

  def test_system_family_passes_no_fontfile
    system = T::Style.new(family: "Helvetica Neue, Arial", fontfile: nil, size_px: 26, weight: 400,
                          color: "#1F2328", tnum: true)
    calls = text_calls { T.render("1,111.11", style: system, align: :right) }
    options = calls.fetch(0).last
    assert_equal "Helvetica Neue, Arial, 26", options[:font]
    refute options.key?(:fontfile)
    assert_equal T::RIGHT_BOX, options[:width]
    assert_equal :high, options[:align]
  end

  def test_align_must_be_left_or_right
    assert_raises(ArgumentError) { render("x", align: :center) }
  end

  # --- 4.4 blank strings ----------------------------------------------------------------------

  def test_blank_strings_draw_nothing
    blanks = ["", "   ", "\u00A0", "\u200B", "\u2063", "\u00AD", "\u034F", "\uFE0F", "\u180E",
              "\u3000", "\u3164", "\u{E0020}\u{E0041}"]
    calls = text_calls { blanks.each { |s| assert_nil render(s), s.dump } }
    assert_empty calls, "blank strings must not call libvips"

    braille = nil
    calls = text_calls { braille = render("\u2800\u2800") }
    assert_nil braille, "libvips' no-text error means blank"
    assert_equal 1, calls.size
  end

  def test_other_libvips_errors_become_render_failed
    Thread.current[:csv_preview_text_error] = Vips::Error.new("text: something broke")
    error = assert_raises(CsvPreview::RenderFailed) { render("secret cell content") }
    refute_includes error.message, "secret"
  ensure
    Thread.current[:csv_preview_text_error] = nil
  end

  def test_style_values_are_validated
    assert_raises(ArgumentError) { style(color: "red") }
    assert_raises(ArgumentError) { style(color: %(#000000" foreground="red)) }
    assert_raises(ArgumentError) { style(weight: "bold") }
    assert_raises(ArgumentError) { style(size: 0) }
    assert_raises(ArgumentError) { style(tnum: nil) }
    assert_raises(ArgumentError) { style.with(family: "") }
    assert_raises(ArgumentError) { style.with(family: "Inter\u0000") }
    assert_raises(ArgumentError) { style.with(fontfile: 1) }
  end

  # --- 4.5 ellipsis truncation ----------------------------------------------------------------

  def test_fit_keeps_a_run_that_already_fits
    run = render("Coffee")
    assert_same run, T.fit(run, style: style, max_extent: run.extent)
    assert_nil T.fit(nil, style: style, max_extent: 10)
  end

  def test_fit_never_splits_a_grapheme_cluster
    # rendering.md 4.5: "Team", a family emoji (a ZWJ sequence), "lunch", two flags, "café".
    family = "\u{1F469}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}"
    source = "Team #{family} lunch \u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8} caf\u00E9"
    clusters = source.grapheme_clusters
    prefixes = (0..clusters.size).map { |k| clusters[0, k].join.rstrip }
    full = render(source)
    ellipsis = render(ELLIPSIS).extent

    (ellipsis...full.extent).step(4) do |max|
      run = T.fit(full, style: style, max_extent: max)
      assert run.string.end_with?(ELLIPSIS), run.string
      base = run.string.delete_suffix(ELLIPSIS)
      assert_includes prefixes, base, "not a grapheme-cluster prefix: #{run.string.inspect}"
      refute base.end_with?(" "), "trailing space before the ellipsis: #{run.string.inspect}"
      assert_operator run.extent, :<=, max

      longer = prefixes.find { |p| p.length > base.length }
      next if longer.nil? || longer == source

      assert_operator render(longer + ELLIPSIS).extent, :>, max, "a longer prefix fits #{max} px"
    end
  end

  def test_fit_trims_spaces_before_the_ellipsis
    target = "COSTCO WHSE #0145 MOUNTAIN#{ELLIPSIS}"
    full = render("COSTCO WHSE #0145 MOUNTAIN VIEW CA")
    run = T.fit(full, style: style, max_extent: render(target).extent)
    assert_equal target, run.string
  end

  def test_fit_returns_the_ellipsis_alone_when_nothing_else_fits
    full = render("Team lunch")
    ellipsis = render(ELLIPSIS)
    assert_operator render("T#{ELLIPSIS}").extent, :>, ellipsis.extent

    run = T.fit(full, style: style, max_extent: ellipsis.extent)
    assert_equal ELLIPSIS, run.string
    assert_equal ellipsis.extent, run.extent
  end

  def test_fit_draws_nothing_when_even_the_ellipsis_does_not_fit
    full = render("Team lunch")
    assert_nil T.fit(full, style: style, max_extent: render(ELLIPSIS).extent - 1)
  end

  def test_fit_right_aligned
    header = render("Transaction amount (USD)", align: :right, weight: 600, size: 24)
    run = T.fit(header, style: style(weight: 600, size: 24), max_extent: 120)
    assert_equal :right, run.align
    assert run.string.end_with?(ELLIPSIS)
    assert_operator run.extent, :<=, 120
    assert_equal 500, run.x_in(0, 500) + run.extent
  end

  def test_fit_probe_count_is_bounded
    source = "Monthly subscription renewal for the analytics workspace, billed annually"[0, 60]
    full = render(source)
    bound = (2 * Math.log2(source.grapheme_clusters.size).ceil) + 2
    T.ellipsis_extent(style, :left) # per process, not a probe
    counts = [120, 200, 333, 450, 600].map do |max|
      text_calls { T.fit(full, style: style, max_extent: max) }.size
    end
    assert_operator counts.max, :<=, bound
    assert_operator counts.sum.fdiv(counts.size), :<=, 4.0, "the proportional first guess should be close"
  end

  # --- 4.6 vertical placement -----------------------------------------------------------------

  def test_metrics_centre_cap_height_on_one_baseline
    metrics = T.metrics(style)
    assert_in_delta 6, metrics.cap_top, MACOS ? 0 : 1
    assert_in_delta 20, metrics.cap_height, MACOS ? 0 : 1
    assert_equal 100 + ((72 - metrics.cap_height) / 2.0).round - metrics.cap_top, metrics.line_top(100, 72)
    assert_equal 20, metrics.line_top(0, 72) if MACOS

    samples = MACOS ? ["H", "2026", "AMZN", "\u{1F600}"] : ["H", "2026", "AMZN"]
    bottoms = samples.map { |s| render(s).then { |r| r.yoffset + r.image.height } }
    assert_equal 1, bottoms.uniq.size, "every run placed at line_top + yoffset shares one baseline"
    assert_equal metrics.cap_top + metrics.cap_height, bottoms.first
  end

  # --- 4.7 caching ----------------------------------------------------------------------------

  def test_renderer_caches_repeated_strings_and_counts_calls
    renderer = T::Renderer.new
    first = renderer.render("USD", style: style, align: :left)
    calls = text_calls do
      assert_same first, renderer.render("USD", style: style, align: :left)
      renderer.render("EUR", style: style, align: :left)
      renderer.render("EUR", style: style, align: :right)
      assert_nil renderer.render("  ", style: style, align: :left)
    end
    assert_equal 2, calls.size
    assert_equal 3, renderer.calls
  end

  def test_renderer_fit_counts_its_probes
    renderer = T::Renderer.new
    full = renderer.render("Monthly subscription renewal", style: style, align: :left)
    T.ellipsis_extent(style, :left) # per process, not counted by the renderer
    calls = text_calls { renderer.fit(full, style: style, max_extent: 150) }
    assert_equal 1 + calls.size, renderer.calls
  end

  class CountingDeadline
    attr_reader :checks

    def initialize = @checks = 0
    def check!(_stage) = @checks += 1
  end

  def test_renderer_checks_the_deadline_every_32_calls
    deadline = CountingDeadline.new
    renderer = T::Renderer.new(deadline: deadline)
    64.times { |i| renderer.render("value #{i}", style: style, align: :left) }
    assert_equal 2, deadline.checks

    expired = CsvPreview::Deadline.new(0)
    renderer = T::Renderer.new(deadline: expired)
    assert_raises(CsvPreview::TimeoutExceeded) do
      40.times { |i| renderer.render("value #{i}", style: style, align: :left) }
    end
  end

  # --- 5 and 9: support, warm-up, process-global state ----------------------------------------

  def test_text_is_supported_with_libvips
    assert T.supported?
    assert CsvPreview.text_supported?
  end

  def test_works_with_untrusted_operations_blocked
    skip "block_untrusted needs libvips 8.13" unless Vips.at_least_libvips?(8, 13)

    Vips.block_untrusted(true)
    assert_instance_of T::Run, render("blocked untrusted")
  ensure
    Vips.block_untrusted(false) if Vips.at_least_libvips?(8, 13)
  end

  def test_require_does_not_load_vips
    out, err, status = ChildRuby.run(<<~RUBY)
      require "csv_preview"
      p defined?(Vips)
      p $LOADED_FEATURES.grep(%r{/vips\\.rb\\z})
    RUBY
    assert status.success?, err
    assert_equal "nil\n[]\n", out
  end

  def test_loads_without_libvips
    out, err, status = ChildRuby.run(<<~RUBY)
      module NoVips
        private def require(name)
          raise LoadError, "cannot load such file -- vips" if name == "vips"

          super
        end
      end
      Kernel.prepend(NoVips)

      require "csv_preview"
      p defined?(Vips)
      p CsvPreview::Sanitizer.clean("a\\tb", max_cell_chars: 60)
      p CsvPreview::CellKind.cell("-$1,284.50")
      p CsvPreview.text_supported?
      style = CsvPreview::Text::Style.new(family: "Inter", fontfile: CsvPreview::Text::REGULAR,
                                          size_px: 26, weight: 400, color: "#1F2328", tnum: false)
      begin
        CsvPreview::Text.render("x", style: style, align: :left)
        puts "rendered"
      rescue CsvPreview::RenderFailed => e
        puts e.message
      end
      p CsvPreview::Text.bundled_font_active?
      require "stringio"
      begin
        CsvPreview.render(StringIO.new("a,b\\n1,2\\n"))
        puts "rendered"
      rescue CsvPreview::RenderFailed => e
        puts e.message
      end
      p CsvPreview.sample(StringIO.new("a,b\\n1,2\\n")).rows
    RUBY
    assert status.success?, err
    lines = out.lines(chomp: true)
    assert_equal ["nil", '"a b"', ":number", "false"], lines[0, 4]
    assert_match(/libvips/, lines[4])
    assert_equal "false", lines[5]
    assert_match(/libvips/, lines[6], "render raises RenderFailed naming the missing library")
    assert_equal '[["1", "2"]]', lines[7], "sample still works"
  end

  def test_cold_warm_up_registers_fonts_once_across_threads
    out, err, status = ChildRuby.run(<<~RUBY)
      require "vips"
      CALLS = Queue.new
      module Count
        def text(*args, **kwargs)
          CALLS << args.first
          super
        end
      end
      Vips::Image.singleton_class.prepend(Count)
      require "csv_preview"

      settings = -> { [Vips.cache_max, Vips.cache_max_mem, Vips.cache_max_files, Vips.concurrency] }
      before = settings.call
      gate = Queue.new
      threads = Array.new(8) { Thread.new { gate.pop; CsvPreview::Text.warm_up! } }
      8.times { gate << true }
      threads.each(&:join)
      p CALLS.size
      p CsvPreview::Text.bundled_font_active?
      p settings.call == before
    RUBY
    assert status.success?, err
    assert_empty err
    # libvips 8.12 needs one more draw to refresh Pango's font list (Text.register_fonts).
    calls = Vips.at_least_libvips?(8, 13) ? 9 : 10
    assert_equal "#{calls}\ntrue\ntrue\n", out,
                 "2 registrations (plus a refresh on libvips 8.12), 1 feature probe, 1 antialiasing probe, " \
                 "2 self-check probes, 3 cap-height probes"
  end

  def test_warm_up_precomputes_the_ledger_metrics
    out, err, status = ChildRuby.run(<<~RUBY)
      require "vips"
      FONTS = []
      module Count
        def text(*args, **kwargs)
          FONTS << kwargs[:font]
          super
        end
      end
      Vips::Image.singleton_class.prepend(Count)
      require "csv_preview"

      CsvPreview.configure { |config| config.scale = 1 }
      CsvPreview::Text.warm_up!
      p FONTS.last(3)
      before = FONTS.size
      styles = CsvPreview::Theme::LEDGER.styles(scale: 1)
      [styles.body, styles.header, styles.footer, styles.message].each { |s| CsvPreview::Text.metrics(s) }
      CsvPreview::Text.warm_up!
      p FONTS.size - before
    RUBY
    assert status.success?, err
    assert_empty err
    assert_equal %(["Inter, 13", "Inter, 12", "Inter, 12"]\n0\n), out,
                 "body, header and footer metrics are ready after warm-up; the message shares the body's"
  end

  # Weight 600 must draw with the bundled SemiBold file. Each child process measures "iiiiiiiiii" at 100 px
  # in weights 400 and 600 the way the theme draws them: one after the gem's warm-up, one with only the
  # SemiBold file ever registered, which is what weight 600 should look like. libvips 8.12 drew weight 600
  # with Regular after warm-up, because Pango kept the font list it read before SemiBold was registered.
  def test_weight_600_draws_with_the_bundled_semibold
    measure = <<~RUBY
      def extent(weight, file)
        image = Vips::Image.text(%(<span weight="\#{weight}">iiiiiiiiii</span>), font: "Inter, 100", fontfile: file,
                                 dpi: 72, rgba: true, width: 32_768, align: :high)
        32_768 - image.xoffset
      end
    RUBY
    after_warm_up = <<~RUBY
      require "csv_preview"
      require "vips"
      #{measure}
      CsvPreview::Text.warm_up!
      print [extent(400, CsvPreview::Text::REGULAR), extent(600, CsvPreview::Text::SEMIBOLD)].join(" ")
    RUBY
    semibold_alone = <<~RUBY
      require "csv_preview"
      require "vips"
      #{measure}
      print extent(600, CsvPreview::Text::SEMIBOLD)
    RUBY

    out, err, status = ChildRuby.run(after_warm_up)
    assert status.success?, err
    regular, semibold = out.split.map(&:to_i)
    out, err, status = ChildRuby.run(semibold_alone)
    assert status.success?, err
    assert_equal Integer(out), semibold, "weight 600 after warm-up is not the SemiBold file's width"
    refute_equal regular, semibold, "weight 600 drew as wide as Regular"
  end

  def test_self_check_failure_warns_once_and_keeps_rendering
    out, err, status = ChildRuby.run(<<~RUBY)
      require "vips"
      # Stands in for a fallback font with other metrics: the self-check probe comes back narrower.
      module FallbackFont
        def text(*args, **kwargs)
          kwargs[:font] = "Inter, 90" if kwargs[:font] == "Inter, 100"
          super
        end
      end
      Vips::Image.singleton_class.prepend(FallbackFont)
      require "csv_preview"

      style = CsvPreview::Text::Style.new(family: "Inter", fontfile: CsvPreview::Text::REGULAR,
                                          size_px: 26, weight: 400, color: "#1F2328", tnum: false)
      CsvPreview::Text.warm_up!
      CsvPreview::Text.warm_up!
      3.times { |i| CsvPreview::Text.render("still renders \#{i}", style: style, align: :left) or abort "nil" }
      p CsvPreview::Text.bundled_font_active?
    RUBY
    assert status.success?, err
    assert_equal "false\n", out
    warnings = err.lines.grep(/csv_preview/)
    assert_equal 1, warnings.size, err
    assert_match(/PANGOCAIRO_BACKEND=fontconfig/, warnings.first)
  end
end
