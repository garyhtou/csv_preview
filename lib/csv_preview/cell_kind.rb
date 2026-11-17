# frozen_string_literal: true

module CsvPreview
  # Classifies sanitized cells and columns as numbers or text (numbers are right-aligned).
  # See docs/spec/parsing-and-safety.md section 6.
  # @api private
  module CellKind
    CURRENCY_CODES = %w[
      USD EUR GBP JPY CNY CAD AUD NZD CHF HKD SGD INR KRW TWD THB MYR IDR PHP VND
      MXN BRL ARS CLP COP PEN ZAR SEK NOK DKK ISK PLN CZK HUF RON TRY ILS AED SAR
      RUB UAH NGN KES EGP
    ].freeze
    SYMBOL = '(?:US\$|CA\$|C\$|A\$|AU\$|NZ\$|HK\$|S\$|R\$|MX\$|[$€£¥₹₩₽₪₫₱₴₺₦₵₸₼₾¢฿]|kr|Kč|zł)'
    CUR    = "(?:#{SYMBOL}|#{CURRENCY_CODES.join("|")})"
    SP     = '[ \u00A0\u202F]?'
    GROUP  = '[ \u00A0\u202F\u2009]'
    SIGN   = '[-+−]'
    NUM = "(?:" + [
      '\d{1,3}(?:,\d{3})+(?:\.\d+)?',
      '\d{1,3}(?:\.\d{3})+(?:,\d+)?',
      '\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d+)?',
      "\\d{1,3}(?:#{GROUP}\\d{3})+(?:[.,]\\d+)?",
      '\d{1,3}(?:[\'’]\d{3})+(?:\.\d+)?',
      '\d+(?:[.,]\d+)?(?:[eE][-+]?\d{1,3})?',
      '[.,]\d+'
    ].join("|") + ")"
    NUMBER = Regexp.new('\A(?:' + [
      "#{SIGN}?#{SP}#{NUM}#{SP}%",
      "#{SIGN}?#{SP}(?:#{CUR}#{SP})?#{NUM}(?:#{SP}#{CUR})?",
      "#{CUR}#{SP}#{SIGN}#{SP}#{NUM}",
      "(?:#{CUR}#{SP})?#{NUM}-",
      "\\(#{SP}(?:#{CUR}#{SP})?#{NUM}(?:#{SP}#{CUR})?#{SP}\\)",
      "#{CUR}#{SP}\\(#{NUM}\\)"
    ].join("|") + ')\z')
    BARE_INTEGER      = /\A\d+\z/
    PLACEHOLDER       = /\A(?:[-‐-―−]{1,3}|n\/?a|null|none|nan)\z/i
    MAX_NUMBER_LENGTH = 40
    NUMBER_SHARE      = 0.8

    module_function

    # @param s [String] a sanitized cell
    # @return [Symbol] :empty, :number or :text
    def cell(s)
      return :empty if s.empty?
      return :text if s.length > MAX_NUMBER_LENGTH || !NUMBER.match?(s)
      return :text if BARE_INTEGER.match?(s) && (s.length > 15 || (s.length > 1 && s.start_with?("0")))

      :number
    end

    # @param cells [Array<String>] sanitized data cells of one column (header excluded)
    # @return [Symbol] :number or :text
    def column(cells)
      numbers = []
      texts = 0
      cells.each do |c|
        next if c.empty? || PLACEHOLDER.match?(c)

        cell(c) == :number ? numbers << c : texts += 1
      end
      return :text if numbers.empty? || numbers.size < NUMBER_SHARE * (numbers.size + texts)
      return :text if identifier_like?(numbers)

      :number
    end

    # Every numeric cell is a bare integer, there are at least two, and all have the
    # same number of digits, at least 4: MCC codes, last-4, years, phone numbers.
    def identifier_like?(numbers)
      numbers.size >= 2 && numbers.all? { |n| BARE_INTEGER.match?(n) } &&
        numbers.map(&:length).uniq.then { |l| l.size == 1 && l[0] >= 4 }
    end
  end
end
