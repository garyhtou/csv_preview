# frozen_string_literal: true

require_relative "../rails_helper"

# Acceptance test AS-11 (active-storage.md 4.3): the first previewer that accepts a blob wins.
class OrderingTest < PreviewerTest
  def with_previewers(list)
    original = ActiveStorage.previewers
    ActiveStorage.previewers = list
    yield
  ensure
    ActiveStorage.previewers = original
  end

  def chosen_for(blob)
    ActiveStorage.previewers.detect { |klass| klass.accept?(blob) }
  end

  def test_AS_11_unshifted_csv_preview_wins_and_previews
    blob = attach_fixture(PlainDocument, "simple.csv")

    with_previewers([CsvPreview::ActiveStoragePreviewer, *ActiveStorage.previewers.dup, OtherCsvPreviewer].uniq) do
      assert_equal CsvPreview::ActiveStoragePreviewer, chosen_for(blob)
      blob.preview(resize_to_limit: [300, 300]).processed
      assert blob.preview_image.attached?
    end
  end

  def test_AS_11_appended_after_another_previewer_it_loses
    blob = attach_fixture(PlainDocument, "simple.csv")

    with_previewers([OtherCsvPreviewer, CsvPreview::ActiveStoragePreviewer]) do
      assert_equal OtherCsvPreviewer, chosen_for(blob)
    end
  end
end
