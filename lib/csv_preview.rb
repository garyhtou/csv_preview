# frozen_string_literal: true

# macOS: libvips ignores the bundled font unless Pango uses the fontconfig backend. This must be set
# before the first text draw, so it happens at load time. An application's own value is never replaced.
if RUBY_PLATFORM.include?("darwin") && ENV["PANGOCAIRO_BACKEND"].to_s.empty?
  ENV["PANGOCAIRO_BACKEND"] = "fontconfig"
end

require_relative "csv_preview/version"
require_relative "csv_preview/errors"
require_relative "csv_preview/configuration"
require_relative "csv_preview/deadline"
require_relative "csv_preview/reader"
require_relative "csv_preview/sanitizer"
require_relative "csv_preview/cell_kind"
require_relative "csv_preview/sample"
require_relative "csv_preview/parser"
require_relative "csv_preview/text"
require_relative "csv_preview/theme"
require_relative "csv_preview/layout"
require_relative "csv_preview/painter"

# Renders CSV and TSV files as preview images. ruby-vips is loaded lazily, never by this file.
module CsvPreview
  # Loaded on first reference; requires Active Storage. Nothing in the core requires it.
  autoload :ActiveStoragePreviewer, "csv_preview/active_storage_previewer"

  @config = Configuration.new.resolve

  class << self
    # Yields a mutable copy of the global configuration for editing at boot. The edited copy is
    # validated, frozen and swapped in with one assignment, so a render running concurrently never sees
    # a half-edited configuration. If the block or validation raises, the old configuration stays.
    # @yieldparam config [Configuration] a mutable copy of the current configuration
    # @return [Configuration] the new global configuration (frozen)
    # @raise [ArgumentError] an invalid value
    # @example Set defaults once at boot
    #   CsvPreview.configure do |config|
    #     config.max_rows = 12
    #     config.previewer_content_types += ["text/x-csv"]
    #   end
    def configure
      copy = @config.dup
      yield copy
      @config = copy.resolve
    end

    # @return [Configuration] the global defaults (frozen)
    # @example
    #   CsvPreview.config.max_rows # => 20
    def config
      @config
    end

    # Renders the first rows of a CSV or TSV source as an image. Empty input (0 bytes, or only blank
    # lines and whitespace) does not raise: it renders a small image saying the file is empty.
    #
    # @param source [String, Pathname, #read] a path, or an IO-like object read with `read(length)` only
    #   (never rewound or closed)
    # @param options [Hash] per-call options; see {Configuration}. `format` picks :png (default), :jpeg
    #   or :webp.
    # @return [String] the encoded image (binary)
    # @raise [ArgumentError] invalid options or source
    # @raise [UnreadableInput] binary or non-text content
    # @raise [RenderFailed] libvips is missing, cannot draw text, or cannot encode the format
    # @raise [TimeoutExceeded] the call ran past `timeout`
    # @raise [SystemCallError] the path cannot be opened or read (for example `Errno::ENOENT`)
    # @example Write a PNG preview of a file
    #   File.binwrite("orders.png", CsvPreview.render("orders.csv"))
    # @example Render CSV text from memory as WebP (a String is always a path, so wrap text in StringIO)
    #   webp = CsvPreview.render(StringIO.new("Fruit,Qty\nApple,3\n"), format: :webp, max_rows: 10)
    def render(source, **options)
      config = self.config.resolve(**options)
      deadline = Deadline.new(config.timeout)
      layout = build_layout(source, config, deadline)
      Painter.call(layout, format: config.format, deadline: deadline)
    end

    # Reads and parses a CSV or TSV source without rendering anything.
    #
    # @param source [String, Pathname, #read] a path, or an IO-like object read with `read(length)` only
    #   (never rewound or closed)
    # @param options [Hash] per-call options; see {Configuration}
    # @return [Sample]
    # @raise [ArgumentError] invalid options or source
    # @raise [UnreadableInput] binary or non-text content
    # @raise [TimeoutExceeded] the call ran past `timeout`
    # @raise [SystemCallError] the path cannot be opened or read (for example `Errno::ENOENT`)
    # @example
    #   sample = CsvPreview.sample("orders.csv")
    #   sample.headers.first(2) # => ["Transaction ID", "Date"]
    #   sample.total_rows       # => 1284, or nil when the file is larger than max_input_bytes
    def sample(source, **options)
      config = self.config.resolve(**options)
      read(source, config, Deadline.new(config.timeout))
    end

    # Reads, parses and lays out a source: which columns and rows are shown, their widths, the exact
    # display strings, the footer and the output size. For debugging and tests.
    #
    # @param source [String, Pathname, #read] as for {sample}
    # @param options [Hash] per-call options; see {Configuration}
    # @return [Layout]
    # @raise [ArgumentError] invalid options or source
    # @raise [UnreadableInput] binary or non-text content
    # @raise [RenderFailed] libvips is missing or cannot draw text
    # @raise [TimeoutExceeded] the call ran past `timeout`
    # @raise [SystemCallError] the path cannot be opened or read
    # @example
    #   layout = CsvPreview.layout("orders.csv")
    #   layout.footer_text                  # => "20 of 1,284 rows · 8 of 31 columns"
    #   [layout.width_px, layout.height_px] # => [2048, 1588]
    def layout(source, **options)
      config = self.config.resolve(**options)
      build_layout(source, config, Deadline.new(config.timeout))
    end

    # Restores factory defaults. Intended for tests.
    # @api private
    # @return [Configuration] the factory defaults (frozen)
    def reset_config!
      @config = Configuration.new.resolve
    end

    # Whether libvips is installed and can draw text. Cheap and never renders; loads ruby-vips on
    # first use.
    # @return [Boolean]
    # @example A health check
    #   raise "libvips cannot draw text" unless CsvPreview.text_supported?
    def text_supported?
      Text.supported?
    end

    private

    # One deadline covers the whole call, from the first read to the last step.
    def read(source, config, deadline)
      result = Reader.call(source, config: config, deadline: deadline)
      Parser.call(result, config: config, deadline: deadline)
    end

    def build_layout(source, config, deadline)
      sample = read(source, config, deadline)
      Layout.build(sample, config: config, theme: Theme.fetch(config.theme), deadline: deadline)
    end
  end
end

require_relative "csv_preview/railtie" if defined?(Rails::Railtie)
