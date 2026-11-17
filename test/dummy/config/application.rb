# frozen_string_literal: true

# Lets storage.yml name the no_ranges service (a Disk service whose download_chunk is unsupported).
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"
require "csv_preview"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.2
    # Rails 8.0 warns at boot unless this is set; 7.2 and 8.1 do not need it.
    config.active_support.to_time_preserves_timezone = :zone if Rails.gem_version.segments.first(2) == [8, 0]
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "csv_preview_dummy_secret_key_base"
    config.logger = Logger.new(File.join(ENV.fetch("CSV_PREVIEW_DUMMY_TMP") { File.expand_path("../../tmp", config.root) },
                                         "dummy_test.log"))
    config.active_job.queue_adapter = :test
    config.active_storage.service = :test
    config.active_storage.variant_processor = (ENV["VARIANT_PROCESSOR"] || "vips").to_sym

    # CSV_PREVIEW_SCENARIO picks one of the registration scenarios of AS-12 (see bin/boot_probe and
    # config/initializers/scenarios.rb). Unset, the app registers the previewer the explicit way: the
    # one line an app needs to preview CSV and TSV files.
    scenario = ENV.fetch("CSV_PREVIEW_SCENARIO", "b")
    config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer if %w[b g].include?(scenario)
    config.csv_preview.register_previewer = true if %w[d g h].include?(scenario)
  end
end
