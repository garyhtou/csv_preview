# frozen_string_literal: true

# Boots test/dummy (Active Record, Active Job and Active Storage only) for the Active Storage tests.
# The core tests never load this file.
ENV["RAILS_ENV"] = "test"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
# Scratch space (database, storage, log). A child process that boots the dummy app points this at its
# own directory so it never touches the parent run's database.
DUMMY_TMP = ENV.fetch("CSV_PREVIEW_DUMMY_TMP") { File.expand_path("../tmp", __dir__) }
FileUtils.mkdir_p(DUMMY_TMP)

require_relative "dummy/config/environment"
require "active_support/test_case"
require "active_job/test_helper"
require "minitest/autorun"
require_relative "support/fixtures"
require_relative "support/images"
require_relative "dummy/lib/other_csv_previewer"

# The schema comes from the installed Active Storage gem's own migration, so it is right for every
# Rails version, plus the dummy app's tables.
FileUtils.rm_f(Dir[File.join(DUMMY_TMP, "dummy_test.sqlite3*")])
ActiveRecord::Migration.verbose = false
load File.join(Gem.loaded_specs.fetch("activestorage").full_gem_path,
               "db/migrate/20170806125915_create_active_storage_tables.rb")
CreateActiveStorageTables.new.migrate(:up)
ActiveRecord::Schema.define do
  %i[documents plain_documents alternate_documents].each { |name| create_table(name) { |t| t.timestamps } }
end

# Helpers shared by the Active Storage tests.
module PreviewerTestHelper
  STORAGE_ROOTS = %w[storage storage_alternate storage_no_ranges].freeze

  def teardown
    super
    [ActiveStorage::Attachment, ActiveStorage::VariantRecord, ActiveStorage::Blob,
     Document, PlainDocument, AlternateDocument].each(&:delete_all)
    STORAGE_ROOTS.each { |name| FileUtils.rm_rf(File.join(DUMMY_TMP, name)) }
  end

  # Runs a block with a logger that captures what Active Storage and the previewer log.
  def capture_log
    io = StringIO.new
    original = ActiveStorage.logger
    ActiveStorage.logger = Logger.new(io, level: Logger::INFO)
    yield
    io.string
  ensure
    ActiveStorage.logger = original
  end

  # Runs a block with global configuration values changed, then restores the old configuration.
  def with_config(**values)
    original = CsvPreview.config
    CsvPreview.configure { |config| values.each { |name, value| config.public_send("#{name}=", value) } }
    yield
  ensure
    CsvPreview.instance_variable_set(:@config, original)
  end

  # Replaces CsvPreview.render for the block with a recorder that calls the real one (or raises).
  # @return [Array<Hash>] the options of each call, filled while the block runs
  def spy_on_render(raising: nil)
    calls = []
    original = CsvPreview.method(:render)
    CsvPreview.singleton_class.send(:define_method, :render) do |source, **options|
      calls << options
      raise raising if raising

      original.call(source, **options)
    end
    yield calls
    calls
  ensure
    CsvPreview.singleton_class.send(:define_method, :render, original)
  end

  def attach_fixture(model, name, content_type: nil, identify: true, record: nil)
    attach_bytes(model, File.binread(Fixtures.path(name)), name, content_type: content_type, identify: identify,
                                                                 record: record)
  end

  def attach_bytes(model, bytes, filename, content_type: nil, identify: true, record: nil)
    record ||= model.create!
    attachable = { io: StringIO.new(bytes), filename: filename, identify: identify }
    attachable[:content_type] = content_type if content_type
    record.file.attach(attachable)
    record.file.blob
  end

  # The events of the given names emitted while the block runs, as [name, payload] pairs.
  def collect_events(*names)
    events = []
    subscribers = names.map do |name|
      ActiveSupport::Notifications.subscribe(name) { |event| events << [event.name, event.payload.dup] }
    end
    yield
    events
  ensure
    subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
  end

  # Performs enqueued jobs, including the jobs they enqueue (PreviewImageJob, then TransformJob).
  def drain_jobs
    perform_enqueued_jobs while queue_adapter.enqueued_jobs.any?
  end

  def decode_png(bytes)
    assert_equal Images::PNG_SIGNATURE, bytes.byteslice(0, 8)
    Images.decode(bytes)
  end
end

class PreviewerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include PreviewerTestHelper
end
