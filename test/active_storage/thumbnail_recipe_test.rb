# frozen_string_literal: true

require_relative "../rails_helper"
require_relative "../support/dummy_child"
require "open3"
require "tmpdir"

# Acceptance test AS-19 (active-storage.md 6): the top-left crop recipe keeps the header band. Each
# processor runs in a child process that boots the dummy app with that processor, because the variant
# processor is fixed at boot. The MiniMagick case runs under a locked-down ImageMagick policy.
class ThumbnailRecipeTest < Minitest::Test
  POLICY_DIR = File.expand_path("../support/imagemagick", __dir__)
  BOX = 120
  BLOCK = 8

  # Runs the recipe and the default centre crop for one processor.
  # @return [Hash{String=>String}] "preview", "recipe" and "centre" PNG bytes
  def thumbnails(processor, recipe:, env: {})
    result = DummyChild.run(<<~RUBY, env: { "VARIANT_PROCESSOR" => processor }.merge(env))
      model = PlainDocument.create!
      model.file.attach(io: File.open(Fixtures.path("wide_long.csv")), filename: "wide_long.csv")
      blob = model.file.blob
      recipe = blob.preview(resize_to_fill: #{recipe}).processed
      centre = blob.preview(resize_to_fill: [#{BOX}, #{BOX}]).processed
      report(processor: ActiveStorage.variant_processor.to_s,
             preview: Base64.strict_encode64(blob.preview_image.blob.download),
             recipe: Base64.strict_encode64(recipe.download),
             centre: Base64.strict_encode64(centre.download))
    RUBY
    assert_equal processor, result.fetch("processor")
    %w[preview recipe centre].to_h { |key| [key, DummyChild.decode(result.fetch(key))] }
  end

  def rgb(bytes)
    image = Images.decode(bytes)
    image.bands > 3 ? image.extract_band(0, n: 3) : image
  end

  # Mean absolute difference between two same-size images, over all bands (0 to 255).
  def distance(first, second)
    (first - second).abs.avg
  end

  def assert_top_left_recipe(bytes)
    preview = rgb(bytes.fetch("preview"))
    recipe = rgb(bytes.fetch("recipe"))
    centre = rgb(bytes.fetch("centre"))
    assert_equal [BOX, BOX], [recipe.width, recipe.height]
    assert_equal [BOX, BOX], [centre.width, centre.height]

    scale = [BOX.to_f / preview.width, BOX.to_f / preview.height].max
    expected = preview.resize(scale).crop(0, 0, BLOCK, BLOCK)
    actual = recipe.crop(0, 0, BLOCK, BLOCK)
    default = centre.crop(0, 0, BLOCK, BLOCK)

    assert_operator distance(actual, expected), :<, 2, "top-left block should match the scaled header corner"
    assert_operator distance(default, expected), :>, 3, "the default centre crop should differ from the corner"
    assert_operator distance(actual, default), :>, 3
  end

  def test_AS_19_vips_recipe_keeps_the_top_left
    assert_top_left_recipe(thumbnails("vips", recipe: "[#{BOX}, #{BOX}, { crop: :low }]"))
  end

  def test_AS_19_mini_magick_recipe_keeps_the_top_left_under_a_locked_down_policy
    require_imagemagick!

    bytes = thumbnails("mini_magick", recipe: %([#{BOX}, #{BOX}, { gravity: "NorthWest" }]),
                                      env: { "MAGICK_CONFIGURE_PATH" => POLICY_DIR })
    assert_top_left_recipe(bytes)
  end

  def test_a_missing_imagemagick_fails_on_ci_and_skips_elsewhere
    define_singleton_method(:imagemagick?) { false }
    with_ci("true") do
      error = assert_raises(Minitest::Assertion) { require_imagemagick! }
      refute_kind_of Minitest::Skip, error, "on CI a missing ImageMagick must fail, not skip"
    end
    with_ci(nil) { assert_raises(Minitest::Skip) { require_imagemagick! } }
  end

  def test_the_policy_really_is_locked_down
    require_imagemagick!

    out, = Open3.capture2e({ "MAGICK_CONFIGURE_PATH" => POLICY_DIR }, *magick_command, "-list", "policy")
    assert_includes out, "{JPEG,JPG,PNG,GIF,WEBP}"
  end

  # Negative probe: the policy is enforced, not just listed. The same picture converts from PNG and is
  # refused as a TIFF, a coder the policy does not allow.
  def test_the_policy_refuses_a_coder_it_does_not_allow
    require_imagemagick!

    Dir.mktmpdir("csvprev-policy") do |dir|
      picture = Vips::Image.black(4, 4) + 128
      png = File.join(dir, "probe.png")
      tiff = File.join(dir, "probe.tif")
      picture.pngsave(png)
      picture.tiffsave(tiff)
      env = { "MAGICK_CONFIGURE_PATH" => POLICY_DIR }

      out, status = Open3.capture2e(env, *magick_command, png, File.join(dir, "from_png.png"))
      assert status.success?, "the policy should allow PNG to PNG:\n#{out}"

      from_tiff = File.join(dir, "from_tiff.png")
      out, status = Open3.capture2e(env, *magick_command, tiff, from_tiff)
      refute status.success?, "the policy should refuse to read a TIFF"
      assert_match(/not authorized|security policy/i, out)
      refute File.exist?(from_tiff), "no output may be written from a refused TIFF"
    end
  end

  private

  def with_ci(value)
    original = ENV.fetch("CI", nil)
    ENV["CI"] = value
    yield
  ensure
    ENV["CI"] = original
  end

  def magick_command
    %w[magick convert].each do |name|
      return [name] if ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    end
    nil
  end

  def imagemagick?
    !magick_command.nil?
  end

  # On CI a missing ImageMagick is a failure, not a skip: the MiniMagick case and the policy checks would
  # silently not run.
  def require_imagemagick!
    return if imagemagick?

    flunk "ImageMagick is required on CI (no magick or convert on PATH)" if ENV["CI"]
    skip "ImageMagick is not installed (no magick or convert on PATH), so the MiniMagick case cannot run"
  end
end
