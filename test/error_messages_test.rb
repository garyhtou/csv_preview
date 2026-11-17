# frozen_string_literal: true

require "test_helper"
require "delegate"
require "stringio"
require_relative "support/fixtures"

# Fails one libvips call while a key is set on the thread, so each RenderFailed path can be reached.
module ErrorMessagesVipsFailures
  module Text
    def text(...)
      raise Vips::Error, "boom" if Thread.current[:csv_preview_fail_vips] == :text

      super
    end
  end

  module Image
    def write_to_buffer(...)
      raise Vips::Error, "boom" if Thread.current[:csv_preview_fail_vips] == :encode

      super
    end

    def composite(...)
      raise Vips::Error, "boom" if Thread.current[:csv_preview_fail_vips] == :composite

      super
    end
  end
end

# Reports no text support while a key is set on the thread (prepending avoids redefining the method).
module ErrorMessagesNoTextSupport
  def supported?
    Thread.current[:csv_preview_no_text_support] ? false : super
  end
end

CsvPreview::Text.singleton_class.prepend(ErrorMessagesNoTextSupport)
CsvPreview.text_supported? # loads ruby-vips so the failure hooks can be installed
Vips::Image.singleton_class.prepend(ErrorMessagesVipsFailures::Text)
Vips::Image.prepend(ErrorMessagesVipsFailures::Image)

# Every CsvPreview::Error message says what to do next and links the README section that explains it,
# so a person or a coding agent reading a log knows where the fix is documented
# (branding-and-discoverability.md 4.8). Messages still never quote the input (PS-33).
class ErrorMessagesTest < Minitest::Test
  REPO = "https://github.com/garyhtou/csv_preview"
  LIB = File.expand_path("../lib", __dir__)
  MARKER = "SECRET-7f3a"
  ERROR_CLASSES = /raise (RenderFailed|UnreadableInput|TimeoutExceeded)\b/

  def failing(operation)
    Thread.current[:csv_preview_fail_vips] = operation
    yield
  ensure
    Thread.current[:csv_preview_fail_vips] = nil
  end

  def test_help_links_point_at_the_readme
    assert_equal "#{REPO}#installation", CsvPreview::Help::INSTALLATION
    assert_equal "#{REPO}#errors", CsvPreview::Help::ERRORS
    assert_equal "#{REPO}#options", CsvPreview::Help::OPTIONS
    assert_equal "#{REPO}/issues", CsvPreview::Help::ISSUES
  end

  def test_unreadable_input_links_the_errors_section
    %w[png zip xls pdf].each do |kind|
      error = assert_raises(CsvPreview::UnreadableInput, kind) { CsvPreview.sample(Fixtures.path("#{kind}_renamed.csv")) }
      assert_includes error.message, "#{REPO}#errors", kind
    end
    ["a,b\n\x00#{MARKER}".b, (("\x01" + MARKER) * 400).b, "\xFF\xFEa\x00\x00\x00#{MARKER}".b].each do |bytes|
      error = assert_raises(CsvPreview::UnreadableInput) { CsvPreview.sample(StringIO.new(bytes)) }
      assert_includes error.message, "#{REPO}#errors"
      refute_includes error.message, MARKER
    end
  end

  def test_timeout_names_the_stage_and_links_the_errors_section
    error = assert_raises(CsvPreview::TimeoutExceeded) do
      CsvPreview.render(Fixtures.path("wide_long.csv"), timeout: 0.001)
    end
    assert_match(/\Acsv_preview exceeded its 0\.001s timeout \(\w+\)\. /, error.message)
    assert_includes error.message, "#{REPO}#errors"
  end

  def test_failed_text_drawing_links_installation
    error = assert_raises(CsvPreview::RenderFailed) do
      failing(:text) { CsvPreview.render(StringIO.new("#{MARKER},b\n1,2\n")) }
    end
    assert_includes error.message, "#{REPO}#installation"
    refute_includes error.message, MARKER
  end

  def test_failed_painting_links_installation
    layout = CsvPreview.layout(Fixtures.path("simple.csv"))
    error = assert_raises(CsvPreview::RenderFailed) do
      failing(:composite) { CsvPreview::Painter.call(layout, format: :png, deadline: CsvPreview::Deadline.new(60)) }
    end
    assert_includes error.message, "#{REPO}#installation"
  end

  def test_missing_saver_links_options
    error = assert_raises(CsvPreview::RenderFailed) do
      failing(:encode) { CsvPreview.render(Fixtures.path("simple.csv"), format: :webp) }
    end
    assert_includes error.message, "format: :png"
    assert_includes error.message, "#{REPO}#options"
  end

  def test_missing_text_support_in_the_painter_links_installation
    layout = CsvPreview.layout(Fixtures.path("simple.csv"))
    Thread.current[:csv_preview_no_text_support] = true
    error = assert_raises(CsvPreview::RenderFailed) do
      CsvPreview::Painter.call(layout, format: :png, deadline: CsvPreview::Deadline.new(60))
    end
    assert_includes error.message, "#{REPO}#installation"
  ensure
    Thread.current[:csv_preview_no_text_support] = nil
  end

  def test_size_cap_bugs_ask_for_a_bug_report
    layout = CsvPreview.layout(Fixtures.path("simple.csv"))
    narrow = Class.new(SimpleDelegator) { def max_width_px = width_px - 1 }.new(layout)
    error = assert_raises(CsvPreview::RenderFailed) do
      CsvPreview::Painter.call(narrow, format: :png, deadline: CsvPreview::Deadline.new(60))
    end
    assert_includes error.message, "#{REPO}/issues"
  end

  # Message parts named *_HINT end with a help link.
  def test_hint_constants_link_the_readme
    modules = CsvPreview.constants.reject { |name| CsvPreview.autoload?(name) }.map { |name| CsvPreview.const_get(name) }
    hints = modules.grep(Module).flat_map do |mod|
      mod.constants(false).grep(/_HINT\z/).map { |name| ["#{mod}::#{name}", mod.const_get(name)] }
    end
    assert_operator hints.size, :>=, 3
    hints.each { |name, value| assert_includes value, "#{REPO}#", name }
  end

  # Every place lib/ raises one of the gem's errors builds its message with a help link: a Help
  # constant, or a *_HINT constant (the support-problem strings end with INSTALL_HINT).
  def test_every_raise_in_lib_carries_a_help_link
    sites = 0
    Dir[File.join(LIB, "**/*.rb")].each do |path|
      lines = File.readlines(path)
      lines.each_index do |start|
        next unless lines[start].match?(ERROR_CLASSES)

        sites += 1
        finish = start
        finish += 1 while lines[finish].rstrip.end_with?("\\", ",") && lines[finish + 1]
        statement = lines[start..finish].join
        assert_match(/Help::|[A-Z]_HINT\b|raise RenderFailed, problem if problem/, statement,
                     "#{File.basename(path)}:#{start + 1} raises without a help link")
      end
    end
    assert_operator sites, :>=, 10
  end
end
