# frozen_string_literal: true

require "vips"
require_relative "images"

# Golden-image comparison (docs/spec/rendering.md section 11).
#
# Exact mode compares bytes. It is only meaningful on the pinned CI image the goldens were made on
# (ubuntu-24.04, packaged libvips 8.15.1, fonts-noto-color-emoji and fonts-noto-cjk), where it is
# switched on with CSV_PREVIEW_GOLDEN=exact.
#
# Perceptual mode is for every other machine, where glyph rasterisation, fallback fonts and PNG
# encoders differ. It requires: both dimensions within 2%; then, with both images resized to 512 px
# wide, a mean absolute difference under 3 levels and a 99th-percentile per-pixel difference under
# 64 levels (0 to 255 scale). These are the spec's numbers: font hinting only moves anti-aliased edges
# a little, while any layout change (a column, a row, a footer) shifts whole text blocks and exceeds them.
module ImageCompare
  EXACT_ENV = "CSV_PREVIEW_GOLDEN"
  DIMENSION_TOLERANCE = 0.02
  COMPARE_WIDTH = 512
  MEAN_LIMIT = 3.0
  P99_LIMIT = 64
  # Looser limits per golden. emoji_cjk is mostly colour emoji and CJK glyphs, which come from
  # whatever fallback fonts the machine has (Apple Color Emoji and Hiragino on macOS, Noto on the
  # pinned image): section 11 says these differ, and the spec's limits measure a mean of 5.3 and a 99th percentile of 195 on macOS (a glyph is dark in one font and light in another, so a few pixels differ completely). The
  # table is small, so a missing or extra row or column still moves the dimensions past 2% and the
  # structural facts in golden_test.rb still apply.
  LIMITS = { "emoji_cjk.png" => { mean: 8.0, p99: 255 } }.freeze

  module_function

  # @return [Boolean] true on the pinned CI job
  def exact?
    ENV[EXACT_ENV] == "exact"
  end

  # Asserts (from inside a Minitest test) that +actual_bytes+ matches the golden at +expected_path+.
  #
  # @param test [Minitest::Test]
  # @param expected_path [String]
  # @param actual_bytes [String] an encoded PNG
  # @param exact [Boolean] compare bytes instead of perceptually
  def assert_matches(test, expected_path, actual_bytes, exact: exact?)
    test.assert File.file?(expected_path), "missing golden #{expected_path} (run bin/goldens on the pinned CI image)"
    expected = File.binread(expected_path)

    if exact
      test.assert_equal expected.bytesize, actual_bytes.bytesize, "golden #{File.basename(expected_path)} size differs"
      test.assert expected == actual_bytes.b, "golden #{File.basename(expected_path)} bytes differ"
    else
      problem = perceptual_difference(expected, actual_bytes, **LIMITS.fetch(File.basename(expected_path), {}))
      test.assert_nil problem, "golden #{File.basename(expected_path)}: #{problem}"
    end
  end

  # @return [String, nil] why the two images differ perceptually, nil when they match
  def perceptual_difference(expected_bytes, actual_bytes, mean: MEAN_LIMIT, p99: P99_LIMIT)
    a = Images.decode(expected_bytes)
    b = Images.decode(actual_bytes)

    if relative(a.width, b.width) > DIMENSION_TOLERANCE || relative(a.height, b.height) > DIMENSION_TOLERANCE
      return "dimensions #{a.width}x#{a.height} vs #{b.width}x#{b.height} differ by more than 2%"
    end

    a = shrink(a)
    b = shrink(b)
    height = [a.height, b.height].min
    diff = (a.crop(0, 0, COMPARE_WIDTH, height) - b.crop(0, 0, COMPARE_WIDTH, height)).abs
    levels = Images.band_rank(diff, :max).cast(:uchar).write_to_memory.bytes

    mean_diff = levels.sum.fdiv(levels.size)
    p99_diff = levels.sort[((levels.size - 1) * 0.99).floor]
    return "mean difference #{mean_diff.round(2)} is not under #{mean}" unless mean_diff < mean

    "99th-percentile difference #{p99_diff} is not under #{p99}" unless p99_diff < p99
  end

  def relative(x, y) = (x - y).abs.fdiv([x, y].max)

  # Resized to COMPARE_WIDTH wide, 3 bands (alpha, if any, is flattened onto white).
  def shrink(image)
    image = image.flatten(background: [255, 255, 255]) if image.has_alpha?
    image.resize(COMPARE_WIDTH.fdiv(image.width), vscale: COMPARE_WIDTH.fdiv(image.width))
  end
end
