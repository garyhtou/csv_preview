# frozen_string_literal: true

require "stringio"
require "active_storage"

module CsvPreview
  # An Active Storage previewer for CSV and TSV blobs. Register it with
  # `config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer`.
  #
  # It reads only the first `max_input_bytes` bytes of the blob (a ranged read), renders them with the
  # global {CsvPreview.config} and always yields a PNG.
  #
  # @example Register it in config/application.rb, inside the Application class
  #   config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer
  class ActiveStoragePreviewer < ActiveStorage::Previewer
    class << self
      # @param blob [ActiveStorage::Blob]
      # @return [Boolean] the content type is in `previewer_content_types` and libvips can draw text
      # @example Pick a CSV-only variant in a view
      #   variant = CsvPreview::ActiveStoragePreviewer.accept?(document.file.blob) ? :table_thumb : :thumb
      def accept?(blob)
        content_type_accepted?(blob.content_type) && text_supported?
      end

      # Cheap and memoised: never renders. Logs one warning the first time it is false.
      # @return [Boolean]
      # @example A Rails health check
      #   CsvPreview::ActiveStoragePreviewer.text_supported? # => true
      def text_supported?
        return @text_supported unless @text_supported.nil?

        @text_supported = CsvPreview::Text.supported?
        unless @text_supported
          ActiveStorage.logger&.warn("csv_preview: libvips has no text support (Pango), so CSV files " \
                                     "are not previewable in this process. Install libvips with Pango, see " \
                                     "#{CsvPreview::Help::INSTALLATION}")
        end
        @text_supported
      end

      private

      def content_type_accepted?(content_type)
        type = content_type.to_s.split(";", 2).first.to_s.strip.downcase
        return false if type.empty?

        CsvPreview.config.previewer_content_types.any? { |accepted| accepted.to_s.strip.downcase == type }
      end
    end

    # Renders the blob's preview image. Active Storage calls this; apps call `Blob#preview` or
    # `#representation` instead.
    #
    # @param options [Hash] passed through to the yielded attachable (`service_name:`); never to render
    # @yieldparam attachable [Hash] `io:`, `filename:`, `content_type:` plus `options`
    # @return [Object] whatever the block returns
    # @raise [ActiveStorage::PreviewError] when the core raises a {CsvPreview::Error}
    # @example What an app writes; Active Storage then calls #preview once per blob
    #   document.file.preview(resize_to_limit: [300, 300]).processed
    def preview(**options)
      png = render_image
      yield io: StringIO.new(png), filename: "#{blob.filename.base}.png", content_type: "image/png", **options
    end

    private

    # Extension point: per-call options for CsvPreview.render. `format` is always forced to :png, and
    # `max_input_bytes` also sets the size of the ranged read.
    def render_options
      {}
    end

    def render_image
      options = render_options.merge(format: :png)
      if (head = read_head(options))
        render(head, options)
      else
        download_blob_to_tempfile { |file| render(file, options) }
      end
    rescue CsvPreview::Error => error
      raise ActiveStorage::PreviewError, "#{error.class.name}: #{error.message}"
    end

    def render(source, options)
      instrument(:preview, key: blob.key) { CsvPreview.render(source, **options) }
    end

    # The first max_input_bytes bytes of the blob, or nil when the service cannot serve ranges.
    def read_head(options)
      limit = options.fetch(:max_input_bytes) { CsvPreview.config.max_input_bytes }
      length = [blob.byte_size.to_i, limit].min
      StringIO.new(length.positive? ? blob.download_chunk(0...length) : "".b)
    rescue NotImplementedError
      nil
    end
  end
end
