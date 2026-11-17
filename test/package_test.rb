# frozen_string_literal: true

require "test_helper"
require "open3"
require "rubygems/package"
require "tmpdir"

# What ships in the gem (docs/spec/branding-and-discoverability.md 4.6): the code, fonts, skill and top-level
# docs, and nothing that bloats the package (tests, specs, scripts, images, llms.txt).
class PackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  TOP_LEVEL = %w[README.md CHANGELOG.md LICENSE SECURITY.md .yardopts].freeze

  def self.packaged_files
    @packaged_files ||= Dir.mktmpdir("csv_preview_package") do |dir|
      gem_path = File.join(dir, "csv_preview.gem")
      output, status = Open3.capture2e("gem", "build", "csv_preview.gemspec", "--output", gem_path, chdir: ROOT)
      raise "gem build failed:\n#{output}" unless status.success?

      Gem::Package.new(gem_path).contents.sort
    end
  end

  def tracked(*dirs)
    output, status = Open3.capture2e("git", "ls-files", "--", *dirs, chdir: ROOT)
    flunk "git ls-files failed (the package test needs git):\n#{output}" unless status.success?
    output.split("\n")
  end

  def packaged = self.class.packaged_files

  def test_packages_exactly_the_tracked_code_fonts_skill_and_top_level_docs
    assert_equal (tracked("lib", "fonts", "skills") + TOP_LEVEL).sort, packaged
  end

  def test_includes_the_licence_fonts_and_skill
    assert_includes packaged, "fonts/OFL.txt"
    assert_includes packaged, "skills/csv-preview/SKILL.md"
    assert_equal 2, packaged.count { |path| path.match?(%r{\Afonts/Inter.*\.(ttf|otf)\z}) }
  end

  def test_leaves_out_tests_docs_scripts_images_and_llms_txt
    assert_empty packaged.grep(%r{\A(test|docs|bin)/})
    assert_empty packaged.grep(/\.(png|jpe?g|webp|gif|svg)\z/i)
    refute_includes packaged, "llms.txt"
  end
end
