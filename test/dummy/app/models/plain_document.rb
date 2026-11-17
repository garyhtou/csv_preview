# frozen_string_literal: true

class PlainDocument < ApplicationRecord
  has_one_attached :file
end
