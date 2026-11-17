# frozen_string_literal: true

require_relative "../rails_helper"
require_relative "../support/dummy_child"

# Acceptance tests AS-4 to AS-10, AS-13 to AS-16, AS-18 and AS-20 (active-storage.md 9.3).
class ActiveStoragePreviewFlowTest < PreviewerTest
  def processed_png(blob, box = [300, 300])
    blob.preview(resize_to_limit: box).processed
  end

  def test_AS_4_basic_preview
    blob = attach_fixture(PlainDocument, "simple.csv")

    assert_equal "text/csv", blob.content_type
    assert blob.previewable?
    assert blob.representable?
    preview = processed_png(blob)
    assert_equal "image/png", blob.preview_image.content_type
    assert_equal "simple.png", blob.preview_image.filename.to_s
    image = decode_png(preview.download)
    assert_operator image.width, :<=, 300
    assert_operator image.height, :<=, 300
    assert_instance_of ActiveStorage::Preview, blob.representation(resize_to_limit: [300, 300])
  end

  def test_AS_5_tsv
    blob = attach_fixture(PlainDocument, "tabs.tsv")

    assert_equal "text/tab-separated-values", blob.content_type
    assert blob.previewable?
    processed_png(blob)
    assert_equal "tabs.png", blob.preview_image.filename.to_s
  end

  def test_AS_6_options_pass_through_and_format
    blob = attach_fixture(AlternateDocument, "simple.csv")
    assert_equal "alternate", blob.service_name

    calls = spy_on_render { processed_png(blob) }
    assert_equal "alternate", blob.preview_image.blob.service_name
    assert_equal [{ format: :png }], calls

    other = attach_fixture(PlainDocument, "simple.csv")
    with_config(format: :jpeg) { processed_png(other) }
    assert_equal "image/png", other.preview_image.content_type
    assert_equal Images::PNG_SIGNATURE, other.preview_image.blob.download.byteslice(0, 8)
  end

  def test_AS_7_preprocessed_variant
    document = nil
    calls = spy_on_render do
      assert_enqueued_jobs 1, only: ActiveStorage::PreviewImageJob do
        document = attach_fixture(Document, "simple.csv") && Document.last
      end
      drain_jobs
    end

    assert_equal 1, calls.size
    blob = document.file.blob
    assert blob.preview_image.attached?
    assert_equal 1, ActiveStorage::VariantRecord.where(blob_id: blob.preview_image.blob.id).count

    later = spy_on_render { document.file.representation(:thumb).processed }
    assert_empty later
  end

  def test_AS_8_unreadable_file
    bytes = File.binread(Fixtures.path("png_renamed.csv"))
    blob = attach_bytes(PlainDocument, bytes, "png_renamed.csv", content_type: "text/csv", identify: false)
    assert_equal "text/csv", blob.content_type

    error = assert_raises(ActiveStorage::PreviewError) { processed_png(blob) }
    assert error.message.start_with?("CsvPreview::UnreadableInput: "), error.message
    refute_includes error.message.b, bytes.byteslice(0, 16)
    assert_instance_of CsvPreview::UnreadableInput, error.cause
    refute blob.reload.preview_image.attached?
  end

  def test_AS_9_discarded_job
    bytes = File.binread(Fixtures.path("png_renamed.csv"))
    document = Document.create!(file: { io: StringIO.new(bytes), filename: "png_renamed.csv",
                                        content_type: "text/csv", identify: false })
    assert_enqueued_jobs 1, only: ActiveStorage::PreviewImageJob

    assert_nothing_raised { drain_jobs }
    assert_no_enqueued_jobs
    refute document.file.blob.reload.preview_image.attached?
  end

  def test_AS_10_identification_stops_renamed_binaries
    blob = attach_fixture(PlainDocument, "png_renamed.csv")

    assert_equal "image/png", blob.content_type
    refute CsvPreview::ActiveStoragePreviewer.accept?(blob)
  end

  def test_AS_13_bounded_read
    path = Fixtures.generate("six_mb.csv")
    blob = attach_bytes(PlainDocument, File.binread(path), "six_mb.csv", content_type: "text/csv", identify: false)
    limit = CsvPreview.config.max_input_bytes

    events = collect_events("service_download_chunk.active_storage", "service_download.active_storage") do
      processed_png(blob)
    end
    mine = events.select { |_, payload| payload[:key] == blob.key }
    assert_equal ["service_download_chunk.active_storage"], mine.map(&:first)
    assert_equal 0...limit, mine.first.last[:range]
    assert_equal CsvPreview.render(File.open(path), format: :png), blob.preview_image.blob.download
  end

  def test_AS_13_render_options_set_the_range
    path = Fixtures.generate("six_mb.csv")
    blob = attach_bytes(PlainDocument, File.binread(path), "six_mb.csv", content_type: "text/csv", identify: false)
    subclass = Class.new(CsvPreview::ActiveStoragePreviewer) do
      private

      def render_options = super.merge(max_input_bytes: 1024)
    end

    events = collect_events("service_download_chunk.active_storage") do
      subclass.new(blob).preview { |attachable| attachable[:io].read }
    end
    assert_equal [0...1024], events.map { |_, payload| payload[:range] }
  end

  def test_AS_14_empty_blob
    blob = attach_bytes(PlainDocument, "", "empty.csv", content_type: "text/csv", identify: false)

    events = collect_events("service_download_chunk.active_storage", "service_download.active_storage") do
      processed_png(blob)
    end
    assert_empty events.select { |_, payload| payload[:key] == blob.key }
    assert blob.preview_image.attached?
    expected = CsvPreview.render(File.join(Fixtures::CHECKED_IN, "empty.csv"), format: :png)
    assert_equal expected, blob.preview_image.blob.download
  end

  def test_AS_15_services_without_ranged_reads
    blob = attach_fixture(PlainDocument, "simple.csv")
    no_ranges = ActiveStorage::Blob.services.fetch(:no_ranges)
    original = ActiveStorage::Blob.service
    blob.update!(service_name: "no_ranges")
    no_ranges.upload(blob.key, StringIO.new(File.binread(Fixtures.path("simple.csv"))))
    assert_raises(NotImplementedError) { no_ranges.download_chunk(blob.key, 0...10) }

    processed_png(blob)
    assert blob.preview_image.attached?
  ensure
    ActiveStorage::Blob.service = original if original
  end

  def test_AS_16_instrumentation
    blob = attach_fixture(PlainDocument, "simple.csv")

    events = nil
    log = capture_log do
      events = collect_events("preview.active_storage") { processed_png(blob) }
    end
    assert_equal [blob.key], events.map { |_, payload| payload[:key] }
    assert_includes log, "Previewed file from key: #{blob.key}"
  end

  # Vips.block_untrusted is write-only, so setting it here would hide rendering regressions from every
  # later test on Rails versions that do not set it themselves. It runs in a child process instead.
  def test_AS_18_untrusted_operations_blocked
    result = DummyChild.run(<<~RUBY)
      Vips.block_untrusted(true)
      model = PlainDocument.create!
      model.file.attach(io: File.open(Fixtures.path("simple.csv")), filename: "simple.csv")
      model.file.blob.preview(resize_to_limit: [300, 300]).processed
      report(attached: model.file.blob.preview_image.attached?)
    RUBY

    assert result.fetch("attached")
  end

  def test_AS_20_concurrent_previews
    blobs = Array.new(8) { |i| attach_bytes(PlainDocument, "a,b\n#{i},x\n", "n#{i}.csv", content_type: "text/csv", identify: false) }
    ids = Queue.new
    blobs.each { |blob| ids << blob.id }
    errors = Queue.new

    threads = Array.new(4) do
      Thread.new do
        while (id = ids.pop(true) rescue nil)
          Rails.application.executor.wrap do
            ActiveStorage::Blob.find(id).preview(resize_to_limit: [300, 300]).processed
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors << e
      end
    end
    threads.each(&:join)

    assert_predicate errors, :empty?, errors.empty? ? nil : errors.pop.inspect
    assert_equal [1] * 8, blobs.map { |blob| ActiveStorage::Attachment.where(record: blob, name: "preview_image").count }
  end
end
