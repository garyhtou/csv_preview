# frozen_string_literal: true

# The initializer-file registration scenarios of AS-12. A normal run sets no scenario and skips this.
require_relative "../../lib/other_csv_previewer"

case ENV["CSV_PREVIEW_SCENARIO"]
when "c"
  Rails.application.config.active_storage.previewers.unshift CsvPreview::ActiveStoragePreviewer
when "f"
  Rails.application.config.csv_preview.register_previewer = true
when "h"
  Rails.application.config.active_storage.previewers = [OtherCsvPreviewer]
end
