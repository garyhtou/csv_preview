# frozen_string_literal: true

Rails.application.config.to_prepare do
  ActiveStorage::PreviewImageJob.discard_on ActiveStorage::PreviewError
  ActiveStorage::TransformJob.discard_on ActiveStorage::PreviewError
end
