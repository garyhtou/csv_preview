# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def teardown
    CsvPreview.reset_config!
  end

  def test_defaults_match_the_pinned_table
    c = CsvPreview::Configuration.new
    assert_equal 2_097_152, c.max_input_bytes
    assert_equal 20, c.max_rows
    assert_equal 12, c.max_columns
    assert_equal 60, c.max_cell_chars
    assert_equal 2048, c.max_width_px
    assert_equal 2600, c.max_height_px
    assert_equal 2, c.scale
    assert_equal 5, c.timeout
    assert_equal :auto, c.header_row
    assert_equal :auto, c.delimiter
    assert_equal :auto, c.encoding
    assert_equal :png, c.format
    assert_equal :ledger, c.theme
    assert_nil c.font
    assert_equal ["text/csv", "text/tab-separated-values"], c.previewer_content_types
  end

  def test_per_call_overrides_win_and_snapshot_is_frozen
    CsvPreview.configure { |config| config.max_rows = 7 }
    snapshot = CsvPreview.config.resolve(max_columns: 3)
    assert_equal 7, snapshot.max_rows
    assert_equal 3, snapshot.max_columns
    assert_equal 9, CsvPreview.config.resolve(max_rows: 9).max_rows
    assert snapshot.frozen?
    assert_raises(FrozenError) { snapshot.max_rows = 1 }
    assert_equal 12, CsvPreview.config.max_columns
  end

  def test_invalid_options_raise_argument_error
    [
      { bogus: 1 },
      { max_rows: 0 },
      { scale: 5 },
      { scale: 1.5 },
      { max_width_px: 159 * 2 },
      { max_height_px: 109 * 2 },
      { delimiter: "\"" },
      { delimiter: "\n" },
      { delimiter: "\0" },
      { delimiter: "ab" },
      { delimiter: "é" },
      { encoding: "NOPE" },
      { format: :gif },
      { theme: :grid },
      { timeout: 0 },
      { timeout: -1 },
      { timeout: "5" },
      { timeout: nil },
      { timeout: Float::INFINITY },
      { timeout: Float::NAN },
      { header_row: "yes" },
      { header_row: nil },
      { font: :arial },
      { font: 12 },
      { scale: 0 },
      { previewer_content_types: "text/csv" },
      { previewer_content_types: ["text/csv", :tsv] },
      { previewer_content_types: nil }
    ].each do |options|
      assert_raises(ArgumentError, options.inspect) { CsvPreview.config.resolve(**options) }
    end
  end

  def test_valid_edge_options_are_accepted
    c = CsvPreview.config.resolve(delimiter: "\t", encoding: "Windows-1252", scale: 4, max_width_px: 640,
                                  max_height_px: 440, header_row: false, format: :webp, font: "Arial")
    assert_equal "\t", c.delimiter
  end

  def test_configure_changes_global_defaults
    CsvPreview.configure do |config|
      config.max_rows = 5
      config.previewer_content_types += ["text/x-csv"]
    end
    assert_equal 5, CsvPreview.config.max_rows
    assert_includes CsvPreview.config.previewer_content_types, "text/x-csv"
    CsvPreview.reset_config!
    assert_equal 20, CsvPreview.config.max_rows
    assert_equal ["text/csv", "text/tab-separated-values"], CsvPreview.config.previewer_content_types
  end

  def test_string_options_are_copied_and_frozen_in_the_snapshot
    font = +"Arial"
    delimiter = +";"
    snapshot = CsvPreview.config.resolve(font: font, delimiter: delimiter)
    font << " Bold"
    delimiter.replace(",")
    assert_equal "Arial", snapshot.font
    assert_equal ";", snapshot.delimiter
    assert snapshot.font.frozen?
    assert snapshot.delimiter.frozen?
  end

  def test_global_config_exists_at_load_time
    assert_instance_of CsvPreview::Configuration, CsvPreview.config
    assert_same CsvPreview.config, CsvPreview.config
  end
end
