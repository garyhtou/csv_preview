# frozen_string_literal: true

require "test_helper"

# The committed brand images (docs/assets/, made by bin/brand-images on CI) have the sizes
# branding-and-discoverability.md section 2 specifies. Reads PNG headers only; nothing is rendered.
class BrandImagesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ASSETS = File.join(ROOT, "docs", "assets")
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  RGB = 2
  RGBA = 6

  # @return [Array(Integer, Integer, Integer)] width, height and colour type from the IHDR chunk
  def png_header(path)
    bytes = File.binread(File.join(ASSETS, path), 26)
    assert_equal PNG_SIGNATURE, bytes[0, 8], "#{path} is not a PNG"
    assert_equal "IHDR", bytes[12, 4]
    width, height = bytes[16, 8].unpack("NN")
    [width, height, bytes.getbyte(25)]
  end

  def test_script_exists_and_is_not_packaged
    assert File.executable?(File.join(ROOT, "bin", "brand-images"))
    spec = Dir.chdir(ROOT) { Gem::Specification.load("csv_preview.gemspec") }
    assert_empty spec.files.grep(%r{\A(bin/|docs/)})
  end

  def test_social_preview_is_1280_by_640_opaque_and_under_1_mb
    assert_equal [1280, 640, RGB], png_header("brand/social-preview.png")
    assert_operator File.size(File.join(ASSETS, "brand", "social-preview.png")), :<, 1_000_000
  end

  def test_marks_have_their_sizes
    [16, 32, 180, 512].each do |size|
      assert_equal [size, size, RGBA], png_header("brand/mark-#{size}.png")
    end
    assert File.file?(File.join(ASSETS, "brand", "mark.svg"))
  end

  def test_readme_images_are_transparent_cards
    %w[hero.png gallery/numbers.png gallery/emoji_cjk.png gallery/simple.png gallery/semicolon_decimal_comma.png
       brand/wordmark-light.png brand/wordmark-dark.png].each do |path|
      assert_equal RGBA, png_header(path)[2], path
    end
    assert_equal [1280, 320, RGBA], png_header("gallery/thumbnails.png")
  end
end
