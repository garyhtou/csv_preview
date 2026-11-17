# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "support/child_ruby"
require "support/fixtures"

# PS-30 and Review Focus 4: concurrent renders give the serial results, including from a cold start.
class ThreadSafetyTest < Minitest::Test
  NAMES = %w[simple.csv wide_long.csv numbers.csv emoji_cjk.csv quoted_newlines.csv bidi.csv
             windows1252.csv markup.csv].freeze

  def teardown
    CsvPreview.reset_config!
  end

  def digest(name)
    Digest::SHA256.hexdigest(CsvPreview.render(Fixtures.path(name)))
  end

  def test_PS_30_eight_threads_ten_iterations_match_serial_digests
    serial = NAMES.to_h { |name| [name, digest(name)] }

    threads = NAMES.map do |name|
      Thread.new { Array.new(10) { digest(name) } }
    end
    threads.each_with_index do |thread, i|
      assert_equal [serial.fetch(NAMES[i])] * 10, thread.value, NAMES[i]
    end
  end

  def test_PS_30_config_is_frozen_and_configure_replaces_it
    before = CsvPreview.config

    assert_predicate before, :frozen?
    CsvPreview.configure { |config| config.max_rows = 7 }
    after = CsvPreview.config

    refute_same before, after
    assert_predicate after, :frozen?
    assert_equal 7, after.max_rows
    assert_equal 20, before.max_rows
    assert_raises(FrozenError) { after.max_rows = 1 }
  end

  # Each call must take exactly one snapshot of the global config at entry (parsing-and-safety.md 10).
  # Runs in a child process so the read counter is never installed in the test process. The counter
  # proves one read per call; the flipper proves configure really ran during the layouts, so each layout
  # used one consistent snapshot (rows_shown is the old or the new value).
  def test_concurrent_configure_takes_one_snapshot_per_call
    out, err, status = ChildRuby.run(<<~RUBY)
      require "csv_preview"
      require "json"
      path = #{Fixtures.path("wide_long.csv").inspect}
      CsvPreview.configure { |config| config.max_rows = 3 }
      CsvPreview.layout(path) # warm-up reads the config for font metrics once per process
      Counting = Module.new do
        def config
          Thread.current[:config_reads] += 1 if Thread.current[:config_reads]
          super
        end
      end
      CsvPreview.singleton_class.prepend(Counting)
      flips = 0
      stop = false
      flipper = Thread.new do
        [3, 5].cycle do |n|
          break if stop

          CsvPreview.configure { |config| config.max_rows = n }
          flips += 1
          sleep 0.001
        end
      ensure
        stop = true
      end
      sizes = []
      reads = []
      begin
        sleep 0.01 until flips.positive?
        8.times do
          Thread.current[:config_reads] = 0
          sizes << CsvPreview.layout(path).rows_shown
          reads << Thread.current[:config_reads]
        end
      ensure
        stop = true
        flipper.join
      end
      puts({ flips: flips, sizes: sizes, reads: reads }.to_json)
    RUBY
    assert status.success?, err
    result = JSON.parse(out)

    assert_operator result["flips"], :>=, 2, "flipper did not run"
    assert_equal [1] * 8, result["reads"], "each call must read the global config exactly once"
    assert(result["sizes"].all? { |n| [3, 5].include?(n) }, result["sizes"].inspect)
  end

  def cold_script(body)
    <<~RUBY
      require "csv_preview"
      require "digest"
      require "json"
      names = #{NAMES.inspect}
      dir = #{Fixtures::CHECKED_IN.inspect}
      # Cold: no ruby-vips loaded, no warm-up, no render yet.
      abort "not cold: Vips loaded" if defined?(::Vips)
      abort "not cold: warm" if CsvPreview::Text.instance_variable_get(:@warm)
      #{body}
      puts digests.to_json
    RUBY
  end

  def child_digests(body)
    out, err, status = ChildRuby.run(cold_script(body))
    assert status.success?, "child failed:\n#{err}\n#{out}"
    assert_equal "", err
    JSON.parse(out)
  end

  # Review Focus 4: the first renders of a process race on the one-time font registration and warm-up.
  def test_cold_start_concurrent_renders_match_serial
    serial = child_digests(<<~RUBY)
      digests = names.to_h { |n| [n, Digest::SHA256.hexdigest(CsvPreview.render(File.join(dir, n)))] }
    RUBY

    concurrent = child_digests(<<~RUBY)
      gate = Queue.new
      ready = Queue.new
      threads = names.map do |n|
        Thread.new do
          ready << true
          gate.pop
          [n, Digest::SHA256.hexdigest(CsvPreview.render(File.join(dir, n)))]
        end
      end
      names.size.times { ready.pop }
      names.size.times { gate << true }
      digests = threads.map(&:value).to_h
    RUBY

    assert_equal NAMES.sort, serial.keys.sort
    assert_equal serial, concurrent
  end
end
