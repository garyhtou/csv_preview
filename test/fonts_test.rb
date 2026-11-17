# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "support/child_ruby"
require_relative "support/fontconfig"

class FontsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # rendering.md 5.1: Inter 4.1, files taken unmodified from the official Inter-4.1.zip.
  BUNDLED = {
    "fonts/Inter-Regular.ttf" => [411_640, "40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82"],
    "fonts/Inter-SemiBold.ttf" => [419_744, "78a843fade9d4612a5567302fb595b56976eb5fcebf4fea5a5912d638bafcde3"],
    "fonts/OFL.txt" => [4_380, "262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a"]
  }.freeze

  def assert_bundled_files_unmodified
    BUNDLED.each do |path, (bytes, sha256)|
      full = File.join(ROOT, path)
      assert File.file?(full), "#{path} is missing"
      assert_equal bytes, File.size(full), "#{path} size"
      assert_equal sha256, Digest::SHA256.file(full).hexdigest, "#{path} SHA-256"
    end
  end

  def test_bundled_files_match_the_inter_4_1_release
    assert_bundled_files_unmodified
  end

  def test_REN_19_bundled_font_active
    assert_bundled_files_unmodified
    CsvPreview::Text.warm_up!
    assert CsvPreview::Text.bundled_font_active?,
           "the bundled Inter is not active (PANGOCAIRO_BACKEND=#{ENV["PANGOCAIRO_BACKEND"].inspect})"
  end

  # Families a host may draw instead of the bundled Inter. On Linux, DejaVu Sans is the usual default
  # sans; on macOS fontconfig answers "DejaVu Sans" with Verdana. Both draw the tabular zeros probe at
  # 634 px, inside its 630 to 660 px range, so that probe alone cannot tell them from Inter.
  FALLBACK_FAMILIES = ["DejaVu Sans", "Verdana", "Liberation Sans", "Noto Sans", "Helvetica", "Arial"].freeze
  DEJAVU_SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

  def test_REN_19_self_check_tells_the_bundled_inter_from_fallback_fonts
    CsvPreview::Text.warm_up!
    inter = CsvPreview::Text.self_check_extents
    assert CsvPreview::Text.self_check_passes?(inter), "the bundled Inter failed the self-check with #{inter.inspect}"

    if RUBY_PLATFORM.include?("linux") && ENV["CI"]
      assert File.file?(DEJAVU_SANS), "DejaVu Sans is expected on Linux CI"
    end
    FALLBACK_FAMILIES.each do |family|
      fontfile = family == "DejaVu Sans" && File.file?(DEJAVU_SANS) ? DEJAVU_SANS : nil
      extents = CsvPreview::Text.self_check_extents(family: family, fontfile: fontfile)
      refute CsvPreview::Text.self_check_passes?(extents), "#{family} passed the self-check with #{extents.inspect}"
    end
  end

  # After warm-up, fontconfig picks the bundled file for both weights the theme uses, including over a
  # system font also called Inter (CI installs one on Ubuntu 22.04 and 24.04; rendering.md 5.4). Pango
  # asks for weight 600 as fontconfig's semibold.
  def test_both_weights_resolve_to_the_bundled_files
    CsvPreview::Text.warm_up!
    { "Inter:weight=regular" => CsvPreview::Text::REGULAR,
      "Inter:weight=semibold" => CsvPreview::Text::SEMIBOLD }.each do |pattern, expected|
      file = Fontconfig.match_file(pattern)
      refute_nil file, pattern
      assert_equal File.realpath(expected), File.realpath(file), pattern
    end
  end

  def test_text_uses_the_bundled_files
    assert_equal File.join(ROOT, "fonts", "Inter-Regular.ttf"), CsvPreview::Text::REGULAR
    assert_equal File.join(ROOT, "fonts", "Inter-SemiBold.ttf"), CsvPreview::Text::SEMIBOLD
  end

  def test_gem_ships_the_fonts_and_the_licence
    spec = Dir.chdir(ROOT) { Gem::Specification.load("csv_preview.gemspec") }
    BUNDLED.each_key { |path| assert_includes spec.files, path }
    assert_equal ["MIT", "OFL-1.1"], spec.licenses
  end

  def test_macos_switches_pango_to_fontconfig_unless_the_app_chose
    skip "macOS only" unless RUBY_PLATFORM.include?("darwin")

    script = 'require "csv_preview"; print ENV["PANGOCAIRO_BACKEND"]'
    [[nil, "fontconfig"], ["", "fontconfig"], ["coretext", "coretext"]].each do |value, expected|
      out, err, status = ChildRuby.run(script, env: { "PANGOCAIRO_BACKEND" => value })
      assert status.success?, err
      assert_equal expected, out, "PANGOCAIRO_BACKEND was #{value.inspect}"
    end
  end
end
