# frozen_string_literal: true

require "test_helper"

class SanitizerTest < Minitest::Test
  def clean(text, max: 200, capped: false)
    CsvPreview::Sanitizer.clean(text, max_cell_chars: max, capped: capped)
  end

  def test_plain_text_is_kept_literally
    assert_equal "a <b> & \"c\" = + @ é 日本 😀", clean("a <b> & \"c\" = + @ é 日本 😀")
  end

  def test_result_is_frozen
    assert_predicate clean("abc"), :frozen?
    assert_predicate clean("x" * 500, max: 5), :frozen?
  end

  def test_line_breaks_and_tabs_become_one_space_per_run
    assert_equal "a b", clean("a\r\nb")
    assert_equal "a b c d", clean("a\tb\n\n\nc\u000B\u000C\r\u0085\u2028\u2029d")
    assert_equal "a b", clean("a\r\n\t\nb")
  end

  def test_other_c0_c1_and_del_are_removed
    assert_equal "ab", clean("a\u0000\u0001\u0008\u000E\u001B\u001F\u007F\u0080\u0084\u0086\u0090\u009Fb")
  end

  def test_PS_16_controls_removed_or_replaced_per_class
    assert_equal "a b", clean("a\u0007\u001B b")
    assert_equal "ab", clean("a\u200Bb")
    assert_equal "ab", clean("a\uFEFFb")
    assert_equal "ab", clean("a\u2060b\uFFF9\uFFFA\uFFFB")
    assert_equal "a b", clean("a\u0085b")
  end

  def test_PS_16_zalgo_cut_to_eight_marks
    out = clean("e" + "\u0301" * 50 + "x")
    assert_equal "e" + "\u0301" * 8 + "x", out
  end

  def test_PS_16_nul_is_removed
    assert_equal "ab", clean("a\u0000b")
  end

  def test_PS_15_bidi_controls_removed
    bidi = ["\u202A", "\u202B", "\u202C", "\u202D", "\u202E", "\u2066", "\u2067", "\u2068", "\u2069",
            "\u200E", "\u200F", "\u061C"]
    bidi.each { |c| assert_equal "ab", clean("a#{c}b"), "U+%04X not removed" % c.ord }
    assert_equal "00.001$", clean("\u202E00.001$")
  end

  def test_line_and_paragraph_separators_become_a_space_and_alm_is_removed
    assert_equal "a b", clean("a\u2028b")
    assert_equal "a b", clean("a\u2029b")
    assert_equal "a b", clean("a\u2028\u2029b")
    assert_equal "ab", clean("a\u061Cb")
  end

  def test_PS_15_zwj_and_zwnj_kept
    family = "👨\u200D👩\u200D👧"
    assert_equal family, clean(family)
    assert_equal "a\u200Cb", clean("a\u200Cb")
  end

  def test_variation_selectors_flags_and_fffd_kept
    assert_equal "❤\uFE0F", clean("❤\uFE0F")
    assert_equal "🇺🇸", clean("🇺🇸")
    assert_equal "a�b", clean("a�b")
  end

  def test_edge_ascii_spaces_trimmed_but_nbsp_kept
    assert_equal "a  b", clean("   a  b \t")
    assert_equal "\u00A0a\u00A0", clean("\u00A0a\u00A0")
  end

  def test_PS_13_formulas_unchanged
    ['=HYPERLINK("http://example.com","x")', "+cmd|' /C calc'!A0", "@SUM(A1:A2)", "-2+3"].each do |f|
      assert_equal f, clean(f)
    end
  end

  def test_PS_13_truncated_formula_is_a_prefix_ending_in_ellipsis
    out = clean('=HYPERLINK("http://example.com","x")', max: 10)
    assert_equal '=HYPERLIN…', out
  end

  def test_truncates_to_max_clusters_with_ellipsis
    assert_equal "abcd…", clean("abcdefghij", max: 5)
    assert_equal "abcde", clean("abcde", max: 5)
    assert_equal "…", clean("abcdef", max: 1)
  end

  def test_truncation_never_splits_a_grapheme_cluster
    family = "👨\u200D👩\u200D👧"
    assert_equal "#{family}#{family}…", clean(family * 5, max: 3)
    assert_equal "e\u0301e\u0301…", clean("e\u0301" * 6, max: 3)
  end

  def test_truncation_removes_trailing_spaces_before_ellipsis
    assert_equal "ab…", clean("ab    cdef", max: 6)
  end

  def test_capped_forces_ellipsis_even_for_short_text
    assert_equal "abc…", clean("abcd", max: 4, capped: true)
    assert_equal "ab…", clean("ab", max: 3, capped: true)
    assert_equal "…", clean("ab", max: 1, capped: true)
  end
end
