# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "support/fixtures"
require_relative "support/images"

# The README's plain Ruby examples run exactly as written, so the first snippet a visitor copies is
# known to work (branding-and-discoverability.md 4.9). Each runs in a fresh Ruby process inside a
# temporary directory that holds the orders.csv the examples read.
class ReadmeExampleTest < Minitest::Test
  README = File.expand_path("../README.md", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # The fenced Ruby blocks of the README section under "## <heading>", in order.
  def ruby_blocks(heading)
    section = File.read(README)[/^## #{Regexp.escape(heading)}\n(.*?)(?=^## |\z)/m, 1]
    refute_nil section, "README.md has a \"## #{heading}\" section"
    section.scan(/^```ruby\n(.*?)^```$/m).flatten
  end

  def run_example(script)
    Dir.mktmpdir do |dir|
      FileUtils.cp(Fixtures.path("wide_long.csv"), File.join(dir, "orders.csv"))
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script, chdir: dir)
      assert status.success?, "README example failed:\n#{script}\n#{err}"
      yield dir, out
    end
  end

  def test_plain_ruby_quick_start_runs_as_written
    blocks = ruby_blocks("Plain Ruby")
    assert_equal 1, blocks.size, "one example under ## Plain Ruby"
    assert_includes blocks.first, 'require "csv_preview"'

    run_example(blocks.first) do |dir, _out|
      png = File.binread(File.join(dir, "orders.png"))
      assert_equal Images::PNG_SIGNATURE, png.byteslice(0, 8)
    end
  end

  def test_plain_ruby_usage_examples_run_as_written
    blocks = ruby_blocks("Plain Ruby usage")
    refute_empty blocks
    run_example(blocks.join("\n")) do |dir, _out|
      assert Dir.glob(File.join(dir, "*.{png,jpg,webp}")).any?, "the examples write an image"
    end
  end
end
