# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# Boots the dummy Rails app in a fresh Ruby process with its own scratch directory (so the parent run's
# database and storage are untouched) and runs a script in it. Used for what is per process: the
# variant processor, libvips blocking untrusted operations (a write-only setting), and the
# ImageMagick policy. The child inherits the environment, including Bundler's, unless overridden.
module DummyChild
  TEST_DIR = File.expand_path("..", __dir__)
  LIB = File.expand_path("../../lib", __dir__)

  module_function

  # @param body [String] Ruby run after rails_helper loads; it prints with +report+
  # @param env [Hash] environment overrides
  # @return [Hash] what the child passed to +report+ (a JSON object)
  # @raise [RuntimeError] the child failed or reported nothing
  def run(body, env: {})
    Dir.mktmpdir("csvprev-dummy") do |dir|
      script = <<~RUBY
        require "rails_helper"
        def report(hash) = puts("CHILD-RESULT " + JSON.generate(hash))
        #{body}
      RUBY
      out, err, status = Open3.capture3({ "CSV_PREVIEW_DUMMY_TMP" => dir }.merge(env), RbConfig.ruby,
                                        "-I", LIB, "-I", TEST_DIR, "-e", script)
      line = out.lines.find { |l| l.start_with?("CHILD-RESULT ") }
      raise "child produced no result (#{status}):\n#{out}\n#{err}" unless line

      JSON.parse(line.delete_prefix("CHILD-RESULT "))
    end
  end

  # @return [String] bytes
  def decode(base64)
    Base64.strict_decode64(base64)
  end
end
