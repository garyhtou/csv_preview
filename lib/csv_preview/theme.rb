# frozen_string_literal: true

module CsvPreview
  # Every colour, size and structural switch the layout and painter use, as one immutable value
  # (rendering.md section 2). Sizes are logical px; {#px} converts a token to device px. No other
  # file holds a visual literal.
  #
  # Values are validated at construction. Colours, weights and the font family end up in Pango markup
  # attributes and font descriptions, so validation is also what keeps them safe there.
  # @api private
  Theme = Data.define(
    :name,
    :font_family,
    :body_size, :body_weight,
    :header_size, :header_weight,
    :footer_size, :footer_weight,
    :number_features,
    :true_minus,
    :text_color,
    :muted_color,
    :header_text_color,
    :header_fill,
    :header_rule_color, :header_rule_width,
    :row_rule_color, :row_rule_width,
    :footer_rule_color, :footer_rule_width,
    :frame_color, :frame_width,
    :background,
    :header_height, :row_height, :footer_height,
    :cell_padding, :edge_padding,
    :min_column_width, :max_column_width,
    :min_width, :max_width,
    :fade_width, :fade_exponent,
    :peek_width,
    :empty_body_rows
  ) do
    def initialize(**tokens)
      Theme::Validation.validate!(tokens)
      super
    end

    # @param token [Symbol] a colour token, for example `:header_fill`
    # @return [Array(Integer, Integer, Integer)] its red, green and blue values
    def rgb(token)
      raise ArgumentError, "#{token.inspect} is not a colour token" unless Theme::COLORS.include?(token)

      token_value(token).delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
    end

    # Converts one token to device px. Applied once per token, never to sums, so rounding never
    # accumulates (rendering.md section 1).
    #
    # @param token [Symbol]
    # @param scale [Numeric]
    # @return [Integer]
    def px(token, scale)
      (token_value(token) * scale).round
    end

    # A rule or border width in device px: 0 when the token is 0 (not drawn), else at least 1.
    #
    # @param token [Symbol] a rule or frame width token
    # @param scale [Numeric]
    # @return [Integer]
    def rule_px(token, scale)
      token_value(token).zero? ? 0 : [1, px(token, scale)].max
    end

    # The text styles in device px. `font` (the `font:` option) replaces the family only; the bundled
    # files are passed only when the family is the theme's own.
    #
    # @param scale [Integer]
    # @param font [String, nil]
    # @return [Styles]
    def styles(scale:, font: nil)
      tnum = !number_features.nil?
      style = lambda do |size, weight, color, features|
        Text::Style.new(family: font || font_family, fontfile: font ? nil : Theme::FONT_FILES.fetch(weight),
                        size_px: px(size, scale), weight: weight, color: color, tnum: features)
      end
      body = style.call(:body_size, body_weight, text_color, false)
      header = style.call(:header_size, header_weight, header_text_color, false)
      Theme::Styles.new(
        body: body,
        body_number: body.with(tnum: tnum),
        header: header,
        header_number: header.with(tnum: tnum),
        footer: style.call(:footer_size, footer_weight, muted_color, tnum),
        message: body.with(color: muted_color)
      )
    end

    private

    # One token's value. Tokens are internal constants, never input, so no dynamic send is needed.
    def token_value(token)
      deconstruct_keys([token]).fetch(token)
    end
  end

  class Theme
    # The text styles of one theme at one scale. Number columns use the `_number` styles (tabular
    # figures); the footer always does. Messages ("Empty file", "No rows") use the body size and
    # weight in the muted colour.
    Styles = Data.define(:body, :body_number, :header, :header_number, :footer, :message)

    # The bundled Inter files by weight. Theme weights must be one of these.
    FONT_FILES = { 400 => Text::REGULAR, 600 => Text::SEMIBOLD }.freeze

    COLORS = %i[
      text_color muted_color header_text_color header_fill header_rule_color row_rule_color footer_rule_color
      frame_color background
    ].freeze
    RULE_WIDTHS = %i[header_rule_width row_rule_width footer_rule_width frame_width].freeze
    WEIGHTS = %i[body_weight header_weight footer_weight].freeze
    SIZES = %i[
      body_size header_size footer_size header_height row_height footer_height cell_padding edge_padding
      min_column_width max_column_width min_width max_width fade_width peek_width empty_body_rows
    ].freeze
    COLOR_PATTERN = /\A#\h{6}\z/
    NUMBER_FEATURES = [nil, "tnum"].freeze

    # @api private
    module Validation
      module_function

      def validate!(t)
        raise ArgumentError, "name must be a Symbol" unless t[:name].is_a?(Symbol)

        family = t[:font_family]
        unless family.is_a?(String) && !family.strip.empty? && !family.match?(/[[:cntrl:]]/)
          raise ArgumentError, "font_family must be a non-empty String without control characters"
        end

        COLORS.each do |token|
          raise ArgumentError, "#{token} must be #RRGGBB" unless t[token].is_a?(String) && t[token].match?(COLOR_PATTERN)
        end
        SIZES.each do |token|
          raise ArgumentError, "#{token} must be a positive Integer" unless t[token].is_a?(Integer) && t[token].positive?
        end
        RULE_WIDTHS.each do |token|
          unless t[token].is_a?(Integer) && !t[token].negative?
            raise ArgumentError, "#{token} must be an Integer, 0 or more"
          end
        end
        WEIGHTS.each do |token|
          next if FONT_FILES.key?(t[token])

          raise ArgumentError, "#{token} must be #{FONT_FILES.keys.join(" or ")} (the bundled weights)"
        end
        validate_rest!(t)
      end

      def validate_rest!(t)
        unless NUMBER_FEATURES.include?(t[:number_features])
          raise ArgumentError, "number_features must be \"tnum\" or nil"
        end
        raise ArgumentError, "true_minus must be true or false" unless [true, false].include?(t[:true_minus])

        exponent = t[:fade_exponent]
        unless exponent.is_a?(Float) && exponent.positive? && exponent.finite?
          raise ArgumentError, "fade_exponent must be a positive, finite Float"
        end
        raise ArgumentError, "min_width must be at most max_width" if t[:min_width] > t[:max_width]
        if t[:min_column_width] > t[:max_column_width]
          raise ArgumentError, "min_column_width must be at most max_column_width"
        end
        raise ArgumentError, "edge_padding must be at least cell_padding" if t[:edge_padding] < t[:cell_padding]
      end
    end

    # The default look (rendering.md 2.2): logical px at scale 1.
    LEDGER = new(
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
    )

    ALL = { ledger: LEDGER }.freeze

    # @param name [Symbol]
    # @return [Theme]
    # @raise [ArgumentError] for an unknown name
    def self.fetch(name)
      ALL.fetch(name) { raise ArgumentError, "unknown theme #{name.inspect}" }
    end
  end
end
