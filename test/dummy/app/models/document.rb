# frozen_string_literal: true

# A CSV attachment with a preprocessed variant, so uploads enqueue ActiveStorage::PreviewImageJob.
class Document < ApplicationRecord
  has_one_attached :file do |attachable|
    attachable.variant :thumb, resize_to_limit: [100, 100], preprocessed: true
  end
end
