# frozen_string_literal: true

require "open3"
require "rbconfig"

# Runs a script in a fresh Ruby process with the gem's lib directory on the load path. Used for
# behaviour that is per process: what loading the gem does, libvips being unloadable, cold font
# warm-up. The child inherits the environment (including Bundler's RUBYOPT) unless overridden.
module ChildRuby
  LIB = File.expand_path("../../lib", __dir__)

  module_function

  # @param script [String] Ruby source passed with -e
  # @param env [Hash] environment overrides; a nil value unsets the variable
  # @return [Array(String, String, Process::Status)] stdout, stderr and status
  def run(script, env: {})
    Open3.capture3(env, RbConfig.ruby, "-I", LIB, "-e", script)
  end
end
