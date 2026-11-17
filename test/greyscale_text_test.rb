# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require_relative "support/child_ruby"

# REN-24: text is greyscale-antialiased whatever the host's fontconfig says (rendering.md section 9).
# libvips before 8.17.1 draws text with subpixel antialiasing when fontconfig enables it (Ubuntu's
# default configuration does), which leaves coloured fringes on every glyph edge. Each test runs in a
# child process, because the antialiasing mode is read once per process; on Linux the child's
# FONTCONFIG_FILE is the system configuration plus one rule that sets the subpixel layout.
class GreyscaleTextTest < Minitest::Test
  LINUX = RUBY_PLATFORM.include?("linux")
  SYSTEM_FONTS_CONF = "/etc/fonts/fonts.conf"
  BODY_COLOR = CsvPreview::Theme::LEDGER.text_color

  # Shared by the child scripts: measurements of a text image composited over white, the way the
  # painter shows it.
  MEASURE = <<~'RUBY'
    require "csv_preview"
    require "json"
    require "vips"

    def over_white(image) = image.flatten(background: [255, 255, 255]).cast(:int)

    # Largest summed channel difference |R - G| + |G - B| + |R - B| of any pixel.
    def spread(image)
      image = over_white(image) if image.bands == 4
      ((image[0] - image[1]).abs + (image[1] - image[2]).abs + (image[0] - image[2]).abs).max.round
    end

    # Pixels whose summed channel difference is above 60, which no theme colour reaches.
    def coloured(image)
      image = image.cast(:int)
      diff = (image[0] - image[1]).abs + (image[1] - image[2]).abs + (image[0] - image[2]).abs
      ((diff > 60).ifthenelse(1, 0).avg * image.width * image.height).round
    end

    # Largest HSV saturation of any pixel.
    def saturation(image)
      bands = over_white(image).cast(:float).bandsplit
      high = Vips::Image.bandrank(bands, index: 2)
      low = Vips::Image.bandrank(bands, index: 0)
      ((high - low) / (high + 0.001)).max.round(3)
    end

    def raw(string, color)
      Vips::Image.text(%(<span foreground="#{color}">#{string}</span>), font: "Inter, 26",
                       fontfile: CsvPreview::Text::REGULAR, dpi: 72, rgba: true)
    end

    STYLES = CsvPreview::Theme::LEDGER.styles(scale: 2)
    FIXTURES = File.expand_path("../test/fixtures", CsvPreview::Text::FONT_DIR)
    SAMPLE = "Hamburgefonstiv 1,284.50 Ag"
    EMOJI = "Coffee ☕ Flag \u{1F1EF}\u{1F1F5}"
  RUBY

  def tint(hex)
    r, g, b = hex.delete_prefix("#").scan(/../).map(&:hex)
    (r - g).abs + (g - b).abs + (r - b).abs
  end

  # Runs +script+ (after MEASURE) in a child whose fontconfig sets +rgba+ ("rgb" or "none") on Linux.
  # On other platforms the child uses the host's own configuration.
  def run_child(script, rgba: nil)
    Dir.mktmpdir("csv_preview-fontconfig") do |dir|
      env = {}
      if rgba
        path = File.join(dir, "fonts.conf")
        File.write(path, fonts_conf(rgba))
        env["FONTCONFIG_FILE"] = path
      end
      out, err, status = ChildRuby.run(MEASURE + script, env: env)
      assert status.success?, err
      JSON.parse(out)
    end
  end

  def fonts_conf(rgba)
    <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <include>#{SYSTEM_FONTS_CONF}</include>
        <match target="pattern"><edit name="rgba" mode="assign"><const>#{rgba}</const></edit></match>
        <match target="font"><edit name="rgba" mode="assign"><const>#{rgba}</const></edit></match>
      </fontconfig>
    XML
  end

  def require_linux_fontconfig
    skip "subpixel rendering can be forced only through a Linux system fontconfig" unless LINUX
    skip "#{SYSTEM_FONTS_CONF} is missing" unless File.file?(SYSTEM_FONTS_CONF)
  end

  def test_REN_24_text_is_greyscale_when_fontconfig_enables_subpixel_rendering
    require_linux_fontconfig
    result = run_child(<<~'RUBY', rgba: "rgb")
      version = Vips.version_string[/\A\d+\.\d+\.\d+/]
      control = raw(SAMPLE, "#5B6472")
      CsvPreview::Text.warm_up!
      runs = %i[body body_number header footer message].to_h do |name|
        style = STYLES.public_send(name)
        image = CsvPreview::Text.render(SAMPLE, style: style, align: :left).image
        [name, { color: style.color, spread: spread(image) }]
      end
      emoji = CsvPreview::Text.render(EMOJI, style: STYLES.body, align: :left).image
      # The ink of "Coffee" alone, so the text beside the emoji is measured without it.
      word = CsvPreview::Text.render("Coffee", style: STYLES.body, align: :left)
      statement = Vips::Image.new_from_buffer(CsvPreview.render(File.join(FIXTURES, "statement.csv")), "")
      print JSON.generate(
        version: version, subpixel: CsvPreview::Text.subpixel_antialiasing?, runs: runs,
        control_spread: spread(control), control_emoji: saturation(raw(EMOJI, "#1F2328")),
        emoji_saturation: saturation(emoji), emoji_word_spread: spread(emoji.crop(0, 0, word.extent, emoji.height)),
        statement_coloured: coloured(statement)
      )
    RUBY

    if Gem::Version.new(result["version"]) < Gem::Version.new("8.17.1")
      assert_operator result["control_spread"], :>, 60, "the child's fontconfig did not turn subpixel rendering on"
      assert result["subpixel"], "warm-up did not detect subpixel antialiasing"
    end
    result["runs"].each do |name, run|
      assert_operator run["spread"], :<=, tint(run["color"]) + 2, "#{name} text (#{run["color"]}) has coloured edges"
    end
    assert_equal 0, result["statement_coloured"], "statement.csv has coloured pixels"
    assert_operator result["emoji_word_spread"], :<=, tint(BODY_COLOR) + 2, "text beside an emoji has coloured edges"
    # A colour emoji font is installed on the CI images (rendering.md 4.8); without one the control has
    # no colour either.
    return unless result["control_emoji"] > 0.45

    assert_operator result["emoji_saturation"], :>, 0.45, "the emoji lost its colours"
  end

  # The corrected text against libvips' own greyscale antialiasing (a child whose fontconfig sets rgba
  # none): the same coverage to within a few levels, so it looks neither bolder nor thinner.
  def test_REN_24_corrected_text_matches_greyscale_rendering
    require_linux_fontconfig
    require "vips"
    renders = %w[rgb none].to_h do |rgba|
      result = run_child(<<~'RUBY', rgba: rgba)
        png = CsvPreview.render(File.join(FIXTURES, "statement.csv"))
        print JSON.generate(subpixel: CsvPreview::Text.subpixel_antialiasing?, png: [png].pack("m0"))
      RUBY
      [rgba, result.merge("image" => Vips::Image.new_from_buffer(result["png"].unpack1("m0"), ""))]
    end
    refute renders["none"]["subpixel"]
    reference = renders["none"]["image"]
    corrected = renders["rgb"]["image"]
    assert_equal [reference.width, reference.height], [corrected.width, corrected.height]

    difference = (reference.cast(:int) - corrected.cast(:int)).abs
    assert_operator difference.avg, :<, 0.5, "mean difference from greyscale rendering"
    assert_operator difference.max, :<=, 24, "largest difference from greyscale rendering"
    ink = ->(image) { (image.cast(:int) * -1 + 255).avg }
    assert_in_delta 1.0, ink.call(corrected) / ink.call(reference), 0.01, "the corrected text is bolder or thinner"
  end

  # The second drawing of a colour-glyph string is a real libvips call: Layout#text_calls (REN-20's
  # budget) counts it, and the deadline is still checked whenever the count reaches a multiple of 32,
  # even when strings add two calls at a time. Subpixel rendering is forced through fontconfig on Linux;
  # where it cannot be (macOS, libvips 8.17.1 and newer) the child switches the correction on.
  def test_REN_24_second_drawing_is_counted_and_keeps_the_deadline_cadence
    skip "#{SYSTEM_FONTS_CONF} is missing" if LINUX && !File.file?(SYSTEM_FONTS_CONF)
    result = run_child(<<~'RUBY', rgba: LINUX ? "rgb" : nil)
      require "stringio"
      CsvPreview::Text.warm_up!
      CsvPreview::Text.instance_variable_set(:@subpixel, true)
      CALLS = []
      module Spy
        def text(*args, **kwargs)
          CALLS << args.first
          super
        end
      end
      Vips::Image.singleton_class.prepend(Spy)

      csv = +"Item,Note\n"
      20.times { |i| csv << "Coffee #{i} \u2615,Flag #{i} \u{1F1EF}\u{1F1F5}\n" }
      CsvPreview.layout(StringIO.new(csv)) # fills the per-process caches
      before = CALLS.size
      layout = CsvPreview.layout(StringIO.new(csv))
      layout_spied = CALLS.size - before

      checks = []
      renderer = nil
      deadline = Object.new
      deadline.define_singleton_method(:check!) { |_stage| checks << renderer.calls }
      renderer = CsvPreview::Text::Renderer.new(deadline: deadline)
      before = CALLS.size
      # One plain string, then strings drawn twice: the count goes 1, 3, 5, ... and never lands on 32.
      (["Total"] + Array.new(60) { |i| "Cell #{i} \u2615" }).each do |string|
        renderer.render(string, style: STYLES.body, align: :left)
      end
      print JSON.generate(layout_calls: layout.text_calls, layout_spied: layout_spied,
                          renderer_calls: renderer.calls, renderer_spied: CALLS.size - before, checks: checks)
    RUBY

    assert_equal result["layout_spied"], result["layout_calls"], "Layout#text_calls misses libvips calls"
    assert_operator result["layout_calls"], :>=, 2 * 40, "the emoji cells were not drawn twice"
    assert_equal 1 + (2 * 60), result["renderer_spied"]
    assert_equal result["renderer_spied"], result["renderer_calls"]
    assert_equal [33, 65, 97], result["checks"], "the deadline is checked as soon as each multiple of 32 is reached"
  end

  # Requirement: hosts that already draw greyscale text (macOS, Linux with rgba none, libvips 8.17.1 or
  # newer) get exactly libvips' own images.
  def test_REN_24_greyscale_hosts_keep_libvips_images
    skip "#{SYSTEM_FONTS_CONF} is missing" if LINUX && !File.file?(SYSTEM_FONTS_CONF)
    result = run_child(<<~'RUBY', rgba: LINUX ? "none" : nil)
      CsvPreview::Text.warm_up!
      style = STYLES.header
      run = CsvPreview::Text.render(SAMPLE, style: style, align: :left)
      expected = Vips::Image.text(CsvPreview::Text.markup(SAMPLE, style), font: "Inter, #{style.size_px}",
                                  fontfile: style.fontfile, dpi: 72, rgba: true)
      print JSON.generate(subpixel: CsvPreview::Text.subpixel_antialiasing?,
                          same: run.image.write_to_memory == expected.write_to_memory)
    RUBY

    refute result["subpixel"], "a greyscale host was detected as subpixel"
    assert result["same"], "the run's image differs from libvips' own"
  end

  # The correction itself, on every platform: with it switched on, text pixels take the style colour and
  # keep their coverage, and colour glyphs keep their pixels.
  def test_REN_24_correction_recolours_text_and_keeps_colour_glyphs
    result = run_child(<<~'RUBY')
      CsvPreview::Text.warm_up!
      style = STYLES.body
      plain = CsvPreview::Text.render(SAMPLE, style: style, align: :left).image
      before = CsvPreview::Text.render(EMOJI, style: style, align: :left).image
      CsvPreview::Text.instance_variable_set(:@subpixel, true)
      after_plain = CsvPreview::Text.render(SAMPLE, style: style, align: :left).image
      after = CsvPreview::Text.render(EMOJI, style: style, align: :left).image
      rgb = after_plain.extract_band(0, n: 3)
      print JSON.generate(
        plain_alpha: plain[3].write_to_memory == after_plain[3].write_to_memory,
        plain_colours: [rgb[0].min, rgb[0].max, rgb[1].min, rgb[1].max, rgb[2].min, rgb[2].max],
        offsets: [after.xoffset, after.yoffset] == [before.xoffset, before.yoffset],
        bands: [after.bands, after.format, after.interpretation].map(&:to_s),
        emoji_before: saturation(before), emoji_after: saturation(after),
        alpha_kept: before[3].write_to_memory == after[3].write_to_memory
      )
    RUBY

    assert result["plain_alpha"], "the coverage (alpha) changed"
    assert_equal [0x1F, 0x1F, 0x23, 0x23, 0x28, 0x28], result["plain_colours"], "text pixels are not the style colour"
    assert result["offsets"], "the ink offsets were lost"
    assert_equal %w[4 uchar srgb], result["bands"]
    assert result["alpha_kept"], "the emoji run's alpha changed"
    assert_in_delta result["emoji_before"], result["emoji_after"], 0.01, "the emoji lost its colours"
  end
end
