# frozen_string_literal: true

require "test_helper"

class CellKindTest < Minitest::Test
  K = CsvPreview::CellKind

  NUMBERS = [
    "1234.56", "$1,234.56", "-12.00", "(45.00)", "1.234,56 €", "12%",
    "USD 12.00", "12.00 USD", "−12.00", "-$1,284.50", "$-12.00",
    "€1.234,56", "12,50", "1\u00A0234,56", "1 234,56", "1'234.50", "1’234.50", "₹1,23,456", "R$ 12,00", "kr 100",
    "0", "0.5", ".5", "+7", "42", "1,284", "1.284", "1.5e10", "-3.5 %",
    "($45.00)", "$(45.00)", "12.00-"
  ].freeze

  TEXTS = [
    "02139", "94105-1234", "24692165073000312345678", "4111 1111 1111 1111",
    "•••• 4821", "INV-001", "ABC 12.00", "R2", "RM101",
    "(415) 555-1234", "415-555-1234", "+1 415 555 1234", "+44 20 7946 0958",
    "2026-03-14", "03/14/2026", "14.03.2026", "12:30", "1.2.3", "v1.2.3",
    "N/A", "-", "$", "%", "--12", "1,23,4", "12 34", "-$-12", "-2+3",
    "12.00 USD EUR", "hello"
  ].freeze

  def test_PS_11_every_listed_number_is_a_number
    NUMBERS.each { |s| assert_equal :number, K.cell(s), s.inspect }
  end

  def test_PS_11_numeric_column_is_number
    assert_equal :number, K.column(["12.00", "-", "N/A", "3.50", ""])
    assert_equal :number, K.column(%w[1 2 10])
    assert_equal :number, K.column(%w[1500000 250000 75000])
  end

  def test_PS_12_every_listed_non_number_is_text
    TEXTS.each { |s| assert_equal :text, K.cell(s), s.inspect }
  end

  def test_PS_12_identifier_columns_are_text
    assert_equal :text, K.column(%w[02139 94105 10001])
    assert_equal :text, K.column(%w[5942 5411 7230])
    assert_equal :text, K.column(%w[4821 1234 9999])
    assert_equal :text, K.column(%w[2026 2025 2024])
    assert_equal :text, K.column(%w[4155551234 4155551235])
    assert_equal :text, K.column(["24692165073000312345678", "24692165073000312345679"])
    assert_equal :text, K.column(["2026-03-14", "2026-03-15"])
  end

  def test_nbsp_thousands_separators_are_numbers
    assert_equal :number, K.cell("1\u00A0234,56\u00A0€")
    assert_equal :number, K.cell("1\u202F234,56\u202F€")
    assert_equal :number, K.column(["1\u00A0234,56\u00A0€", "12,00 €", "-3,50 €"])
  end

  def test_empty_cell
    assert_equal :empty, K.cell("")
  end

  def test_bare_integer_identifier_rules
    assert_equal :text, K.cell("0012")
    assert_equal :number, K.cell("0")
    assert_equal :number, K.cell("5942")
    assert_equal :number, K.cell("1" * 15)
    assert_equal :text, K.cell("1" * 16)
  end

  def test_cells_over_40_chars_are_text
    assert_equal :text, K.cell("1" * 41)
    assert_equal :text, K.cell("1," + "000," * 10 + "000")
  end

  def test_column_with_no_countable_cells_is_text
    assert_equal :text, K.column([])
    assert_equal :text, K.column(["", "-", "N/A", "null", "none", "nan", "\u2014"])
  end

  def test_column_needs_80_percent_numbers
    assert_equal :number, K.column(%w[1.5 2.5 3.5 4.5 abc])
    assert_equal :text, K.column(%w[1.5 2.5 3.5 abc def])
  end

  def test_single_identifier_like_value_is_still_a_number
    assert_equal :number, K.column(["5942"])
  end

  def test_mixed_width_integers_are_numbers
    assert_equal :number, K.column(%w[5942 12 300])
  end
end
