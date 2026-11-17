# frozen_string_literal: true

# Stores its file on the alternate service, to prove the preview image follows the original.
class AlternateDocument < ApplicationRecord
  has_one_attached :file, service: :alternate
end
