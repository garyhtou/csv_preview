# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "prism"
require "support/child_ruby"
require "support/fixtures"

# PS-25 to PS-29: the gem's code starts no process, touches no network, loads no image from input bytes,
# uses no ImageMagick and writes no files. Guards run in child Ruby processes so nothing leaks into the
# other test files (parsing-and-safety.md 9.2).
class SafetyTest < Minitest::Test
  GUARDS = File.expand_path("support/guards.rb", __dir__)
  BINARY_FIXTURES = %w[png_renamed.csv zip_renamed.csv xlsx_renamed.csv xls_renamed.csv pdf_renamed.csv
                       gif_renamed.csv jpeg_renamed.csv gzip_renamed.csv].freeze
  FIXTURE_PATHS = Dir[File.join(Fixtures::CHECKED_IN, "*")].select { |p| File.file?(p) }.sort.freeze

  # Ruby that renders every checked-in fixture, one "name status" line each. Binary ones must raise
  # UnreadableInput; anything else is reported as the exception class.
  RENDER_ALL = <<~RUBY
    results = #{FIXTURE_PATHS.inspect}.map do |path|
      status = begin
        CsvPreview.render(path, **($render_options || {}))
        "ok"
      rescue CsvPreview::UnreadableInput
        "unreadable"
      rescue Exception => e
        "\#{e.class}: \#{e.message}"
      end
      [File.basename(path), status]
    end
  RUBY

  def run_child(script, env: {})
    out, err, status = ChildRuby.run(script, env: env)
    assert status.success?, "child failed:\n#{err}\n#{out}"
    assert_equal "", err
    out
  end

  # Hidden directories at the top of the checkout that git ignores, as absolute paths ending in "/".
  # They hold local editor and agent tool state (a language server's cache, for example) that other
  # processes may update while a test runs; the gem never writes there. Tracked files and every other
  # ignored path stay watched. Empty outside a git checkout.
  def ignored_hidden_dirs(root)
    out, status = Open3.capture2("git", "-C", root, "ls-files", "--others", "--ignored", "--exclude-standard",
                                 "--directory", "-z", err: File::NULL)
    return [] unless status.success?

    out.split("\0").select { |path| path.start_with?(".") && path.end_with?("/") && path.count("/") == 1 }
       .map { |path| File.join(root, path) }
  rescue SystemCallError
    []
  end

  def assert_every_fixture_handled(out)
    results = out.lines.map(&:chomp).grep(/\A\S+ \S/).to_h { |l| l.split(" ", 2) }
    assert_equal FIXTURE_PATHS.map { |p| File.basename(p) }.sort, results.keys.sort
    results.each do |name, status|
      if BINARY_FIXTURES.include?(name)
        assert_equal "unreadable", status, name
      else
        assert_includes %w[ok], status, name
      end
    end
  end

  def test_PS_25_no_subprocesses_and_no_libvips_loaders
    out = run_child(<<~RUBY)
      require "csv_preview"
      require #{GUARDS.inspect}
      CsvPreview.text_supported? # loads ruby-vips; the guards are installed before the first draw
      Guards.install_process_guards!
      Guards.install_loader_guards!
      #{RENDER_ALL}
      results.each { |name, status| puts "\#{name} \#{status}" }
      puts "violations \#{Guards.violations.size}"
    RUBY

    assert_includes out.lines, "violations 0\n"
    assert_every_fixture_handled(out.lines.reject { |l| l.start_with?("violations") }.join)
  end

  def test_PS_25_guards_really_trip
    out = run_child(<<~RUBY)
      require #{GUARDS.inspect}
      require "csv_preview"
      CsvPreview.text_supported?
      Guards.install_process_guards!
      Guards.install_loader_guards!
      calls = {
        "system" => -> { system("true") }, "Kernel.system" => -> { Kernel.system("true") },
        "backtick" => -> { `true` }, "%x" => -> { %x(true) }, "spawn" => -> { spawn("true") },
        "Process.spawn" => -> { Process.spawn("true") }, "IO.popen" => -> { IO.popen("true") },
        "Open3" => -> { Open3.capture2("true") }, "exec" => -> { exec("true") }, "fork" => -> { fork },
        "open" => -> { open("|true") }, "on object" => -> { Object.new.instance_eval { system("true") } },
        "new_from_buffer" => -> { Vips::Image.new_from_buffer("x", "") },
        "new_from_file" => -> { Vips::Image.new_from_file("x") },
        "new_from_source" => -> { Vips::Image.new_from_source(nil, "") },
        "pngload_buffer" => -> { Vips::Image.pngload_buffer("x") },
        "svgload_buffer" => -> { Vips::Image.svgload_buffer("x") },
        "pngload" => -> { Vips::Image.pngload("x.png") },
        "thumbnail_buffer" => -> { Vips::Image.thumbnail_buffer("x", 1) },
        "thumbnail" => -> { Vips::Image.thumbnail("x.png", 1) },
        "Operation.call" => -> { Vips::Operation.call("pngload_buffer", ["x"], {}) },
        "Operation.call load type" => -> { Vips::Operation.call("VipsForeignLoadPngBuffer", ["x"], {}) },
        "Operation.call thumbnail type" => -> { Vips::Operation.call("VipsThumbnailBuffer", ["x", 1], {}) }
      }
      calls.each do |name, call|
        begin
          call.call
          puts "\#{name} NOT-TRIPPED"
        rescue Guards::Violation
          puts "\#{name} tripped"
        end
      end
    RUBY

    assert_equal [], out.lines.grep(/NOT-TRIPPED/)
    assert_equal 23, out.lines.grep(/tripped/).size
  end

  def test_PS_26_no_network_in_process_guards
    out = run_child(<<~RUBY)
      require "csv_preview"
      require #{GUARDS.inspect}
      CsvPreview.text_supported?
      Guards.install_network_guards!
      Guards.install_process_guards!
      #{RENDER_ALL}
      begin
        TCPSocket.new("127.0.0.1", 9)
        puts "NOT-TRIPPED"
      rescue Guards::Violation
        puts "guard-live"
      end
      results.each { |name, status| puts "\#{name} \#{status}" }
      puts "violations \#{Guards.violations.size - 1}"
    RUBY

    assert_includes out.lines, "guard-live\n"
    assert_includes out.lines, "violations 0\n"
    assert_every_fixture_handled(out.lines.reject { |l| l =~ /\A(violations|guard-live)/ }.join)
  end

  FORBIDDEN_FEATURE = %r{(?:\A|/)(?:socket|net/http|open-uri|resolv|open3)\.(?:rb|so|bundle)\z}

  def test_PS_26_clean_child_loads_no_network_libraries
    baseline = JSON.parse(run_child(%(require "json"; puts $LOADED_FEATURES.to_json)))
    out = run_child(<<~RUBY)
      require "csv_preview"
      require "json"
      #{RENDER_ALL}
      puts results.to_h.values.uniq.to_json
      puts $LOADED_FEATURES.to_json
    RUBY
    statuses, features = out.lines.map { |l| JSON.parse(l) }

    assert_equal %w[ok unreadable].sort, statuses.sort
    added = features - baseline

    assert_empty added.grep(FORBIDDEN_FEATURE)
    assert_empty features.grep(FORBIDDEN_FEATURE) - baseline.grep(FORBIDDEN_FEATURE),
                 "csv_preview loaded a network library"
  end

  def test_PS_26_strace_no_exec_no_inet_sockets
    require_strace!

    Dir.mktmpdir do |dir|
      trace = File.join(dir, "trace.txt")
      script = File.join(dir, "child.rb")
      File.write(script, <<~RUBY)
        require "csv_preview"
        $render_options = { timeout: 120 }
        #{RENDER_ALL}
        results.each { |name, status| puts "\#{name} \#{status}" }
      RUBY
      out, err, status = Open3.capture3("strace", "-f", "-o", trace, "-e", "trace=execve,clone,clone3,fork,vfork,socket,connect",
                                        RbConfig.ruby, "-I", ChildRuby::LIB, script)
      assert status.success?, err
      assert_every_fixture_handled(out)
      lines = File.readlines(trace)

      assert_equal 1, lines.grep(/\bexecve\(/).size, lines.grep(/\bexecve\(/).join
      assert_empty lines.grep(/\b(fork|vfork)\(/), "a process was forked"
      assert_empty lines.grep(/\bclone3?\(/).grep_v(/CLONE_THREAD/), "a process was cloned"
      assert_empty lines.grep(/AF_INET6?\b/), "network socket opened"
    end
  end

  def test_PS_27_no_imagemagick
    Dir.mktmpdir do |empty_path|
      out = run_child(<<~RUBY, env: { "PATH" => empty_path })
        module RequireGuard
          def require(name)
            raise LoadError, "blocked \#{name}" if name.to_s =~ /mini_magick|rmagick|RMagick/i
            super
          end
        end
        Kernel.prepend(RequireGuard)
        Object.prepend(RequireGuard)
        require "csv_preview"
        #{RENDER_ALL}
        results.each { |name, status| puts "\#{name} \#{status}" }
        puts "minimagick \#{defined?(MiniMagick).inspect}"
        puts "rmagick \#{defined?(Magick).inspect}"
        puts "convert \#{ENV["PATH"].split(":").any? { |d| File.exist?(File.join(d, "convert")) }}"
      RUBY

      assert_includes out.lines, "minimagick nil\n"
      assert_includes out.lines, "rmagick nil\n"
      assert_includes out.lines, "convert false\n"
      assert_every_fixture_handled(out.lines.grep_v(/\A(minimagick|rmagick|convert) /).join)
    end
  end

  def test_PS_28_source_scan_finds_no_forbidden_api
    findings = Dir[File.join(File.expand_path("../lib", __dir__), "**", "*.rb")].flat_map do |file|
      SourceScan.call(File.read(file), File.basename(file))
    end

    assert_empty findings
  end

  def test_PS_28_source_scan_detects_every_forbidden_form
    forbidden = {
      "system" => 'system("ls")', "spawn" => 'spawn("ls")', "exec" => 'exec("ls")', "fork" => "fork { }",
      "backtick" => "`ls`", "%x" => "%x(ls)", "popen" => 'IO.popen("ls")', "Open3" => 'Open3.capture2("ls")',
      "Process.spawn" => 'Process.spawn("ls")', "open" => 'open("f")', "IO.read" => 'IO.read("f")',
      "IO.readlines" => 'IO.readlines("f")', "IO.foreach" => 'IO.foreach("f") { }', "IO.write" => 'IO.write("f", "")',
      "URI.open" => 'URI.open("u")', "socket" => 'require "socket"', "net/http" => 'require "net/http"',
      "open-uri" => 'require "open-uri"', "eval" => "eval(s)", "instance_eval" => "o.instance_eval(s)",
      "class_eval" => "o.class_eval(s)", "module_eval" => "o.module_eval(s)", "binding" => "binding",
      "Marshal.load" => "Marshal.load(s)", "YAML.load" => "YAML.load(s)", "send" => "o.send(name)",
      "public_send" => "o.public_send(name)", "CSV.open" => 'CSV.open("f")', "CSV.read" => 'CSV.read("f")',
      "CSV.readlines" => 'CSV.readlines("f")', "CSV.foreach" => 'CSV.foreach("f") { }',
      "CSV.table" => 'CSV.table("f")', "CSV.parse" => "CSV.parse(s)", "CSV.parse_line" => "CSV.parse_line(s)",
      "new_from_buffer" => "Vips::Image.new_from_buffer(s, '')", "new_from_file" => "Vips::Image.new_from_file(s)",
      "new_from_source" => "Vips::Image.new_from_source(s, '')", "loader" => "Vips::Image.pngload(s)",
      "mini_magick" => 'require "mini_magick"', "MiniMagick" => "MiniMagick::Image", "cache_set_max" => "Vips.cache_set_max(1)",
      "concurrency_set" => "Vips.concurrency_set(1)", "block_untrusted_set" => "Vips.block_untrusted_set(true)",
      "::IO.popen" => '::IO.popen("ls")', "::Kernel.system" => '::Kernel.system("ls")',
      "::Process.spawn" => '::Process.spawn("ls")', "::Open3" => '::Open3.capture2("ls")',
      "::CSV.parse" => "::CSV.parse(s)", "::Marshal.load" => "::Marshal.load(s)",
      "Marshal.restore" => "Marshal.restore(s)", "send :system" => 'send(:system, "ls")',
      "Kernel.send :spawn" => 'Kernel.send(:spawn, "ls")', "IO.send :popen" => 'IO.send(:popen, "ls")',
      "public_send :eval" => "public_send(:eval, s)", "send string" => 'o.send("instance_eval", s)',
      "TOPLEVEL_BINDING.eval" => "TOPLEVEL_BINDING.eval(s)", "method(:system)" => 'method(:system).call("ls")',
      "Vips.block_untrusted" => "Vips.block_untrusted(true)", "Vips.block" => 'Vips.block("VipsForeignLoad", true)',
      "set_debug" => "Vips.set_debug(true)", "Operation.call loader" => 'Vips::Operation.call("pngload_buffer", [s], {})',
      "Operation.call dynamic" => "Vips::Operation.call(name, [s], {})", "thumbnail" => "Vips::Image.thumbnail(s, 1)",
      "thumbnail_buffer" => "Vips::Image.thumbnail_buffer(s, 1)", "pngload_buffer" => "Vips::Image.pngload_buffer(s)",
      "socket.so" => 'require "socket.so"', "interpolated require" => 'require "so#{x}"',
      "variable require" => "require name", "autoload" => 'autoload :Open3, "open3"',
      "::TCPSocket" => '::TCPSocket.new("h", 80)', "::Socket" => "::Socket.tcp(h, 80)",
      "::UDPSocket" => "::UDPSocket.new", "::Net::HTTP" => "::Net::HTTP.get(u)",
      "::MiniMagick" => "::MiniMagick::Image.open(f)", "::Magick" => "::Magick::Image.read(f)",
      "::Open3 constant" => "x = ::Open3", "Net::HTTP" => "Net::HTTP.get(u)",
      "send dynamic" => "o.send(name)", "eval on receiver" => "o.eval(s)",
      "Operation.call load type" => 'Vips::Operation.call("VipsForeignLoadPngBuffer", [s], {})',
      "Operation.call thumbnail type" => 'Vips::Operation.call("VipsThumbnailBuffer", [s, 1], {})'
    }
    forbidden.each do |name, source|
      refute_empty SourceScan.call(source, "x.rb"), "scan missed #{name}: #{source}"
    end
  end

  def test_PS_28_source_scan_allows_the_permitted_forms
    allowed = [
      "CSV.new(feed)", "File.open(path, 'rb') { |f| f.read(10) }", "o.send(:known)", "Vips::Image.text(s)",
      "x.system_name", "string.open_tag", "Vips::Image.text(s, font: f)", 'require "csv"', 'require_relative "x"',
      'o.send(:validate!)', "Vips::Operation.call('text', [s], {})"
    ]
    allowed.each { |source| assert_empty SourceScan.call(source, "x.rb"), source }
  end

  def test_PS_29_no_stray_writes
    Dir.mktmpdir("csvprev") do |root|
      dirs = %w[tmp work home cache].to_h { |n| [n, File.join(root, n).tap { |d| FileUtils.mkdir_p(d) }] }
      gem_dir = File.expand_path("..", __dir__)
      local_tool_dirs = ignored_hidden_dirs(gem_dir)
      out = run_child(<<~RUBY, env: { "TMPDIR" => dirs["tmp"], "HOME" => dirs["home"], "XDG_CACHE_HOME" => dirs["cache"] })
        require "csv_preview"
        require "digest"
        Dir.chdir(#{dirs["work"].inspect})
        snapshot = lambda do |dir|
          Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).reject { |f| f.end_with?("/.", "/..") }
             .reject { |f| f.include?("/.git/") || f.include?("/tmp/fixtures") }
             .reject { |f| #{local_tool_dirs.inspect}.any? { |d| f.start_with?(d) } }
             .map { |f| [f, File.directory?(f) ? :dir : [File.size(f), File.mtime(f).to_f]] }.sort_by(&:first)
        end
        CsvPreview.render(#{Fixtures.path("simple.csv").inspect}) # warm-up: fontconfig may build its cache
        watched = { tmp: #{dirs["tmp"].inspect}, work: #{dirs["work"].inspect}, cache: #{dirs["cache"].inspect},
                    gem: #{gem_dir.inspect} }
        before = watched.transform_values(&snapshot)
        #{RENDER_ALL}
        after = watched.transform_values(&snapshot)
        results.each { |name, status| puts "\#{name} \#{status}" }
        watched.each_key { |k| puts "\#{k} \#{before[k] == after[k] ? "unchanged" : "CHANGED"}" }
        puts "tmp-empty \#{Dir.children(#{dirs["tmp"].inspect}).empty?}"
        puts "work-empty \#{Dir.children(#{dirs["work"].inspect}).empty?}"
      RUBY

      %w[tmp work cache gem].each { |k| assert_includes out.lines, "#{k} unchanged\n", out }
      assert_includes out.lines, "tmp-empty true\n"
      assert_includes out.lines, "work-empty true\n"
      assert_every_fixture_handled(out.lines.grep_v(/\A(tmp|work|cache|gem)(-empty)? /).join)
    end
  end

  def test_PS_29_strace_no_writes_after_warm_up
    require_strace!

    Dir.mktmpdir("csvprev") do |dir|
      %w[tmp home cache work].each { |n| FileUtils.mkdir_p(File.join(dir, n)) }
      trace = File.join(dir, "trace.txt")
      marker = "/nonexistent/csv_preview_after_warm_up"
      script = File.join(dir, "child.rb")
      File.write(script, <<~RUBY)
        require "csv_preview"
        $render_options = { timeout: 120 }
        Dir.chdir(#{File.join(dir, "work").inspect})
        CsvPreview.render(#{Fixtures.path("simple.csv").inspect}, **$render_options)
        File.open(#{marker.inspect}) rescue nil
        #{RENDER_ALL}
        results.each { |name, status| puts "\#{name} \#{status}" }
      RUBY
      env = { "TMPDIR" => File.join(dir, "tmp"), "HOME" => File.join(dir, "home"),
              "XDG_CACHE_HOME" => File.join(dir, "cache") }
      out, err, status = Open3.capture3(env, "strace", "-f", "-o", trace, "-e", "trace=openat",
                                        RbConfig.ruby, "-I", ChildRuby::LIB, script)
      assert status.success?, err
      assert_every_fixture_handled(out)
      lines = File.readlines(trace)
      index = lines.index { |l| l.include?(marker) }

      refute_nil index, "marker open not traced"
      writes = lines[(index + 1)..].grep(/O_WRONLY|O_RDWR|O_CREAT/)

      assert_empty writes, "files opened for writing after warm-up:\n#{writes.first(10).join}"
    end
  end

  # On Linux CI a missing strace is a failure, not a skip: the checks would silently not run.
  def require_strace!
    return if strace?

    flunk "strace is required on Linux CI" if RUBY_PLATFORM.include?("linux") && ENV["CI"]
    skip "strace checks run on Linux with strace installed"
  end

  def strace?
    RUBY_PLATFORM.include?("linux") && system("strace", "-V", out: File::NULL, err: File::NULL)
  end

  # Walks a Prism parse tree for every forbidden form of parsing-and-safety.md 9.1 (plus the libvips
  # global settings and loaders of 9.1 and 10). Returns "file:line name" strings. Receivers are
  # normalised (a leading :: is dropped) and send, public_send, __send__ and method are resolved when
  # their target is a literal, so a forbidden name cannot hide behind them; a non-literal target, a
  # non-literal require or any eval is flagged outright.
  module SourceScan
    KERNEL_CALLS = %w[system spawn exec fork open binding].freeze
    EVALS = %w[eval instance_eval class_eval module_eval instance_exec class_exec module_exec].freeze
    INDIRECT = %w[send public_send __send__ method public_method instance_method].freeze
    IO_CALLS = %w[popen read readlines foreach write binread binwrite].freeze
    OPEN3_CALLS = %w[capture2 capture2e capture3 popen2 popen2e popen3 pipeline pipeline_r pipeline_rw
                     pipeline_start pipeline_w].freeze
    CSV_CALLS = %w[open read readlines foreach table parse parse_line].freeze
    DESERIALIZE_CALLS = %w[load unsafe_load restore load_file unsafe_load_file safe_load].freeze
    FORBIDDEN_REQUIRES = %w[socket net/http open-uri open3 mini_magick rmagick RMagick].freeze
    FORBIDDEN_CONSTANTS = %w[Open3 MiniMagick Magick TCPSocket UDPSocket Socket Net TOPLEVEL_BINDING].freeze
    VIPS_SETTINGS = /\A(cache_set\w*|concurrency_set|vector_set|leak_set|block_untrusted(_set)?|set_debug)\z/
    LOADER_NAME = /load|thumbnail|new_from_(buffer|file|source)/i

    module_function

    def call(source, label)
      result = Prism.parse(source)
      raise "scan target does not parse: #{label}" unless result.success?

      findings = []
      walk(result.value) { |node| check(node, label, findings) }
      findings
    end

    def walk(node, &block)
      block.call(node)
      node.compact_child_nodes.each { |child| walk(child, &block) }
    end

    def check(node, label, findings)
      where = "#{label}:#{node.location.start_line}"
      case node
      when Prism::XStringNode, Prism::InterpolatedXStringNode
        findings << "#{where} backtick"
      when Prism::ConstantReadNode
        findings << "#{where} #{node.name}" if FORBIDDEN_CONSTANTS.include?(node.name.to_s)
      when Prism::ConstantPathNode
        findings << "#{where} #{constant_root(node)}" if FORBIDDEN_CONSTANTS.include?(constant_root(node))
      when Prism::CallNode
        check_call(node, where, findings)
      end
    end

    # The first segment of a constant path with a leading :: dropped (::Net::HTTP gives "Net").
    def constant_root(node)
      node.full_name.delete_prefix("::").split("::").first
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      nil
    end

    def check_call(node, where, findings)
      name = node.name.to_s
      receiver = receiver_name(node.receiver)
      args = node.arguments&.arguments || []
      bad = forbidden_call?(name, receiver, args)
      bad ||= INDIRECT.include?(name) && indirect_bad?(name, receiver, args)
      bad ||= %w[require load autoload require_relative].include?(name) && receiver.nil? && bad_require?(name, args)
      findings << "#{where} #{name}" if bad
    end

    def forbidden_call?(name, receiver, args)
      last = receiver.to_s.split("::").last
      return true if EVALS.include?(name) || name == "`"
      return true if KERNEL_CALLS.include?(name) && (receiver.nil? || %w[Kernel Process].include?(receiver))
      return true if receiver == "IO" && IO_CALLS.include?(name)
      return true if receiver == "Open3" && OPEN3_CALLS.include?(name)
      return true if %w[URI Process].include?(receiver) && %w[open spawn daemon].include?(name)
      return true if %w[Marshal YAML Psych].include?(receiver) && DESERIALIZE_CALLS.include?(name)
      return true if receiver == "CSV" && CSV_CALLS.include?(name)
      return true if name.match?(VIPS_SETTINGS) || (receiver == "Vips" && name == "block")
      return true if last == "Image" && name.match?(LOADER_NAME)
      return true if last == "Operation" && name == "call" && loader_or_dynamic?(args.first)

      receiver.to_s.start_with?("Vips") && name.match?(/(load|thumbnail)\w*\z/i)
    end

    # send(:system), Kernel.send(:spawn), method(:system), o.send("instance_eval"): resolve the literal
    # and apply the direct rules with the same receiver; a name that is not a literal is flagged.
    def indirect_bad?(name, receiver, args)
      target = args.first
      return true unless literal_name?(target)

      target_name = literal_value(target)
      return true if forbidden_call?(target_name, receiver, args.drop(1))

      (KERNEL_CALLS + EVALS + %w[popen capture2 capture3]).include?(target_name) ||
        target_name.match?(VIPS_SETTINGS) || target_name.match?(LOADER_NAME)
    end

    def loader_or_dynamic?(arg)
      !literal_name?(arg) || literal_value(arg).match?(/load|thumbnail/i)
    end

    def bad_require?(name, args)
      arg = name == "autoload" ? args[1] : args.first
      return true unless arg.is_a?(Prism::StringNode)

      feature = arg.unescaped.sub(/\.(rb|so|bundle)\z/, "")
      FORBIDDEN_REQUIRES.include?(feature)
    end

    def literal_name?(node)
      node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
    end

    def literal_value(node)
      node.unescaped
    end

    def receiver_name(node)
      case node
      when nil then nil
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.full_name.delete_prefix("::")
      else "<expr>"
      end
    rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
      "<expr>"
    end
  end
end
