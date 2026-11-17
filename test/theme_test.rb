# frozen_string_literal: true

require "test_helper"

class ThemeTest < Minitest::Test
  Theme = CsvPreview::Theme
  L = Theme::LEDGER

  # rendering.md 2.2, logical px at scale 1.
  LEDGER_TOKENS = {
    name: :ledger,
    font_family: "Inter",
    body_size: 13, body_weight: 400,
    header_size: 12, header_weight: 600,
    footer_size: 12, footer_weight: 400,
    number_features: "tnum",
    true_minus: true,
    text_color: "#1F2328",
    muted_color: "#6B7280",
    header_text_color: "#5B6472",
    header_fill: "#EEF0F3",
    header_rule_color: "#DDE1E6", header_rule_width: 1,
    row_rule_color: "#EDEFF2", row_rule_width: 1,
    footer_rule_color: "#E3E6EA", footer_rule_width: 1,
    frame_color: "#E3E6EA", frame_width: 1,
    background: "#FFFFFF",
    header_height: 36, row_height: 36, footer_height: 36,
    cell_padding: 12, edge_padding: 20,
    min_column_width: 56, max_column_width: 260,
    min_width: 320, max_width: 1024,
    fade_width: 72, fade_exponent: 1.5,
    peek_width: 120,
    empty_body_rows: 3
  }.freeze

  def test_ledger_tokens_match_the_spec
    assert_equal LEDGER_TOKENS, L.to_h
    assert_instance_of Float, L.fade_exponent
    assert_predicate L, :frozen?
  end

  def test_all_and_fetch
    assert_equal({ ledger: L }, Theme::ALL)
    assert_predicate Theme::ALL, :frozen?
    assert_same L, Theme.fetch(:ledger)
  end

  def test_fetch_rejects_unknown_themes
    error = assert_raises(ArgumentError) { Theme.fetch(:grid) }
    assert_equal "unknown theme :grid", error.message
  end

  def test_rgb
    assert_equal [31, 35, 40], L.rgb(:text_color)
    assert_equal [238, 240, 243], L.rgb(:header_fill)
    assert_equal [255, 255, 255], L.rgb(:background)
    assert_raises(ArgumentError) { L.rgb(:body_size) }
  end

  def test_px_is_applied_per_token
    assert_equal 72, L.px(:header_height, 2)
    assert_equal 26, L.px(:body_size, 2)
    assert_equal 20, L.px(:body_size, 1.5), "19.5 rounds to 20"
    assert_equal 2, L.rule_px(:frame_width, 2)
    assert_equal 1, L.rule_px(:frame_width, 0.4), "a drawn rule is at least 1 px"
    assert_equal 0, L.with(frame_width: 0).rule_px(:frame_width, 2), "width 0 means not drawn"
  end

  def test_validation_rejects_a_bad_colour
    ["#EEF0F", "EEF0F3", "#EEF0G3", "red", nil, %(#EEF0F3" foreground="red)].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { L.with(header_fill: bad) }
    end
  end

  def test_validation_rejects_non_positive_sizes
    %i[body_size header_height row_height cell_padding min_column_width max_width fade_width peek_width
       empty_body_rows].each do |token|
      [0, -1, 1.5, "12", nil].each do |bad|
        assert_raises(ArgumentError, "#{token}: #{bad.inspect}") { L.with(token => bad) }
      end
    end
  end

  def test_rule_widths_may_be_zero_but_not_negative
    %i[header_rule_width row_rule_width footer_rule_width frame_width].each do |token|
      assert_equal 0, L.with(token => 0).public_send(token)
      assert_raises(ArgumentError) { L.with(token => -1) }
      assert_raises(ArgumentError) { L.with(token => 1.0) }
    end
  end

  def test_validation_of_the_other_tokens
    assert_raises(ArgumentError) { L.with(fade_exponent: 0.0) }
    assert_raises(ArgumentError) { L.with(fade_exponent: -1.5) }
    assert_raises(ArgumentError) { L.with(fade_exponent: Float::INFINITY) }
    assert_raises(ArgumentError) { L.with(fade_exponent: 2) }
    assert_raises(ArgumentError) { L.with(min_width: 1025) }
    assert_raises(ArgumentError) { L.with(min_column_width: 261) }
    assert_raises(ArgumentError) { L.with(edge_padding: 11) }
    assert_raises(ArgumentError) { L.with(body_weight: 700) }
    assert_raises(ArgumentError) { L.with(header_weight: "600") }
    assert_raises(ArgumentError) { L.with(number_features: "zero") }
    assert_raises(ArgumentError) { L.with(true_minus: nil) }
    assert_raises(ArgumentError) { L.with(font_family: "") }
    assert_raises(ArgumentError) { L.with(font_family: "Inter\n") }
    assert_raises(ArgumentError) { L.with(name: "ledger") }
    assert_nil L.with(number_features: nil).number_features
  end

  def test_styles_are_device_px_with_the_bundled_files
    styles = L.styles(scale: 2)
    text = CsvPreview::Text

    assert_equal text::Style.new(family: "Inter", fontfile: text::REGULAR, size_px: 26, weight: 400,
                                 color: "#1F2328", tnum: false), styles.body
    assert_equal styles.body.with(tnum: true), styles.body_number
    assert_equal text::Style.new(family: "Inter", fontfile: text::SEMIBOLD, size_px: 24, weight: 600,
                                 color: "#5B6472", tnum: false), styles.header
    assert_equal styles.header.with(tnum: true), styles.header_number
    assert_equal text::Style.new(family: "Inter", fontfile: text::REGULAR, size_px: 24, weight: 400,
                                 color: "#6B7280", tnum: true), styles.footer
    assert_equal styles.body.with(color: "#6B7280"), styles.message

    assert_equal 13, L.styles(scale: 1).body.size_px
    assert_equal 52, L.styles(scale: 4).body.size_px
  end

  def test_font_option_replaces_the_family_only
    styles = L.styles(scale: 2, font: "DejaVu Sans")
    [styles.body, styles.header, styles.footer].each do |style|
      assert_equal "DejaVu Sans", style.family
      assert_nil style.fontfile
    end
    assert_equal 600, styles.header.weight
    assert styles.footer.tnum
  end

  def test_without_number_features_no_style_asks_for_tnum
    styles = L.with(number_features: nil).styles(scale: 2)
    refute styles.body_number.tnum
    refute styles.header_number.tnum
    refute styles.footer.tnum
  end
end
