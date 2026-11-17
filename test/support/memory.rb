# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "child_ruby"

# Peak memory growth of a piece of work, measured in fresh Ruby processes so the test process's own
# allocations do not count. The child warms up, runs the work, and reports its own peak resident set size
# (Linux: VmHWM, as in parsing-and-safety.md PS-19). macOS has no cheap in-process peak without Fiddle,
# which Ruby 4 no longer ships by default, so there the parent runs the child under /usr/bin/time -l
# twice, once with the work skipped, and takes the difference of the two maximum resident set sizes.
# Spawning processes is fine here: this is test code, never part of lib/.
#
# The child raises the global timeout to 600 s. These tests measure memory; the time bounds are asserted
# in-process by the tests that own them (PS-18 to PS-20), so a loaded machine must slow a measurement
# down rather than turn it into a TimeoutExceeded (which made PS-18's measurement flaky on a busy Mac).
module Memory
  LINUX = File.readable?("/proc/self/status")

  module_function

  # @param work [String] Ruby source whose peak memory growth is measured; its value must be JSON-able
  # @param warmup [String] Ruby source run first (loads code paths), not counted
  # @param requires [Array<String>] absolute paths required in the child before the warm-up
  # @return [Hash] +:growth+ (bytes the peak rose), +:seconds+, +:output+ (the work's value)
  def measure(work, warmup: "", requires: [])
    script = child_script(work, warmup, requires)
    LINUX ? linux(script) : macos(script)
  end

  def child_script(work, warmup, requires)
    <<~RUBY
      require "csv_preview"
      require "json"
      CsvPreview.configure { |config| config.timeout = 600 }
      #{requires.map { |path| "require #{path.inspect}" }.join("\n")}
      #{warmup}
      GC.start
      hwm = -> { File.read("/proc/self/status")[/^VmHWM:\\s+(\\d+) kB/, 1].to_i * 1024 if File.readable?("/proc/self/status") }
      base = hwm.call
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ENV["MEMORY_SKIP_WORK"] ? nil : begin
        #{work}
      end
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts JSON.generate(growth: base && (hwm.call - base), seconds: seconds, output: result)
    RUBY
  end

  def linux(script)
    out, err, status = ChildRuby.run(script)
    raise "memory child failed: #{err}" unless status.success?

    JSON.parse(out.lines.last, symbolize_names: true)
  end

  def macos(script)
    full = run_timed(script, skip: false)
    idle = run_timed(script, skip: true)
    full[:result].merge(growth: [full[:max_rss] - idle[:max_rss], 0].max)
  end

  def run_timed(script, skip:)
    env = skip ? { "MEMORY_SKIP_WORK" => "1" } : {}
    out, err, status = Open3.capture3(env, "/usr/bin/time", "-l", RbConfig.ruby, "-I", ChildRuby::LIB, "-e", script)
    raise "memory child failed: #{err}" unless status.success?

    { result: JSON.parse(out.lines.last, symbolize_names: true),
      max_rss: err[/(\d+)\s+maximum resident set size/, 1].to_i }
  end
end
