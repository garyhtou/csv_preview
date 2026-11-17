# frozen_string_literal: true

# The hostile input shapes of parsing-and-safety.md section 7.3, each built as 2 MiB of bytes
# (SIZE) unless the shape is defined by its own length. Shared by the in-process bounds tests and the
# child process that measures memory growth.
module HostileShapes
  SIZE = 2_097_152

  REALISTIC_ROW = "2026-03-14,TXN-004821,\"$1,284.50\",Tidepool Coffee,Meals,Seattle,WA,US,5814,Posted," \
                  "\"Team lunch, downtown\",Yes,Avery Chen,Operating,1.0000,USD,0,0,0,M00412,T093,card,ok\n"

  module_function

  # @param unit [String] repeated until it is at least SIZE bytes, then cut to exactly SIZE bytes
  def fill(unit, prefix = "")
    body = unit.b * ((SIZE - prefix.bytesize) / unit.bytesize + 1)
    (prefix.b + body).byteslice(0, SIZE)
  end

  # Rows repeated past SIZE, so the Reader stops at its byte limit (never sees EOF) with the limit falling
  # +back+ bytes before a row end: a file that is cut, not one that happens to end mid-record.
  def longer_than_limit(row, back)
    rows_before = (SIZE + back) / row.bytesize + 1
    text = row.b * (rows_before + 2)
    text.byteslice(0, rows_before * row.bytesize)
  end

  # Whole rows, then a quoted field that is open when the Reader's limit falls and closes well after it.
  def cut_inside_quote
    prefix = REALISTIC_ROW.b * (SIZE / REALISTIC_ROW.bytesize)
    prefix = prefix.byteslice(0, prefix.bytesize - (prefix.bytesize % REALISTIC_ROW.bytesize))
    prefix + "x,\"a quoted field still open at the byte limit".b + ("y" * 4_096).b + "\"\n".b
  end

  # @return [Hash{String => String}] shape name to input bytes
  def build
    {
      "realistic" => fill(REALISTIC_ROW),
      "one_line_x_comma" => fill("x,"),
      "only_commas" => fill(","),
      "only_lf" => fill("\n"),
      "only_crlf" => fill("\r\n"),
      "only_spaces" => fill(" "),
      "space_comma" => fill(" ,"),
      "a_lf" => fill("a\n"),
      "a_crlf" => fill("a\r\n"),
      "header_then_a_lf" => fill("a\n", "\"h\",\"i\"\n"),
      "one_unquoted_cell" => fill("x"),
      "one_quoted_cell" => fill("x", "\""),
      "only_quote" => "\"".b,
      "quoted_pairs" => fill("\"\"", "\""),
      "quote_then_letters" => fill("abcdefghij", "\""),
      "quote_then_lines" => fill("some text in a line\n", "\""),
      "comma_quote" => fill(",\""),
      "empty_quoted_fields" => fill("\"\","),
      "quoted_a_comma" => fill("\"a\","),
      "quoted_rows" => fill("\"a\",\"b\"\n"),
      "blank_quoted_records" => fill("\"\n\"\n"),
      "multiline_quoted_fields" => fill("\"\n\","),
      "text_after_quotes" => fill("\"a\"b,"),
      "space_before_quotes" => fill(" \"a\","),
      "mid_field_quotes" => fill("a\"b,"),
      "stray_quote_then_rows" => fill("1,2,3\n", "a,\"x\n"),
      "multibyte" => fill("€é漢字\u{1F642},"),
      "realistic_cut_mid_record" => longer_than_limit(REALISTIC_ROW, 37),
      "realistic_crlf_cut" => longer_than_limit(REALISTIC_ROW.gsub("\n", "\r\n"), 21),
      "cut_inside_quoted_field" => cut_inside_quote
    }
  end
end
