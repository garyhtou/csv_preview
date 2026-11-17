# frozen_string_literal: true

module CsvPreview
  # Option defaults and validation. The global instance is edited with {CsvPreview.configure};
  # each call takes a validated, frozen snapshot with {#resolve}.
  #
  # Every option except {#previewer_content_types} can also be passed per call to
  # {CsvPreview.render}, {CsvPreview.sample} and {CsvPreview.layout}; per-call values win. Invalid
  # values raise `ArgumentError` before any input is read.
  #
  # @example Set defaults once at boot
  #   CsvPreview.configure do |config|
  #     config.max_rows = 12
  #     config.previewer_content_types += ["text/x-csv"]
  #   end
  class Configuration
    # The options that can be passed per call.
    OPTIONS = %i[
      max_input_bytes max_rows max_columns max_cell_chars max_width_px max_height_px
      scale timeout header_row delimiter encoding format theme font
    ].freeze

    # Options that must be positive Integers.
    POSITIVE_INTEGERS = %i[max_input_bytes max_rows max_columns max_cell_chars max_width_px max_height_px].freeze
    # Allowed values of {#scale}.
    SCALES = (1..4)
    # Allowed values of {#format}.
    FORMATS = %i[png jpeg webp].freeze
    # Allowed values of {#theme}.
    THEMES = %i[ledger].freeze
    # {#max_width_px} must be at least this times {#scale}.
    MIN_WIDTH_PER_SCALE = 160
    # {#max_height_px} must be at least this times {#scale}.
    MIN_HEIGHT_PER_SCALE = 110
    # Characters that cannot be a {#delimiter}.
    FORBIDDEN_DELIMITERS = ["\"", "\r", "\n", "\0"].freeze

    # @return [Integer] bytes read from the start of the source; nothing past this is read.
    #   Default 2_097_152 (2 MiB).
    attr_accessor :max_input_bytes
    # @return [Integer] data rows shown (the header is not counted). Default 20.
    attr_accessor :max_rows
    # @return [Integer] most columns kept and shown; fewer are shown if they do not fit. Default 12.
    attr_accessor :max_columns
    # @return [Integer] characters kept per cell before measuring; longer cells end in "…". Default 60.
    attr_accessor :max_cell_chars
    # @return [Integer] cap on output width in pixels, not a target: small tables produce narrower
    #   images. At least 160 * scale. Default 2048.
    attr_accessor :max_width_px
    # @return [Integer] cap on output height in pixels. At least 110 * scale. Default 2600.
    attr_accessor :max_height_px
    # @return [Integer] pixel density from 1 to 4; theme sizes are logical pixels times this. Default 2.
    attr_accessor :scale
    # @return [Numeric] wall-clock budget in seconds for one call, checked at checkpoints (no
    #   `Timeout.timeout`); past it the call raises {TimeoutExceeded}. Default 5.
    attr_accessor :timeout
    # @return [:auto, Boolean] whether the first row is a header; `:auto` detects it. Default `:auto`.
    attr_accessor :header_row
    # @return [:auto, String] `:auto` sniffs comma, semicolon, tab and pipe; or any single ASCII
    #   character other than a quote, CR, LF or NUL. Default `:auto`.
    attr_accessor :delimiter
    # @return [:auto, String] `:auto` detects UTF-8, UTF-16, UTF-32 and Windows-1252; or an encoding
    #   name such as "Windows-1252". Default `:auto`.
    attr_accessor :encoding
    # @return [Symbol] `:png`, `:jpeg` or `:webp`. The Active Storage previewer always produces PNG.
    #   Default `:png`.
    attr_accessor :format
    # @return [Symbol] the look; only `:ledger` in this version. Default `:ledger`.
    attr_accessor :theme
    # @return [String, nil] nil uses the bundled Inter; a String names a system font family instead.
    #   Default nil.
    attr_accessor :font
    # @return [Array<String>] content types the Active Storage previewer accepts (global only, not a
    #   per-call option). Default ["text/csv", "text/tab-separated-values"].
    attr_accessor :previewer_content_types

    # A configuration with the factory defaults (not yet validated or frozen; see {#resolve}).
    def initialize
      @max_input_bytes = 2_097_152
      @max_rows = 20
      @max_columns = 12
      @max_cell_chars = 60
      @max_width_px = 2048
      @max_height_px = 2600
      @scale = 2
      @timeout = 5
      @header_row = :auto
      @delimiter = :auto
      @encoding = :auto
      @format = :png
      @theme = :ledger
      @font = nil
      @previewer_content_types = ["text/csv", "text/tab-separated-values"]
    end

    # @param overrides [Hash] per-call option values; they win over this configuration
    # @return [Configuration] a validated, frozen snapshot
    # @raise [ArgumentError] on an unknown option or an invalid value
    def resolve(**overrides)
      unknown = overrides.keys - OPTIONS
      raise ArgumentError, "unknown option(s): #{unknown.map(&:inspect).join(", ")}" unless unknown.empty?

      snapshot = dup
      overrides.each { |key, value| snapshot.instance_variable_set(:"@#{key}", value) } # keys are in OPTIONS (checked above)
      snapshot.send(:validate!)
      snapshot.previewer_content_types = previewer_content_types.dup.freeze
      snapshot.freeze_string_options
      snapshot.freeze
    end

    # @api private
    def freeze_string_options
      @font = @font.dup.freeze if @font.is_a?(String)
      @delimiter = @delimiter.dup.freeze if @delimiter.is_a?(String)
      @encoding = @encoding.dup.freeze if @encoding.is_a?(String)
    end

    private

    def validate!
      POSITIVE_INTEGERS.each do |name|
        value = instance_variable_get(:"@#{name}") # name is a POSITIVE_INTEGERS constant
        raise ArgumentError, "#{name} must be a positive Integer" unless value.is_a?(Integer) && value.positive?
      end
      raise ArgumentError, "scale must be an Integer from 1 to 4" unless scale.is_a?(Integer) && SCALES.cover?(scale)

      min_width = MIN_WIDTH_PER_SCALE * scale
      min_height = MIN_HEIGHT_PER_SCALE * scale
      raise ArgumentError, "max_width_px must be at least #{min_width} at scale #{scale}" if max_width_px < min_width
      raise ArgumentError, "max_height_px must be at least #{min_height} at scale #{scale}" if max_height_px < min_height

      validate_timeout!
      validate_header_row!
      validate_delimiter!
      validate_encoding!
      raise ArgumentError, "format must be one of #{FORMATS.inspect}" unless FORMATS.include?(format)
      raise ArgumentError, "theme must be one of #{THEMES.inspect}" unless THEMES.include?(theme)
      raise ArgumentError, "font must be nil or a String" unless font.nil? || font.is_a?(String)
      validate_content_types!
    end

    def validate_content_types!
      return if previewer_content_types.is_a?(Array) && previewer_content_types.all?(String)

      raise ArgumentError, "previewer_content_types must be an Array of Strings"
    end

    def validate_timeout!
      return if timeout.is_a?(Numeric) && timeout.real? && timeout.positive? && timeout.to_f.finite?

      raise ArgumentError, "timeout must be a positive, finite Numeric"
    end

    def validate_header_row!
      return if [:auto, true, false].include?(header_row)

      raise ArgumentError, "header_row must be :auto, true or false"
    end

    def validate_delimiter!
      return if delimiter == :auto
      return if delimiter.is_a?(String) && delimiter.length == 1 && delimiter.ascii_only? &&
                !FORBIDDEN_DELIMITERS.include?(delimiter)

      raise ArgumentError, "delimiter must be :auto or a single ASCII character other than a quote, CR, LF or NUL"
    end

    def validate_encoding!
      return if encoding == :auto

      raise ArgumentError, "encoding must be :auto or an encoding name" unless encoding.is_a?(String)

      raise ArgumentError, "unsupported" if %w[internal external locale filesystem].include?(encoding.downcase)

      enc = Encoding.find(encoding)
      raise ArgumentError, "unsupported" if enc.nil? || enc.dummy? || enc == Encoding::BINARY

      Encoding::Converter.new(enc, Encoding::UTF_8) unless enc == Encoding::UTF_8
    rescue ArgumentError, Encoding::ConverterNotFoundError
      raise ArgumentError, "encoding must be :auto or a known encoding name"
    end
  end
end
