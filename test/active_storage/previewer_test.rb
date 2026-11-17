# frozen_string_literal: true

require_relative "../rails_helper"

# Acceptance tests AS-1 to AS-3 and AS-17 (active-storage.md 9.3).
class ActiveStoragePreviewerTest < PreviewerTest
  PREVIEWER = CsvPreview::ActiveStoragePreviewer

  def blob_with(content_type)
    ActiveStorage::Blob.new(content_type: content_type, filename: "x.csv", byte_size: 1, checksum: "x")
  end

  def test_AS_1_accept_by_content_type
    ["text/csv", "text/tab-separated-values", "TEXT/CSV", "text/csv; charset=utf-8"].each do |type|
      assert PREVIEWER.accept?(blob_with(type)), "expected #{type.inspect} to be accepted"
    end
    ["application/vnd.ms-excel", "image/png", "application/pdf", "text/plain", "", nil].each do |type|
      refute PREVIEWER.accept?(blob_with(type)), "expected #{type.inspect} to be rejected"
    end
  end

  def test_AS_2_the_list_is_configurable
    refute PREVIEWER.accept?(blob_with("text/x-csv"))
    with_config(previewer_content_types: CsvPreview.config.previewer_content_types + ["text/x-csv"]) do
      assert PREVIEWER.accept?(blob_with("text/x-csv"))
    end
    with_config(previewer_content_types: ["text/csv"]) do
      refute PREVIEWER.accept?(blob_with("text/tab-separated-values"))
      assert PREVIEWER.accept?(blob_with("text/csv"))
    end
    assert PREVIEWER.accept?(blob_with("text/tab-separated-values"))
    refute PREVIEWER.accept?(blob_with("text/x-csv"))
  end

  def test_AS_3_no_text_support
    blob = attach_fixture(PlainDocument, "simple.csv")
    reset_memo
    original = CsvPreview::Text.method(:supported?)
    CsvPreview::Text.singleton_class.send(:define_method, :supported?) { false }
    log = capture_log do
      refute PREVIEWER.accept?(blob_with("text/csv"))
      refute blob.previewable?
      refute blob.representable?
      refute PREVIEWER.text_supported?
    end

    assert_equal 1, log.scan("csv_preview: libvips has no text support (Pango)").size
  ensure
    CsvPreview::Text.singleton_class.send(:define_method, :supported?, original)
    reset_memo
  end

  def test_AS_17_core_errors_become_preview_errors
    blob = attach_fixture(PlainDocument, "wide_long.csv")

    with_config(timeout: 0.001) do
      error = assert_raises(ActiveStorage::PreviewError) { blob.preview(resize_to_limit: [300, 300]).processed }
      assert_instance_of CsvPreview::TimeoutExceeded, error.cause
      assert_match(/\ACsvPreview::TimeoutExceeded: /, error.message)
    end

    failure = CsvPreview::RenderFailed.new("stubbed failure")
    spy_on_render(raising: failure) do
      error = assert_raises(ActiveStorage::PreviewError) { blob.preview(resize_to_limit: [300, 300]).processed }
      assert_same failure, error.cause
    end
    refute blob.reload.preview_image.attached?
  end

  def test_AS_17_service_errors_propagate_unchanged
    blob = attach_fixture(PlainDocument, "simple.csv")
    blob.service.delete(blob.key)

    assert_raises(ActiveStorage::FileNotFoundError) { blob.preview(resize_to_limit: [300, 300]).processed }
  end

  private

  def reset_memo
    PREVIEWER.instance_variable_set(:@text_supported, nil)
  end
end
