# frozen_string_literal: true

require "rails/railtie"

module CsvPreview
  # Opt-in automatic registration of {ActiveStoragePreviewer}. Loaded by `lib/csv_preview.rb` only when
  # Rails is present. With `config.csv_preview.register_previewer = true` the previewer is put first in
  # `config.active_storage.previewers`; by default (false) nothing changes.
  class Railtie < Rails::Railtie
    config.csv_preview = ActiveSupport::OrderedOptions.new
    config.csv_preview.register_previewer = false

    # The flag is read after initializer files have run, hence the after_initialize hook. Active Storage
    # copies the previewer list in a hook registered by its "active_storage.configs" initializer, so
    # declaring this one before it registers this hook first. The list is changed in place, which keeps
    # `ActiveStorage.previewers` and the config value the same Array.
    initializer "csv_preview.register_previewer", before: "active_storage.configs" do |app|
      config.after_initialize do
        if app.config.csv_preview.register_previewer
          if defined?(ActiveStorage::Engine)
            previewers = (app.config.active_storage.previewers ||= [])
            unless previewers.include?(CsvPreview::ActiveStoragePreviewer)
              previewers.unshift(CsvPreview::ActiveStoragePreviewer)
            end
          else
            Rails.logger&.warn("csv_preview: config.csv_preview.register_previewer is true, but Active Storage is " \
                               "not loaded; see #{CsvPreview::Help::RAILS}")
          end
        end

        Railtie.warm_up(app)
      end
    end

    class << self
      # Pays the one-time font and Pango set-up cost at boot instead of in the first request, but only
      # when the previewer is registered (by either route) and the app has not chosen its own font (an
      # app that always passes `font:` never needs the bundled-font self-check, rendering.md 5.4).
      # @api private
      def warm_up(app)
        return unless defined?(ActiveStorage::Engine)
        # A pending autoload means nothing has referenced the previewer, so it cannot be in the list.
        # Checking that first keeps this gate from loading the previewer in apps that never opted in.
        return if CsvPreview.autoload?(:ActiveStoragePreviewer)
        return unless app.config.active_storage.previewers&.include?(CsvPreview::ActiveStoragePreviewer)
        return unless CsvPreview.config.font.nil? && CsvPreview::Text.supported?

        CsvPreview::Text.warm_up!
      rescue CsvPreview::Error => e
        Rails.logger&.warn("csv_preview: font warm-up failed (#{e.class}: #{e.message})")
      end
    end
  end
end
