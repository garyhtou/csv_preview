# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "support/fixtures"
require "support/golden"
require "support/image_compare"

# REN-21: golden images. Byte-exact on the pinned CI image (CSV_PREVIEW_GOLDEN=exact), perceptual plus
# the structural facts from CsvPreview.layout everywhere else. Regenerate with bin/goldens on CI.
class GoldenTest < Minitest::Test
  GOLDEN_DIR = Golden::DIR

  Golden::NAMES.each do |name|
    define_method(:"test_REN_21_golden_#{name}") do
      source = Fixtures.path("#{name}.csv")
      png = CsvPreview.render(source)
      ImageCompare.assert_matches(self, File.join(GOLDEN_DIR, "#{name}.png"), png)
      assert_structure(name, source) unless ImageCompare.exact?
    end
  end

  def test_REN_21_layout_change_does_not_match
    source = Fixtures.path("statement.csv")
    golden = File.binread(File.join(GOLDEN_DIR, "statement.png"))
    other = CsvPreview.render(source, max_rows: 19)
    refute_nil ImageCompare.perceptual_difference(golden, other)
    refute_equal golden, other
  end

  def test_REN_21_exact_mode_compares_bytes
    path = File.join(GOLDEN_DIR, "simple.png")
    bytes = File.binread(path)
    ImageCompare.assert_matches(self, path, bytes, exact: true)
    tweaked = bytes.dup
    tweaked.setbyte(tweaked.bytesize - 20, tweaked.getbyte(tweaked.bytesize - 20) ^ 1)
    failure = assert_raises(Minitest::Assertion) { ImageCompare.assert_matches(self, path, tweaked, exact: true) }
    assert_match(/bytes differ/, failure.message)
  end

  # bin/goldens writes only on CI or when forced: goldens made on any other machine are not
  # byte-comparable with the pinned image.
  def test_bin_goldens_refuses_to_write_outside_ci
    before = golden_files
    _out, err, status = Open3.capture3({ "CI" => nil, "CSV_PREVIEW_GOLDENS_FORCE" => nil },
                                       RbConfig.ruby, File.expand_path("../bin/goldens", __dir__))
    refute status.success?, "bin/goldens should exit with an error outside CI"
    assert_match(/CSV_PREVIEW_GOLDENS_FORCE=1/, err)
    assert_equal before, golden_files, "bin/goldens changed test/golden outside CI"
  end

  private

  def golden_files
    Dir[File.join(GOLDEN_DIR, "*")].sort.to_h { |path| [path, File.binread(path)] }
  end

  def assert_structure(name, source)
    stored = JSON.parse(File.read(File.join(GOLDEN_DIR, "#{name}.json")))
    actual = Golden.facts(CsvPreview.layout(source))
    assert_in_delta stored["visible_columns"], actual["visible_columns"], 1, "visible columns"
    assert_equal stored["rows_shown"], actual["rows_shown"], "rows shown"
    assert stored["footer_pattern"] == actual["footer_pattern"],
           "footer pattern #{actual["footer_pattern"].inspect} is not #{stored["footer_pattern"].inspect}"
  end
end
