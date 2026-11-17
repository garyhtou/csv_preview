# frozen_string_literal: true

require "active_storage"

# Stands in for an office-suite previewer: accepts CSV and must never be asked to render it.
class OtherCsvPreviewer < ActiveStorage::Previewer
  def self.accept?(blob)
    blob.content_type == "text/csv"
  end

  def preview(**)
    raise "OtherCsvPreviewer was asked to render"
  end
end
