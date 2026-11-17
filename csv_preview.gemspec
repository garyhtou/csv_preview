# frozen_string_literal: true

require_relative "lib/csv_preview/version"

Gem::Specification.new do |spec|
  spec.name        = "csv_preview"
  spec.version     = CsvPreview::VERSION
  spec.authors     = ["Gary Tou"]
  spec.summary     = "Render CSV and TSV files as preview images and thumbnails (PNG, JPEG, WebP) " \
                     "using libvips. Includes an Active Storage previewer for Rails."
  spec.description = <<~TEXT.tr("\n", " ").strip
    csv_preview is a Ruby gem that renders CSV and TSV files as preview images (PNG, JPEG or WebP)
    and adds an Active Storage previewer to Rails. It turns the first rows of a file into a clean,
    readable table image: a thumbnail for a file list or a larger preview for a detail page. In Rails,
    CsvPreview::ActiveStoragePreviewer (an ActiveStorage::Previewer) makes CSV attachments work with
    blob.preview, blob.representation and previewable? the same way PDFs and videos do. It draws text
    with libvips (vips) and Pango, needs no LibreOffice, headless browser or ImageMagick, never starts
    another process or opens a network connection, and treats every file as untrusted input with
    bounded reads, memory and time.
  TEXT
  spec.homepage    = "https://github.com/garyhtou/csv_preview"
  spec.licenses    = ["MIT", "OFL-1.1"]
  spec.required_ruby_version = ">= 3.3"
  spec.requirements << "libvips 8.12 or newer with Pango text support"

  spec.metadata = {
    "homepage_uri" => "https://github.com/garyhtou/csv_preview",
    "source_code_uri" => "https://github.com/garyhtou/csv_preview/tree/v#{spec.version}",
    "changelog_uri" => "https://github.com/garyhtou/csv_preview/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://rubydoc.info/gems/csv_preview/#{spec.version}",
    "bug_tracker_uri" => "https://github.com/garyhtou/csv_preview/issues",
    "rubygems_mfa_required" => "true",
    "allowed_push_host" => "https://rubygems.org"
  }

  # .yardopts ships so rubydoc.info, which builds from the packaged gem, renders the Markdown docs.
  spec.files = Dir["lib/**/*", "fonts/*", "skills/**/*", "README.md", "CHANGELOG.md", "LICENSE", "SECURITY.md",
                   ".yardopts"]
                 .select { |path| File.file?(path) }
  spec.require_paths = ["lib"]

  spec.add_dependency "csv", ">= 3.2.8", "< 4"
  spec.add_dependency "ruby-vips", ">= 2.2.2", "< 3"
end
