# frozen_string_literal: true

require "fileutils"

# Test fixtures. Small ones are checked in under test/fixtures; large or byte-exact generated ones are
# built deterministically on first use and cached under tmp/fixtures (git-ignored).
module Fixtures
  ROOT = File.expand_path("..", __dir__)
  CHECKED_IN = File.join(ROOT, "fixtures")
  GENERATED = File.expand_path("../tmp/fixtures", ROOT)

  GENERATORS = {
    # A NUL inside the 8 KiB binary-detection window.
    "nul_in_window.csv" => -> { "a,b\n1,2\n".b + "\x00".b + "c,d\n".b },
    # A NUL after the window, inside what would be a kept cell: not binary.
    "nul_after_window.csv" => lambda {
      "a,b\n".b + ("1,2\n".b * 2_500) + "x\x00y,z\n".b
    },
    # 8 KiB with 10% C0 controls (no NUL, no TAB/LF/CR): binary.
    "controls_heavy.bin" => lambda {
      Array.new(8_192) { |i| (i % 10).zero? ? 0x01 : 0x61 }.pack("C*")
    },
    # With max_input_bytes 8 the limit falls after the first byte of the three-byte euro sign.
    "cut_mid_char_utf8.csv" => -> { "ab,cd\nx€y\n".b },
    # BOM, "a,b\n", then U+1F600 as a surrogate pair at byte offsets 10 to 13: a limit of 11 leaves an
    # odd trailing byte, a limit of 12 ends on a lone high surrogate.
    "cut_mid_char_utf16.csv" => -> { "\xFF\xFE".b + "a,b\n\u{1F600}x\n".encode("UTF-16LE").b },
    # 50 MB of realistic rows.
    "huge.csv" => :huge,
    # A 100,000-character ASCII cell and a 100,000-byte cell of two-byte characters.
    "long_cell.csv" => lambda {
      "id,text\n1,#{"abcdefghij" * 10_000}\n2,#{"é" * 50_000}\n".b
    },
    # A stray quote, then 349,525 rows of 1,2,3: the quote swallows enough delimiters to trip the
    # field guard (parsing-and-safety.md 4.6 rule 1).
    "stray_quote_wide.csv" => -> { "a,\"x\n".b + ("1,2,3\n".b * 349_525) },
    # One line of 999,999 "x," then "x": exactly 2,000,000 bytes and about a million fields (PS-20).
    "one_line_million_columns.csv" => -> { ("x," * 999_999).b + "x\n".b },
    # A 400-record export (header included) with quoted amounts and multi-line quoted memos that
    # contain commas and doubled quotes. Cut at every offset by PS-34.
  "cut_sweep.csv" => :cut_sweep,
  # 12 columns by 20 rows under a header, every header and cell 60 to 70 characters of words
  # (rendering.md 12, REN-7).
  "long_text.csv" => :long_text,
  # About 5 MB of short rows: only the first max_input_bytes are read, so the row total is unknown
  # (REN-9).
  "five_mb.csv" => -> { "id,name,amount\n".b + (1..200_000).map { |i| "#{i},Customer #{i},#{i % 997}.50\n" }.join.b },
  # 6 MiB of short rows, for the Active Storage bounded-read test (AS-13).
  "six_mb.csv" => lambda {
    rows = "id,name,amount\n".b
    rows << "#{rows.bytesize},Customer #{rows.bytesize},12.50\n".b while rows.bytesize < 6 * 1_048_576
    rows
  },
  # 2 MiB + 1 newlines, then data: the bytes read are all blank but the file continues (REN-11).
  "blank_then_data.csv" => -> { ("\n" * (2_097_152 + 1)).b + "name,amount\nAlice,1.00\n".b }
}.freeze

  module_function

  # @param name [String] a checked-in fixture
  # @return [String] its absolute path
  def path(name)
    full = File.join(CHECKED_IN, name)
    raise ArgumentError, "no checked-in fixture #{name}" unless File.file?(full)

    full
  end

  # @param name [String] a generated fixture
  # @return [String] the absolute path of the cached file
  def generate(name)
    generator = GENERATORS.fetch(name) { raise ArgumentError, "no generator for #{name}" }
    FileUtils.mkdir_p(GENERATED)
    full = File.join(GENERATED, name)
    return full if File.file?(full)

    tmp = "#{full}.#{Process.pid}.part"
    case generator
    when :huge then write_huge(tmp)
    when :cut_sweep then File.binwrite(tmp, cut_sweep.b)
    when :long_text then File.binwrite(tmp, long_text.b)
    else File.binwrite(tmp, generator.call)
    end
    File.rename(tmp, full)
    full
  end

  # The first line of a multi-line memo has no comma, and rows with one have no quoted amount, so a
  # stray-quote re-read of that first line (4.6 rule 3) never splits more fields than the file has.
  # Memos cycle with period five: in each group of five records the first three have single-line memos
  # and the last two multi-line ones.
  #
  # @return [String] the cut_sweep export, LF line endings, no blank lines
  def cut_sweep
    merchants = ["Tidepool Coffee", "Northwind Supply", "Zipcab", "Blue Heron Hotel", "Greenleaf Market"]
    memos = [
      "Team lunch",
      "",
      "\"Said \"\"thanks\"\", left early\"",
      "\"Client visit\ndowntown, second line\"",
      "\"Three lines\nof memo, with commas\n\"\"quoted\"\" end\""
    ]
    lines = ["id,date,description,amount,memo,status"]
    (1..399).each do |i|
      memo = memos[(i - 1) % 5]
      cents = ((i * 7_919) % 250_000) + 1
      cents %= 100_000 if memo.include?("\n")
      amount = format("%s$%d.%02d", i.even? ? "-" : "", cents / 100, cents % 100)
      amount = "\"#{amount.sub(/(\d)(\d{3})\./, '\1,\2.')}\"" if cents >= 100_000
      lines << [i, format("2026-03-%02d", (i % 28) + 1), merchants[i % 5], amount, memo,
                i % 7 == 3 ? "Pending" : "Posted"].join(",")
    end
    lines.join("\n") + "\n"
  end

  # Words of at most 9 letters are appended while a cell is shorter than 60 characters, so every cell
  # ends on a whole word and is 60 to 69 characters long. Words are drawn from a seeded Mersenne
  # Twister, which gives the same sequence on every Ruby, so the cells are distinct and stable.
  #
  # @return [String] the long_text export, 21 lines of 12 cells
  def long_text
    words = %w[ledger quarterly invoice harbor coffee northwind supply travel monthly receipt transfer
               pending vendor office lunch refund payout airport hotel software]
    random = Random.new(2026)
    cell = lambda do
      text = +""
      while text.length < 60
        text << " " unless text.empty?
        text << words[random.rand(words.size)]
      end
      text
    end
    Array.new(21) { Array.new(12) { cell.call }.join(",") }.join("\n") + "\n"
  end

  def write_huge(path)
    block = +"id,name,amount,date\n"
    1_000.times { |i| block << "#{i},Customer number #{i},#{i * 7 % 1000}.#{i % 100},2026-03-14\n" }
    File.open(path, "wb") { |f| (52_428_800 / block.bytesize + 1).times { f.write(block) } }
  end
end
