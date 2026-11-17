# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../rakelib/docs_check"

# The parsing behind `rake docs:check` (rakelib/docs_check.rb). The check itself runs on the real
# repository in CI; these tests pin how it reads Markdown, so a passing check means what it says.
class DocsCheckTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_slug_matches_github_anchors
    {
      "Installation" => "installation",
      "Rails in three lines" => "rails-in-three-lines",
      "How do I convert a CSV file to a PNG image in Ruby?" => "how-do-i-convert-a-csv-file-to-a-png-image-in-ruby",
      "Does csv_preview need ImageMagick? What if my ImageMagick policy blocks TEXT, LABEL or SVG?" =>
        "does-csv_preview-need-imagemagick-what-if-my-imagemagick-policy-blocks-text-label-or-svg",
      "Why does Active Storage raise `UnpreviewableError`?" => "why-does-active-storage-raise-unpreviewableerror",
      "Licence and credits" => "licence-and-credits",
      "Read the [guide](x.md) first" => "read-the-guide-first"
    }.each { |heading, anchor| assert_equal anchor, DocsCheck.slug(heading), heading }
  end

  def test_anchors_skip_code_blocks_and_number_repeats
    markdown = <<~MARKDOWN
      # csv_preview
      ## Errors
      ```ruby
      # Gemfile
      ```
      ### Errors
    MARKDOWN
    assert_equal Set["csv_preview", "errors", "errors-1"], DocsCheck.anchors(markdown)
  end

  def test_links_find_badges_images_html_and_references_but_not_code
    markdown = <<~MARKDOWN
      [![CI](https://example.com/badge.svg)](https://example.com/ci) see [the guide](docs/guide.md#setup).
      <img width="720" alt="x" src="https://example.com/hero.png">
      `sample.rows[0](x)` is code, and so is this:
      ```ruby
      [a](not-a-link.md)
      ```
      [ref]: CHANGELOG.md
    MARKDOWN
    assert_equal %w[https://example.com/badge.svg https://example.com/ci docs/guide.md#setup CHANGELOG.md
                    https://example.com/hero.png], DocsCheck.links(markdown)
  end

  def test_normalize_joins_wrapped_lines_and_drops_emphasis
    assert_equal "Beautiful CSV previews. No network.", DocsCheck.normalize("> **Beautiful CSV previews.**\n> No\n  network.")
  end

  def test_copy_deck_is_read_from_the_spec
    deck = DocsCheck.copy_deck(File.read(File.join(ROOT, DocsCheck::COPY_DECK)))
    assert_equal "Beautiful CSV previews for Active Storage.", deck.fetch("Tagline")
    assert_equal "No LibreOffice, no headless browser, no network.", deck.fetch("Differentiator")
    assert deck.fetch("Descriptor").start_with?("csv_preview is a Ruby gem")
    assert deck.fetch("Safety line").start_with?("Built for untrusted uploads")
    assert deck.fetch("Gem summary").start_with?("Render CSV and TSV files")
  end

  def test_pinned_api_methods_need_an_example_a_return_and_every_param
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib/csv_preview.rb"), <<~RUBY)
        module CsvPreview
          # @param source [String]
          # @return [String]
          # @example
          #   CsvPreview.render("a.csv")
          def self.render(source, **options) = source

          # @return [Boolean]
          def self.text_supported? = true
        end
      RUBY
      problems = DocsCheck.new(root).pinned_api_problems(%w[CsvPreview.render CsvPreview.text_supported? CsvPreview.sample])
      assert_equal ["yard: CsvPreview.render has no @param for options", "yard: CsvPreview.text_supported? has no @example",
                    "yard: CsvPreview.sample is not defined in lib/"], problems
    end
  end

  # A small repository with one broken link, one missing anchor and a security table that cites a test
  # that does not exist.
  def test_problems_are_reported_for_a_broken_repository
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test"))
      File.write(File.join(root, "test/safety_test.rb"), "def test_PS_25_no_subprocesses; end\n")
      File.write(File.join(root, "README.md"), <<~MARKDOWN)
        # csv_preview
        See [missing](missing.md), [nowhere](#nowhere) and [safety](test/safety_test.rb).

        ## Security

        | Guarantee | Proved by |
        |---|---|
        | No subprocesses | [PS-25](https://github.com/garyhtou/csv_preview/blob/main/test/safety_test.rb) |
        | No network | [PS-26](https://github.com/garyhtou/csv_preview/blob/main/test/safety_test.rb), PS-99 |
      MARKDOWN
      check = DocsCheck.new(root, yard: false)

      links = check.link_problems
      assert_equal 2, links.size, links.inspect
      assert(links.any? { |p| p.include?("missing.md does not exist") })
      assert(links.any? { |p| p.include?("#nowhere") })

      table = check.security_table_problems
      assert(table.any? { |p| p.include?("PS-99 without linking") }, table.inspect)
      assert(table.any? { |p| p.include?("no def test_PS_26_* test") }, table.inspect)
      refute(table.any? { |p| p.include?("PS-25") }, table.inspect)
    end
  end
end
