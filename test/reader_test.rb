# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require_relative "support/fixtures"

class ReaderTest < Minitest::Test
  TEXT = "name,symbol,quote,apostrophe\né,€,“smart quotes”,’\n"

  def read(source, deadline: CsvPreview::Deadline.new(30), **overrides)
    CsvPreview::Reader.call(source, config: CsvPreview.config.resolve(**overrides), deadline: deadline)
  end

  def read_fixture(name, **overrides) = read(Fixtures.path(name), **overrides)

  # An IO that exposes only read(length) and records every request.
  class CountingIO
    attr_reader :requested, :returned, :calls

    def initialize(io) = (@io = io; @requested = []; @returned = 0; @calls = [])

    def read(length = nil)
      @calls << :read
      @requested << length
      chunk = @io.read(length)
      @returned += chunk.bytesize if chunk
      chunk
    end

    def method_missing(name, *) = (@calls << name; raise NoMethodError, "unexpected #{name}")
    def respond_to_missing?(*) = false
  end

  def test_PS_2_utf8_bom
    r = read_fixture("utf8_bom.csv")
    assert_equal TEXT, r.text
    assert_equal "UTF-8", r.encoding
    assert r.complete
  end

  def test_PS_2_utf16le_bom
    r = read_fixture("utf16le_bom.csv")
    assert_equal TEXT, r.text
    assert_equal "UTF-16LE", r.encoding
  end

  def test_PS_2_utf16be_bom
    r = read_fixture("utf16be_bom.csv")
    assert_equal TEXT, r.text
    assert_equal "UTF-16BE", r.encoding
  end

  def test_PS_2_utf32le_bom
    r = read_fixture("utf32le_bom.csv")
    assert_equal TEXT, r.text
    assert_equal "UTF-32LE", r.encoding
  end

  def test_PS_2_utf32be_bom
    io = StringIO.new("\x00\x00\xFE\xFF".b + TEXT.encode("UTF-32BE").b)
    r = read(io)
    assert_equal TEXT, r.text
    assert_equal "UTF-32BE", r.encoding
  end

  def test_PS_2_windows1252
    r = read_fixture("windows1252.csv")
    assert_equal TEXT + "undefined,�\n", r.text
    assert_equal "Windows-1252", r.encoding
  end

  def test_PS_2_no_leading_bom_in_text
    %w[utf8_bom utf16le_bom utf16be_bom utf32le_bom].each do |name|
      refute read_fixture("#{name}.csv").text.start_with?("\uFEFF"), name
    end
  end

  def test_PS_3_utf16le_nobom
    r = read_fixture("utf16le_nobom.csv")
    assert_equal "UTF-16LE", r.encoding
    assert_equal TEXT, r.text
  end

  def test_PS_3_utf16be_nobom
    r = read(StringIO.new(TEXT.encode("UTF-16BE").b))
    assert_equal "UTF-16BE", r.encoding
    assert_equal TEXT, r.text
  end

  def test_PS_4_invalid_utf8
    r = read_fixture("invalid_utf8.csv")
    assert_equal "UTF-8", r.encoding
    assert r.text.valid_encoding?
    assert_includes r.text, "Café,Ünïcode"
    assert_includes r.text, "漢字,stray�\n"
    assert_includes r.text, "cut,a�b\n"
    assert_includes r.text, "over,c��d\n"
  end

  def test_PS_9_cut_mid_char_utf8
    r = read(Fixtures.generate("cut_mid_char_utf8.csv"), max_input_bytes: 8)
    assert_equal "ab,cd\nx", r.text
    refute r.text.include?("�")
    refute r.complete
    assert_equal 8, r.bytes_read
  end

  def test_PS_9_cut_mid_char_utf16
    path = Fixtures.generate("cut_mid_char_utf16.csv")
    odd = read(path, max_input_bytes: 11)
    assert_equal "a,b\n", odd.text
    high = read(path, max_input_bytes: 12)
    assert_equal "a,b\n", high.text
    [odd, high].each do |r|
      assert_equal "UTF-16LE", r.encoding
      refute r.complete
      refute r.text.include?("�")
    end
  end

  def test_PS_9_cut_mid_char_utf32
    io = StringIO.new("\xFF\xFE\x00\x00".b + "ab\u{1F600}".encode("UTF-32LE").b)
    r = read(io, max_input_bytes: 4 + 4 + 4 + 2)
    assert_equal "ab", r.text
    refute r.complete
  end

  def test_PS_9_cut_keeps_windows1252_bytes
    r = read(StringIO.new("a,\xE9\xE9\xE9".b), max_input_bytes: 4)
    assert_equal "Windows-1252", r.encoding
    assert_equal "a,\u00e9\u00e9", r.text
  end

  def test_PS_9_true_end_of_file_truncated_sequence_is_replaced
    r = read(StringIO.new("café über été \xE2\x82".b))
    assert_equal "UTF-8", r.encoding
    assert r.text.end_with?("�")
    assert r.complete
  end

  def test_PS_19_read_bound_through_counting_io
    io = CountingIO.new(File.open(Fixtures.generate("huge.csv"), "rb"))
    r = read(io, max_input_bytes: 100_000)
    assert_equal 100_000, io.returned
    assert_equal 100_000, r.bytes_read
    refute r.complete
    assert_equal [:read], io.calls.uniq
    assert io.requested.all? { |n| n.is_a?(Integer) && n <= 65_536 }
  ensure
    io&.instance_variable_get(:@io)&.close
  end

  def test_PS_19_path_source_reads_at_most_the_limit
    r = read(Fixtures.generate("huge.csv"), max_input_bytes: 200_000)
    assert_equal 200_000, r.bytes_read
    refute r.complete
  end

  def test_PS_19_path_source_complete_when_file_fits
    r = read_fixture("utf8_bom.csv")
    assert r.complete
    assert_equal File.size(Fixtures.path("utf8_bom.csv")), r.bytes_read
  end

  def test_PS_19_io_exactly_at_the_limit_is_incomplete
    r = read(StringIO.new("a,b\n"), max_input_bytes: 4)
    refute r.complete
    assert_equal "a,b\n", r.text
  end

  def test_empty_source
    r = read_fixture("empty.csv")
    assert_equal "", r.text
    assert r.complete
    assert_equal "UTF-8", r.encoding
    assert_equal 0, r.bytes_read
    assert_equal "", read(StringIO.new("")).text
  end

  def test_PS_22_binary_input
    %w[png gif jpeg zip xlsx xls pdf gzip].each do |kind|
      error = assert_raises(CsvPreview::UnreadableInput, kind) { read_fixture("#{kind}_renamed.csv") }
      refute_empty error.message
    end
  end

  def test_PS_22_nul_in_window
    assert_raises(CsvPreview::UnreadableInput) { read(Fixtures.generate("nul_in_window.csv")) }
  end

  def test_PS_22_controls_heavy
    assert_raises(CsvPreview::UnreadableInput) { read(Fixtures.generate("controls_heavy.bin")) }
  end

  def test_PS_22_dos_eof_marker_is_not_binary
    r = read(StringIO.new("a,b\x1A".b))
    assert_equal "a,b\x1A", r.text
  end

  def test_PS_22_nul_after_window_is_not_rejected
    r = read(Fixtures.generate("nul_after_window.csv"))
    assert_includes r.text, "x\u0000y"
  end

  def test_PS_22_more_magic_numbers
    {
      "bzip2" => "BZh91AY&SY", "xz" => "\xFD7zXZ\x00", "zstd" => "\x28\xB5\x2F\xFD", "7z" => "7z\xBC\xAF\x27\x1C",
      "rar" => "Rar!\x1A\x07", "riff" => "RIFF", "tiff_le" => "II*\x00", "tiff_be" => "MM\x00*",
      "mp4" => "\x00\x00\x00\x18ftypmp42", "elf" => "\x7FELF", "sqlite" => "SQLite format 3\x00",
      "zip_spanned" => "PK\x07\x08", "gif87" => "GIF87a"
    }.each do |kind, bytes|
      assert_raises(CsvPreview::UnreadableInput, kind) { read(StringIO.new(bytes.b + "abc")) }
    end
  end

  def test_PS_22_plausible_text_prefixes_are_not_rejected
    ["BMW,3\n", "MZ,1\n", "BZh,x\n", "RIF,1\n", "PK,1\n"].each do |csv|
      assert_equal csv, read(StringIO.new(csv)).text
    end
  end

  def test_PS_22_error_never_quotes_input
    error = assert_raises(CsvPreview::UnreadableInput) { read(StringIO.new("a\x00SECRET-7f3a".b)) }
    refute_includes error.message, "SECRET-7f3a"
  end

  def test_PS_23_stringio_position_and_left_open
    io = StringIO.new("0123456789a,b\n1,2\n")
    io.pos = 10
    r = read(io)
    assert_equal "a,b\n1,2\n", r.text
    refute io.closed?
    assert_equal io.size, io.pos
  end

  def test_PS_23_read_only_io_like
    io = CountingIO.new(StringIO.new("a,b\n1,2\n"))
    assert_equal "a,b\n1,2\n", read(io).text
    assert_equal [:read], io.calls.uniq
  end

  def test_PS_23_io_returning_too_much_is_cut
    greedy = Object.new
    def greedy.read(_length) = (@done ? nil : (@done = true; "a,b\n1,2\n3,4\n5,6\n"))
    r = read(greedy, max_input_bytes: 8)
    assert_equal 8, r.bytes_read
    assert_equal "a,b\n1,2\n", r.text
  end

  def test_PS_23_utf8_returning_io
    utf8_io = Object.new
    def utf8_io.read(_length)
      return nil if @done

      @done = true
      "café,üñ\n".dup.force_encoding("UTF-8")
    end
    r = read(utf8_io)
    assert_equal "café,üñ\n", r.text
  end

  def test_PS_23_chunks_that_mix_utf8_strings
    pieces = ["café,", "ü,ñ\n"]
    io = Object.new
    io.define_singleton_method(:read) { |_n| pieces.shift }
    assert_equal "café,ü,ñ\n", read(io).text
  end

  def test_PS_23_non_string_read_result_raises
    io = Object.new
    def io.read(_n) = 42
    assert_raises(ArgumentError) { read(io) }
  end

  def test_PS_23_directory_raises_argument_error
    assert_raises(ArgumentError) { read(File.expand_path("fixtures", __dir__)) }
  end

  # A FIFO with no writer must not block the open (which would outlast any timeout): the path is
  # opened non-blocking and refused as not a regular file. A regression is unblocked by opening a
  # writer, so it fails instead of hanging the suite.
  def test_PS_23_fifo_without_a_writer_raises_promptly
    Dir.mktmpdir do |dir|
      fifo = File.join(dir, "input.csv")
      begin
        File.mkfifo(fifo)
      rescue NotImplementedError
        skip "File.mkfifo is not available on this platform"
      end
      reader = Thread.new do
        read(fifo, timeout: 1)
      rescue ArgumentError => e
        e
      end
      unless reader.join(5)
        File.open(fifo, File::WRONLY | File::NONBLOCK).close
        reader.join
        flunk "reading a FIFO with no writer blocked for 5 s"
      end
      assert_instance_of ArgumentError, reader.value
      assert_equal "source path is not a regular file", reader.value.message
    end
  end

  def test_PS_23_missing_path_raises_enoent
    assert_raises(Errno::ENOENT) { read(File.join(__dir__, "fixtures", "nope.csv")) }
  end

  def test_PS_23_pathname_accepted
    path = Fixtures.path("utf8_bom.csv")
    r = read(Pathname(path))
    assert_equal TEXT, r.text
    assert r.complete
    assert_equal File.size(path), r.bytes_read
    assert_raises(ArgumentError) { read(Pathname(File.expand_path("fixtures", __dir__))) }
    assert_raises(Errno::ENOENT) { read(Pathname(File.join(__dir__, "fixtures", "nope.csv"))) }
  end

  def test_PS_22_binary_window_starts_at_raw_byte_zero
    bom = "\xEF\xBB\xBF".b
    inside = bom + ("a" * 8_188).b + "\x00".b + "b".b # NUL at raw byte 8,191
    outside = bom + ("a" * 8_189).b + "\x00".b + "b".b # NUL at raw byte 8,192
    assert_raises(CsvPreview::UnreadableInput) { read(StringIO.new(inside)) }
    assert_includes read(StringIO.new(outside)).text, "\u0000"
  end

  def test_PS_23_other_source_types_raise
    assert_raises(ArgumentError) { read(42) }
    assert_raises(ArgumentError) { read(nil) }
  end

  def test_PS_24_explicit_windows1252_on_utf8_file
    r = read(StringIO.new("café\n"), encoding: "Windows-1252")
    assert_equal "Windows-1252", r.encoding
    assert_equal "cafÃ©\n", r.text
  end

  def test_PS_24_explicit_encoding_canonical_name
    assert_equal "Windows-1252", read(StringIO.new("a\xE9"), encoding: "cp1252").encoding
  end

  def test_PS_24_explicit_encoding_removes_only_matching_bom
    assert_equal "a,b\n", read(StringIO.new("\xEF\xBB\xBFa,b\n".b), encoding: "UTF-8").text
    # A UTF-16 BOM is not a UTF-8 BOM, so it is kept (as mojibake) when the option names UTF-8.
    assert_equal "\uFFFD\uFFFDa,b\n", read(StringIO.new("\xFF\xFEa,b\n".b), encoding: "UTF-8").text
  end

  def test_PS_24_explicit_utf16_without_bom
    r = read(StringIO.new("a,b\n".encode("UTF-16LE").b), encoding: "UTF-16LE")
    assert_equal "a,b\n", r.text
    assert_equal "UTF-16LE", r.encoding
  end

  def test_PS_24_explicit_encoding_still_checks_magic_numbers
    assert_raises(CsvPreview::UnreadableInput) { read_fixture("png_renamed.csv", encoding: "Windows-1252") }
  end

  def test_PS_24_bad_encoding_names_raise_argument_error
    ["nope", "UTF-16", "UTF-32", "UTF-7", "BINARY", "ASCII-8BIT", "internal", "external", "locale", "filesystem"].each do |name|
      assert_raises(ArgumentError, name) { CsvPreview.config.resolve(encoding: name) }
    end
  end

  def test_timeout_checked_per_chunk
    ticks = 0
    clock = -> { (ticks += 1) > 3 ? 100.0 : 0.0 }
    deadline = CsvPreview::Deadline.new(1, clock: clock)
    error = assert_raises(CsvPreview::TimeoutExceeded) { read(StringIO.new("x" * 500_000), deadline: deadline) }
    assert_match(/read/, error.message)
  end

  def test_decoding_never_raises_on_random_bytes
    rng = Random.new(7)
    ["auto", "UTF-8", "UTF-16LE", "UTF-16BE", "UTF-32LE", "UTF-32BE", "Windows-1252", "Shift_JIS", "ISO-8859-1"].each do |enc|
      20.times do
        bytes = Array.new(rng.rand(1..300)) { rng.rand(1..255) }.map { |b| [0x00, 0x01].include?(b) ? 0x41 : b }.pack("C*")
        begin
          r = read(StringIO.new(bytes), encoding: enc == "auto" ? :auto : enc)
          assert r.text.valid_encoding?, enc
          assert_equal Encoding::UTF_8, r.text.encoding
        rescue CsvPreview::UnreadableInput
          nil
        end
      end
    end
  end
end
