# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.cache_classes = true
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr
  config.csv_preview.register_previewer = true if ENV["CSV_PREVIEW_SCENARIO"] == "e"
end
