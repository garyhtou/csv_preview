# csv_preview: parsing and safety

- **Status:** accepted; implemented in 0.1
- **Started:** 2026-11-15
- **Part of:** the specification in [`README.md`](./README.md) (the overview). This document conforms to the pinned contract in sections 9 and 10 of the overview. Where this document thinks the contract should change, it says so in [section 14](#14-proposed-changes-to-the-overview) instead of silently diverging.
- **Covers:** `Reader`, `Parser`, `Sanitizer`, `CellKind`, `Sample` and `Deadline` (files `reader.rb`, `parser.rb`, `sanitizer.rb`, `cell_kind.rb`, `sample.rb`, `deadline.rb`), the safety properties of the whole gem, and the acceptance tests and fixtures that prove them.

Every claim marked **(measured)** was checked with a prototype on Ruby 3.4.12 (no YJIT unless stated) on an Apple M1 Pro, using csv 3.3.5 unless stated. Parser behaviour was also compared across csv 3.2.6 to 3.3.7 and on Ruby 4.0.2. The machine was heavily loaded at the time (load average between 15 and 90 on 10 cores), so the timings are upper bounds, not best cases. The experiments are summarised in [appendix B](#appendix-b-experiments).

---

## 1. Threat model and goals

The CSV bytes are controlled by whoever uploaded the file. Previews are generated automatically (background jobs, sometimes inline in a web request), so nobody reviews a file before the gem reads it. The gem must therefore guarantee, for **any** byte sequence:

1. **Bounded input:** at most `max_input_bytes` bytes are read from the source.
2. **Bounded work and memory:** total work is `O(max_input_bytes) + O(max_rows × max_columns × max_cell_chars)`, and peak memory growth stays well under 200 MB, regardless of the file's shape.
3. **Bounded time:** a call that runs past `timeout` raises `CsvPreview::TimeoutExceeded` promptly.
4. **No interpretation:** cell text is never evaluated (formulas), never parsed as markup, never allowed to reorder neighbouring text (bidi controls), and never handed to an image decoder.
5. **No side effects:** no subprocesses, no network, no `eval`, no file writes.
6. **No surprise exceptions:** malformed CSV, bad encodings and odd shapes never raise. The only input-driven exceptions are `CsvPreview::UnreadableInput` (binary, not text) and `CsvPreview::TimeoutExceeded`.

Non-goals for this layer: guessing what the data *means* beyond "number or text", recovering from every possible mangling, and supporting multi-byte legacy encodings automatically (see [open questions](#13-open-questions)).

## 2. Pipeline and internal interfaces

All of these are internal (not part of the public API) except `Sample`. Every step receives the per-call frozen `Configuration` snapshot and the per-call `Deadline`.

```ruby
result = CsvPreview::Reader.call(source, config:, deadline:)
# => Reader::Result(text:, encoding:, complete:, bytes_read:)
#    text      UTF-8 String, valid encoding, BOM removed, owned by the gem
#    encoding  String, e.g. "UTF-8", "UTF-16LE", "Windows-1252"
#    complete  true when the whole source was read within max_input_bytes
#    bytes_read Integer, never above max_input_bytes

sample = CsvPreview::Parser.call(result, config:, deadline:)
# => CsvPreview::Sample (public, frozen)

CsvPreview::Parser.normalize!(text)                          # line breaks, in place (4.2)
CsvPreview::Parser::Records.new(text, complete:, delimiter:, keep_rows:, keep_columns:,
                                raw_cap:, deadline:, kept_only: false).call
# => Records::Result(kept:, widths:, count:, max_width:, complete:, too_wide:, recovered:)
#    runs Ruby's csv library inside the gem's bounds (4.3 to 4.8, appendix A)

CsvPreview::Sanitizer.clean(text, max_cell_chars:, capped:)  # => frozen String
CsvPreview::CellKind.cell(string)                            # => :empty, :number or :text
CsvPreview::CellKind.column(strings)                         # => :number or :text
CsvPreview::Deadline.new(seconds)                            # #check!(stage), #remaining
```

`CsvPreview.render`, `.sample` and `.layout` each create one `Deadline` at entry, before the source is opened, and pass it down. `Layout` and `Painter` (see [`rendering.md`](./rendering.md)) receive the `Sample` and the same `Deadline`.

---

## 3. Reader

### 3.1 Opening the source

Per overview section 9.1:

- **`String` or `Pathname`:** always a path. Open it read-only, binary and non-blocking (`File.open(path, File::RDONLY | File::NONBLOCK, binmode: true)`) in block form so it is closed in all cases. Non-blocking makes no difference to a regular file, but it stops the open itself from waiting for a writer when the path is a FIFO, which no `timeout` could bound. After opening, require `file.stat.file?` (a regular file), otherwise raise `ArgumentError` (directories, FIFOs and devices are refused). `Errno::*` errors from opening propagate unchanged: a missing file is a caller mistake, not untrusted input. The path is chosen by the application, so the gem does not defend against path traversal.
  - Never use `Kernel#open`, `IO.read`, `IO.readlines`, `IO.foreach` or `URI.open`: on Ruby versions before 4.0 some of these spawn a subprocess when the path starts with `|`.
- **IO-like object** (responds to `read`): used as is. The gem calls **only** `read(length)`. It never calls `rewind`, `seek`, `pos=`, `eof?`, `size`, `close`, or `read` without a length. Reading starts at whatever position the caller left the IO in.
- Anything else raises `ArgumentError`.

### 3.2 Bounded sequential read

```ruby
CHUNK = 65_536

buffer = String.new(capacity: [max_input_bytes, CHUNK].min, encoding: Encoding::BINARY)
eof = false
while buffer.bytesize < max_input_bytes
  deadline.check!(:read)
  want  = [CHUNK, max_input_bytes - buffer.bytesize].min
  chunk = io.read(want)
  if chunk.nil? || chunk.empty?
    eof = true
    break
  end
  raise ArgumentError, "source#read returned #{chunk.class}" unless chunk.is_a?(String)
  chunk = chunk.byteslice(0, want) if chunk.bytesize > want  # never trust the IO
  buffer << chunk.b                                          # .b: binary copy, see below
end
complete = eof || (path_source && file.size <= max_input_bytes)
```

- **Chunk size 64 KiB.** Small enough that a deadline check happens at least every 64 KiB, large enough that a 2 MiB read is 32 calls. Chunked reading also copes with slow streams.
- **`chunk.b` is required.** `IO#read(length)` and `StringIO#read(length)` return BINARY strings (measured), but other IO-likes may return UTF-8, and appending a non-ASCII UTF-8 string to a BINARY buffer that already holds non-ASCII bytes raises `Encoding::CompatibilityError` (measured). `.b` also avoids mutating a buffer the caller's IO might reuse.
- **Completeness.** `complete` is true only when the read loop saw end of file before the budget ran out, or (for path sources, where the gem owns the `File`) when `File#size <= max_input_bytes`. An IO source whose remaining length is *exactly* `max_input_bytes` is reported as incomplete, because confirming end of file would require reading one more byte. This only affects whether `total_rows` is known.
- **Blocking reads cannot be interrupted.** If the caller passes a network stream whose `read` blocks, the gem cannot interrupt it (see [section 8](#8-deadline-and-timeouts)). Callers should pass a file or `Tempfile` (as the Active Storage previewer does) or apply their own read timeouts.

### 3.3 Binary detection

Binary detection runs on the raw buffer before decoding, in this order. Any hit raises `CsvPreview::UnreadableInput` with a message naming the reason (for example `"input looks like a PNG image, not CSV text"`), never quoting input bytes.

**Step 1: magic numbers at offset 0.**

| Format | Signature (bytes at offset 0 unless noted) |
|---|---|
| PNG | `89 50 4E 47 0D 0A 1A 0A` |
| JPEG | `FF D8 FF` |
| GIF | `GIF87a` or `GIF89a` |
| PDF | `%PDF-` |
| ZIP (XLSX, ODS, Numbers, DOCX, JAR) | `PK 03 04`, `PK 05 06` (empty archive), `PK 07 08` |
| OLE2 compound file (XLS, DOC, MSG) | `D0 CF 11 E0 A1 B1 1A E1` |
| gzip | `1F 8B` |
| bzip2 | `BZh` followed by a digit `1` to `9`, then `31 41 59 26 53 59` |
| xz | `FD 37 7A 58 5A 00` |
| zstd | `28 B5 2F FD` |
| 7z | `37 7A BC AF 27 1C` |
| RAR | `52 61 72 21 1A 07` |
| RIFF (WebP, WAV, AVI) | `RIFF` |
| TIFF | `49 49 2A 00` or `4D 4D 00 2A` |
| ISO media (MP4, MOV, HEIC, AVIF) | `ftyp` at offset 4 |
| ELF executable | `7F 45 4C 46` |
| SQLite database | `SQLite format 3` followed by `00` |

Two-byte signatures that are also plausible text (`BM` for BMP, `MZ` for Windows executables) are deliberately **not** listed: a CSV can start with "BMW" or "MZ". Those formats contain NUL bytes in their headers and are caught by step 3.

**Step 2: choose the encoding** (section 3.4). The remaining checks depend on whether that encoding is ASCII-compatible.

**Step 3: NUL bytes and control-character ratio.** Let the window be the first 8,192 bytes of the buffer (for ASCII-compatible encodings), or the first 4,096 characters of the decoded text (for UTF-16 and UTF-32, where NUL *bytes* are normal).

- Any NUL (byte `00`, or U+0000 after decoding) in the window: `UnreadableInput`.
- Let `suspicious` be the number of C0 control characters other than TAB, LF and CR, plus DEL, in the window: `window.count("\x01-\x08\x0B\x0C\x0E-\x1F\x7F")`. If `suspicious > [8, window_size / 20].max` (more than 5%, with a floor of 8 so a tiny file ending in a DOS `^Z` is not rejected): `UnreadableInput`.

Random binary data almost always fails the NUL test (8 KiB of uniformly random bytes contains about 32 NULs; the chance of none is about e^-32). Real CSV exports contain essentially no C0 controls.

NUL bytes **after** the window do not make the file unreadable; the Sanitizer removes them from kept cells (this matters: ruby-vips raises `ArgumentError: string contains null byte` if a NUL reaches `Vips::Image.text`, measured).

Text formats that are not CSV (HTML, XML, JSON, RTF) are **not** rejected: they render as one-column text, literally, which is harmless.

### 3.4 Encoding detection

When the `encoding` option is `:auto`:

1. **BOM**, checked in this order (UTF-32LE must come before UTF-16LE because they share `FF FE`):

   | Bytes | Encoding | Notes |
   |---|---|---|
   | `FF FE 00 00` | UTF-32LE | supported because it costs nothing with Ruby's transcoder |
   | `00 00 FE FF` | UTF-32BE | |
   | `EF BB BF` | UTF-8 | |
   | `FF FE` | UTF-16LE | Excel's "Unicode Text" export |
   | `FE FF` | UTF-16BE | |

   The BOM is removed before decoding.
2. **BOM-less UTF-16** (supported, because CSV structure is ASCII and leaves an unmistakable pattern). In the first 4,096 bytes (rounded down to an even count), count NUL bytes at even offsets (`e`) and odd offsets (`o`) as fractions of the number of 2-byte units. If `o >= 0.30` and `e <= 0.05`: UTF-16LE. If `e >= 0.30` and `o <= 0.05`: UTF-16BE. (Measured: an ASCII CSV in UTF-16LE gives `e = 0.00, o = 1.00`; a Japanese CSV with ASCII digits and delimiters gives `o = 0.60`; random bytes give about `0.01` on both.) A UTF-16 file made entirely of CJK text with no ASCII has no NULs, is not detected, and falls through to step 3 (mojibake rather than an error).
3. **BOM-less UTF-32 is not supported.** It would be caught by the NUL test and raise `UnreadableInput`.
4. **UTF-8 or Windows-1252.** Let `U` be the buffer (with an incomplete trailing UTF-8 sequence removed if the input was cut, see 3.5), labelled UTF-8.
   - If `U.valid_encoding?`: **UTF-8**.
   - Otherwise compute, in C, with no per-byte Ruby loop:
     ```ruby
     clean     = u.scrub("")
     invalid   = u.bytesize - clean.bytesize          # bytes in invalid sequences
     multibyte = clean.length - clean.count("\x00-\x7F") # valid non-ASCII characters
     ```
   - If `multibyte >= 1 && multibyte >= invalid`: **UTF-8** (the invalid bytes become U+FFFD).
   - Otherwise: **Windows-1252**.

   Rationale: genuine Windows-1252 text almost never forms valid multi-byte UTF-8 sequences (a high byte followed by ASCII is invalid UTF-8), while a UTF-8 file with a few corrupt bytes still has plenty of valid ones. A mostly-ASCII file with a single stray high byte is genuinely ambiguous; Windows-1252 is the better guess there, because that is how Excel writes "é" or a curly quote. The `invalid_utf8.csv` fixture is built accordingly (section 12).

When the `encoding` option names an encoding:

- Resolve it with `Encoding.find(name)`. Raise `ArgumentError` if the name is unknown, the encoding is a dummy (`UTF-16`, `UTF-32`, `UTF-7`), it is `ASCII-8BIT`/`BINARY`, or `Encoding::Converter.new(enc, "UTF-8")` raises. This check belongs in `Configuration` so it fails before any reading.
- Skip detection. Remove a BOM only if it matches the named encoding (a UTF-8 BOM when the option is `"UTF-8"`, and so on).
- Binary detection still runs (magic numbers always; the NUL and control-ratio checks on raw bytes if the encoding is ASCII-compatible, on decoded text otherwise).

`Reader::Result#encoding` (and so `Sample#encoding`) is the canonical Ruby name: `"UTF-8"`, `"UTF-16LE"`, `"UTF-16BE"`, `"UTF-32LE"`, `"UTF-32BE"`, `"Windows-1252"`, or `Encoding#name` of the named encoding (for example `"cp1252"` becomes `"Windows-1252"`). For 0-byte input it is `"UTF-8"` (or the named encoding).

### 3.5 When the byte limit cuts the input

When `complete` is false, the last bytes of the buffer are an arbitrary cut.

- **Mid-character:** the cut must not produce a spurious U+FFFD at the end.
  - UTF-8: look back over at most 3 continuation bytes (`10xxxxxx`) to the nearest lead byte. If that lead announces a longer sequence (`110xxxxx` = 2, `1110xxxx` = 3, `11110xxx` = 4) than the bytes present, drop from the lead byte to the end. (At true end of file, a truncated sequence is genuinely invalid and becomes U+FFFD.)
  - UTF-16: drop a trailing odd byte; then, if the last 2-byte unit is a high surrogate (`D800` to `DBFF`), drop it.
  - UTF-32: drop the trailing `bytesize % 4` bytes.
  - Windows-1252 and other single-byte encodings: nothing to do.
  - The UTF-8 trim is applied to the *candidate* `U` used for the UTF-8 decision in 3.4 step 4; if Windows-1252 wins, the untrimmed buffer is decoded.
- **Mid-record:** the final, partial record is parsed like any other record, ending at the end of the text. It is not dropped (see 4.2 for why). It is shown if it is among the kept rows: this matters for files whose first data row is enormous (for example one 50 MB line), which would otherwise show nothing. A cell cut by the limit usually exceeds the raw cap anyway and so ends in "…".
- **Mid-quote:** if the cut falls inside a quoted field, `csv` rejects that record ("Unclosed quoted field"). The Parser's cut-tail recovery (4.6 rule 2) closes the quote at the end of the text, so the record ends there, as an open quoted field did in the hand-written tokenizer this replaces.
- **Counting:** the partial record counts towards `rows_read` and `total_columns`. Both are documented as lower bounds when `total_rows` is `nil`, and the partial record is a real row that was partly read.
- **`total_rows` is `nil`** whenever `complete` is false, even if the cut happened to land on a record boundary. It is also `nil` when the field guard stopped the parse inside an over-wide record (4.5).

### 3.6 Decoding (never raises)

| Source encoding | Call |
|---|---|
| UTF-8 | `text = buffer.force_encoding(Encoding::UTF_8)`, then `text = text.scrub("�") unless text.valid_encoding?` |
| everything else | `text = buffer.encode(Encoding::UTF_8, source_encoding, invalid: :replace, undef: :replace, replace: "�")` |

Then remove one leading U+FEFF if present (a BOM can survive when the option named an encoding without one, or in UTF-16 after a BOM-less detection). Then `deadline.check!(:decode)`.

Facts behind this table (all measured):

- `scrub` replaces each maximal invalid subsequence with one U+FFFD (`"a\xE2\x82b"` becomes `"a�b"`), but an overlong or surrogate encoding becomes one U+FFFD per byte (`"\xED\xA0\x80"` becomes three). Either is fine for a preview.
- Plain `encode` from Windows-1252 **raises** `Encoding::UndefinedConversionError` on the five undefined bytes `81 8D 8F 90 9D`. With `undef: :replace` they become U+FFFD.
- With `invalid: :replace`, UTF-16 lone surrogates, a trailing odd byte, and UTF-32 values above U+10FFFF all become U+FFFD.
- A fuzz run of 20,000 random byte strings through each of UTF-8, UTF-16LE/BE, UTF-32LE/BE, Windows-1252, Shift_JIS and ISO-8859-1 with these calls produced no exception and always valid UTF-8.
- Cost for 2 MiB: Windows-1252 to UTF-8 about 20 ms, UTF-16LE to UTF-8 about 10 ms, `valid_encoding?` on UTF-8 about 6 ms. Worst-case growth is 3x (2 MiB of byte `80`, each becoming the 3-byte "€").

The decoded `text` belongs to the gem. The Parser rewrites its line breaks in place (4.2) and otherwise only takes `byteslice`s of it, which share its memory; the one full-length copy it may make is the tail handed to the cut-tail recovery (4.6).

---

## 4. Parser

### 4.1 Decision: Ruby's `csv` library, wrapped and bounded

The Parser parses with Ruby's standard `csv` library (the `csv` gem: a default gem in Ruby 3.3 and a bundled gem from Ruby 3.4, so it is a declared runtime dependency; versions in 4.13). The reason is trust and maintainability: a widely used, long-maintained parser instead of custom parsing code. The gem keeps only what `csv` does not do: preparing the text, delimiter sniffing, header detection, the resource bounds, and recovery from the inputs `csv` rejects.

Used naively (`CSV.parse(text)`), `csv` breaks several goals of section 1. Each problem below was measured (csv 3.3.5) and has a specific answer:

| `csv` behaviour | Effect on hostile or truncated input | How the Parser handles it |
|---|---|---|
| Even with `liberal_parsing`, a quote that never closes raises `MalformedCSVError: Unclosed quoted field`, and the `CSV` object cannot continue | Every cut at `max_input_bytes` inside a quoted field, and every stray opening quote, would abort the parse | Recovery (4.6): at most one stray-quote re-parse plus one terminal pass, so a render never aborts |
| `row_sep: :auto` locks onto the first line ending; a different one later raises `Unquoted fields do not allow new line` | Files mixing CRLF and LF fail | Line breaks normalised to LF before parsing (4.2), and `row_sep: "\n"` |
| `max_field_size` raises instead of truncating | Unusable as a cell cap | Not used; kept cells are capped after parsing (4.8) |
| Fields are matched with greedy regexes (`[^",\n]+`, `[^"]+`, `"+`), and Onigmo pushes a backtrack entry per character matched: about 48 bytes of memory per input byte, the same on Ruby 3.4 and 4.0 | One 2 MiB field, or a stray quote followed by 2 MiB of rows, grows memory by 94 to 100 MB; with a recovery pass, by 202 MB | `csv` reads from an IO-like `Feed` in chunks of at most 8 KiB (4.3), which confines every match to one chunk: at most about 20 MB growth for any shape measured |
| Every field of a record is materialised | One line of 1,000,000 fields: +91 MB and 0.8 s; one line of 2,097,152 empty fields: +67 MB and 1.4 s | The field guard (4.5) ends `csv`'s input inside any record with more than about 57,000 delimiters: +4 to 6 MB and under 0.1 s |
| One `CSV#shift` can parse a whole 2 MiB record with no chance to check the deadline | A timeout could overrun by about a second | The `Feed` checks the deadline before every chunk it hands to `csv` (4.3) |
| `skip_blanks` skips empty lines one at a time in Ruby | 2 MiB of newlines: 1.6 s | Runs of LF are collapsed before parsing (4.2): 0.003 s |
| The only way to skip whitespace before an opening quote is `strip`, which also deletes the space in `"Big" Bob's Diner` and makes `csv` drop whitespace-only lines without reporting them | Changed cell text; record offsets the recovery cannot track | `strip` is not used; whitespace before a quote leaves the quote literal, as RFC 4180 and Excel do (4.7 rule 4) |

### 4.2 Preparing the text

**Excel's `sep=` directive.** When `delimiter: :auto` and the text (after any BOM) starts with a line matching `/\Asep=(.)\r?\n/` whose character is an allowed delimiter, that character is the delimiter, sniffing is skipped, and the line is removed before anything else: it is never shown, counted or used for header detection. Excel writes and honours this line. With an explicit `delimiter:`, or a character that is not an allowed delimiter, the line is ordinary data.

Before sniffing and parsing, `Parser.normalize!` rewrites the Reader's text in place (the text belongs to the gem, 3.6):

```ruby
text.tr!("\r", "\n")   # CRLF becomes LF LF; a lone CR (old Mac files) becomes LF
text.squeeze!("\n")    # every run of LF becomes one LF
```

Both are single C passes without a copy (2 MiB of CRLF pairs: 0.003 s, measured).

Why this changes nothing that is shown or counted:

- Outside quotes, a run of line breaks is a record end followed by empty lines, and empty lines are blank records, which are skipped anyway (4.7 rule 7). CRLF, LF and a lone CR all ended a record in the previous design too.
- Inside a quoted field, a run of line breaks becomes one LF, and the Sanitizer turns every run of line breaks into one space (5.1). So `"a\r\nb"`, `"a\n\n\nb"` and `"a\rb"` all display as `a b`.
- `rows_read` and `total_columns` ignore blank records, so collapsing empty lines cannot change them.

Deliberately not done:

- **No dropping of the trailing partial record when the input was cut.** Cutting the text after its last LF would not prevent a cut inside a multi-line quoted field (the last LF can lie inside that field), and it would leave nothing when the first record is longer than `max_input_bytes`. The partial record is parsed like any other (3.5); a cut inside a quoted field is handled by the cut-tail recovery (4.6 rule 2).
- **NUL and other control characters stay.** `csv` treats them as ordinary characters (measured); the Sanitizer removes them from kept cells (5.1).
- **Nothing else is rewritten.** Quotes, delimiters and whitespace reach `csv` unchanged.

### 4.3 How `csv` reads: the `Feed`

`CSV.new` is never given the text as a `String`. It is given a `Feed`, a small IO-like object over the text (appendix A). The reason is memory: `csv` reads a `String` or a `StringIO` whole and runs its field regexes over one long string (4.1), but it reads any other IO by calling `gets(row_sep, 8192)` and scans chunk by chunk, joining fields across chunk boundaries. That is `csv`'s ordinary path for files (`CSV.foreach` and `CSV.open` use it). Every regex match is then confined to one chunk, so Onigmo's backtrack stack stays under about 400 KB.

The `Feed`:

- wraps a `StringIO` over the text, starting at a given byte offset;
- implements exactly the methods `csv` calls on its input (recorded with a proxy object on csv 3.2.8 and 3.3.5): `gets(separator, limit)`, `eof?` and `eof`, `external_encoding` (UTF-8) and `internal_encoding` (`nil`);
- answers `gets` with up to `limit` bytes, **ignoring the separator** (`StringIO#gets(nil, limit)`, which never splits a character, measured). `csv`'s chunked scanner treats chunks as a byte stream, so chunks that hold several lines are parsed the same way (PS-31 runs every fuzz input with chunks of 1 to 9 bytes and requires identical results). They make inputs of tiny records faster than one line per call: 1,048,576 one-character rows took 2.35 s instead of 3.70 s (measured under load, so read the ratio, not the times);
- calls `deadline.check!(:parse)` before every chunk, so even a single 2 MiB record can be interrupted every 8 KiB;
- counts delimiters for the field guard (4.5) and, when the guard trips, reports end of input from then on.

The `Feed` must not be a `StringIO` subclass: `csv` checks `is_a?(StringIO)` and would read it whole. An exception raised inside `gets` (the deadline's `TimeoutExceeded`) propagates out of `CSV#shift` unchanged (measured on csv 3.2.6, 3.2.8, 3.3.5 and 3.3.7).

Measured effect of reading through the `Feed` rather than a `String` (2 MiB inputs, growth in maximum RSS): one unquoted field, 99 to 14 MB; one quoted field, 98 to 15 MB; only `"` characters, 100 to 14 MB; `a,"x` followed by rows of `1,2,3`, 94 to 1 MB; an unclosed quote followed by letters, including the recovery pass, 202 to 20 MB. The parsed results are identical.

### 4.4 Options passed to `csv`

```ruby
{ col_sep: delimiter, row_sep: "\n", quote_char: quoting ? '"' : nil,
  liberal_parsing: true, skip_blanks: true }
```

| Option | Value | Why |
|---|---|---|
| `col_sep` | the sniffed or explicit delimiter | a single ASCII character other than `"`, CR, LF and NUL (overview 9.2) |
| `row_sep` | `"\n"` | the text is normalised (4.2); an explicit value also stops `csv` from reading ahead to detect one |
| `quote_char` | `'"'`, or `nil` in quote-free passes | `nil` selects `csv`'s split-based path, about 2 to 3 times faster (measured). Used where the rest of the text has no quote (4.5) and where a quote must be read literally (4.6) |
| `liberal_parsing` | `true` (not the Hash form) | keeps `"Big" Bob's Diner`, `5" monitor` and `a""b` as written instead of raising. The Hash sub-options `double_quote_outside_quote` and `backslash_quote` would rewrite cell text |
| `skip_blanks` | `true` | empty lines are skipped inside `csv`; other blank records are skipped by the gem (4.7 rule 7) |

Everything else stays at its default: no `headers` (header detection is the gem's, 4.10), no `converters` (cells are data, 5.4), and no `nil_value` or `empty_value`. Unquoted empty fields come back as `nil`, which the gem treats as `""`; setting a value would send every field through `csv`'s converter code.

Never used: `max_field_size` or `field_size_limit` (they raise, 4.1), `strip` (4.1 and 4.7 rule 4), `skip_lines` (a regex over every line), `row_sep: :auto` (4.1), and `CSV.parse`, `CSV.read`, `CSV.foreach` or `CSV.table` (they take a whole string or a path, or build every row at once).

### 4.5 Pulling rows

Each pass creates one `CSV` over a `Feed` and pulls records with `shift`, never more than one at a time:

```ruby
csv = CSV.new(feed, **options)
pos = start
while (row = csv.shift)
  pos = skip_blank_lines(pos) + csv.line.bytesize   # byte offset just past this record
  add(row)
end
```

For each record, `add` (appendix A):

1. Computes the width: 1 plus the index of the last non-blank field, or 0 (4.7 rule 6). `row.rindex { |f| f && f.count(" \t\n") != f.bytesize }`.
2. Skips the record if its width is 0: not kept, not counted.
3. Keeps the first `max_columns` fields of the first `max_rows + 1` non-blank records as capped cells (4.8), with their widths capped at `max_columns`.
4. Counts the record and tracks the widest width seen.
5. Every 1,024 records, calls `deadline.check!(:parse)` (the `Feed` also checks before every chunk).

Records after the kept ones are still pulled, so that `rows_read` and `total_columns` cover every byte read, but their arrays are dropped at once. `csv` builds each of them, which is why many tiny records are the slowest input (7.3).

**Offsets.** Recovery needs the byte offset of the record `csv` rejects (4.6). `csv.line` (public API: the raw text of the last row read, including its line break) gives each record's length, and `skip_blank_lines` steps over the empty lines that `skip_blanks` swallowed without reporting (after 4.2 each is a single LF, found with one `getbyte`, or one `byteindex(/[^\n]/)` search when there are several). PS-31 asserts on every fuzz input that `text.byteslice(pos, line.bytesize) == line` for every record.

**Quote-free switch.** At the start the Parser finds the last `"` in the text with `byterindex`. As soon as a record ends after it, the rest of the text has no quote character, so the Parser abandons that `CSV` object and parses the rest in a fresh pass with `quote_char: nil`. The rows are identical (PS-31 compares both ways), `csv` is 2 to 3 times faster, and nothing in the rest can be rejected, so no offsets are needed. Text with no quote at all switches after its first record.

**Field guard.** The `Feed` adds `chunk.count(delimiter)` to a counter that `add` resets after every record. When the counter passes `MAX_RECORD_FIELDS = 65_536`, the `Feed` reports end of input. `csv` then returns what it has of that record (or rejects it, if a quote is open, 4.6 rule 1), the parse ends there, `complete` becomes false and `too_wide` becomes true. The counter also counts delimiters inside quoted fields and can carry up to one 8 KiB chunk of the next record before the reset, so the guard trips only for records with more than about 57,000 delimiters (65,536 minus one chunk), and no record ever reaches about 82,000 fields (65,536 plus two chunks). That is far above any spreadsheet's column limit (16,384 in Excel and LibreOffice), and it caps one record's row array at about 6 MB. Measured on one line of 1,000,000 fields: +91 MB and 0.79 s without the guard, +6 MB and 0.06 s with it. For such a file `total_columns` reports the width read before the stop (69,632 for that line) and `total_rows` is `nil`, because the rest was not parsed.

### 4.6 Recovery from `CSV::MalformedCSVError` (normative)

After 4.2, with the options of 4.4, `csv` rejects a record for one reason: it contains a quote that is still open where `csv`'s input ended (the end of the text, or the field guard's stop). Across 100,000 random inputs (20,000 on each of five `csv` versions), `Unclosed quoted field` was the only error raised (measured). `csv` has other `MalformedCSVError` messages (a stray CR, an illegal line ending after a quoted field), but normalised text and liberal parsing do not reach them; the rules below treat every `MalformedCSVError` the same way.

Let `x` be the byte offset of the rejected record: the offset just past the last record `csv` returned, moved past any skipped empty lines. Apply the first rule that matches:

1. **Runaway quote caught by the guard.** If the field guard stopped `csv`'s input during this pass and rule 3 has not been used yet, undo the stop (restore the end of the text, `complete` and `too_wide`), then apply rule 3. A quoted field that swallows more than 57,000 delimiters is almost always a stray quote followed by ordinary rows. Measured: `a,"x` followed by 349,525 rows of `1,2,3` counts all 349,526 records, with `total_rows` exact.
2. **Cut tail.** If the input was cut (the Reader stopped at `max_input_bytes`, or the guard stopped `csv` and rule 1 did not apply), and record `x` is past the kept records or starts on the last line read: parse `text[x...end] + '"'` with quoting on, which gives one final record whose open field ends at the cut. The parse ends. This is the record the cut fell into. Closing it keeps every count a lower bound; reading it without quotes instead would split quoted cells such as `"-$1,284.50"` and could report more columns than the file has.
3. **Stray quote (at most once).** If rule 3 has not been used: parse the first line of record `x` with `quote_char: nil` (the quote is a literal character and that line's fields split at every delimiter), then continue normally from the next line, with quoting on, offsets tracked and the guard counter reset. This recovers the common case of a description that starts with a quote and never closes it, without losing the rows that follow.
4. **Quote-free rest.** Otherwise (a second rejection): parse `text[x...end]` with `quote_char: nil`. The parse ends.

**Bounds.** Each rule applies at most once per parse, every pass moves forward through the text, and rules 2 and 4 end the parse. So a parse makes at most three passes over the text (the first, the one after rule 3, and one final pass) plus one line, all inside the field guard. Rules 2, 3 and 4 hand `csv` text it has no reason to reject (no quote character at all, or the open quote closed); if it ever did, the parse ends there with `complete` false. The Parser itself never raises `MalformedCSVError`: in more than 1,000,000 fuzz inputs run against the prototype, no recovery pass was ever rejected (measured).

**Why re-reading one line is enough (rule 3).** When `csv` rejects record `x` for an open quote, every run of quote characters after the opening quote has even length, because an odd run would have closed the field. Parsing again with quoting on from the next line, any field that starts with such a run closes inside that run, so the lines a runaway quote swallowed cannot be rejected again. A second rejection needs a second unbalanced quote, and then rule 2 or 4 ends the parse.

Verified behaviour (measured; identical on csv 3.2.6 to 3.3.7):

- The `unbalanced_quote.csv` shape, `Date,Desc,Amount` then `2026-03-01,"Coffee,4.50` then two normal rows: four records; the second is `2026-03-01`, `"Coffee`, `4.50` (rule 3); the last two are intact.
- A byte-limit sweep: an export of 400 records with quoted amounts and multi-line quoted memos (containing commas and `""`), cut at each of its 41,641 byte offsets with the defaults. No cut raised; `total_columns` never exceeded the true width; every complete record among the kept ones equalled a strict `CSV.parse` of the whole file; `rows_read` was never below the number of complete records before the cut. In 396 cuts `rows_read` exceeded that number by more than one: all were cuts inside a multi-line memo among the first 21 records, where rule 3 shows the memo's remaining lines as rows. With `max_rows: 2` (so that almost every cut falls past the kept records) there were none.
- A 2 MiB export with CRLF line endings, cut inside a quoted field on its last line: rule 2; the last record is closed at the cut; 23 columns, as in the file.
- One long line of quoted fields cut inside a quote (`"a,b","a,b",...,"cut,here`): rule 2 (the record starts on the last line); 11 correct cells.

Known and accepted:

- If the input is cut inside a multi-line quoted field among the kept records (only possible when those records span `max_input_bytes`), rule 3 shows the field's later lines as extra rows.
- If a file has a stray quote and another quote later, `csv` pairs them (liberal parsing) and everything between becomes one cell. Nothing is rejected, so no recovery runs. The hand-written tokenizer this replaces behaved the same way.

### 4.7 Lenient results (normative)

These follow from the options in 4.4. They are written down so that tests can assert them and a change in `csv` is noticed. `D` is the delimiter.

1. **Unquoted field:** runs to the next `D` or line end. A `"` inside it is a literal character: `5" monitor` stays `5" monitor`, and `a""b` stays `a""b`.
2. **Quoted field:** starts with `"` as the very first character of the field. Each `""` inside stands for one `"`; `D` and LF inside are literal.
3. **Text after the closing quote:** the field is the raw text from the opening quote to the next `D` or line end, quotes kept and nothing unescaped. The quoted part still protects delimiters, so `"a,b" c,d` is two fields, `"a,b" c` and `d`, and `"Big" Bob's Diner` is one. Whitespace counts as such text: `"a" ,b` gives `"a" ` (shown as `"a"` once the Sanitizer trims it) and `b`.
4. **Whitespace before an opening quote:** the field is unquoted, so the quote is literal: `1, "Smith, John"` is three fields, `1`, ` "Smith` and ` John"`, shown as `1`, `"Smith` and `John"`. This is RFC 4180's rule and what Excel shows. (The hand-written tokenizer skipped the whitespace; `csv` can only do that with `strip`, which costs what 4.1 lists.)
5. **Unterminated quote:** `csv` rejects the record; see 4.6.
6. **Blank fields and record width.** A field is *blank* if it is `nil` (unquoted and empty) or consists only of spaces, tabs and LF (`""`, `"  "`, a quoted line break). Fields from rule 3 always contain a `"`, so they are never blank. The **width** of a record is 1 plus the index of its last non-blank field, or 0 if every field is blank. Trailing delimiters therefore do not widen a record (`a,b,c,,,` has width 3), which keeps Excel's trailing-comma exports from showing empty columns.
7. **Blank records** (width 0) are skipped completely: not shown, not counted. This covers empty lines (which `csv` skips itself), whitespace-only lines, and delimiter-only lines such as `,,,,`.

Ragged rows are allowed: each kept row is later padded with `""` or cut to `column_count` (section 4.11).

### 4.8 Keeping cells: `max_columns` and the raw cap

- The Parser keeps the first `max_columns` fields of the first `max_rows + 1` non-blank records (one extra in case the first record is a header). `csv` has already built every field of the record; the rest are dropped with the row.
- Each kept field is cut to at most `RAW_CAP` bytes, where
  ```ruby
  RAW_CAP = 8 * (max_cell_chars + 1) + 64   # 552 bytes for the default 60
  ```
  This allows 4 bytes per code point, a factor of two for characters the Sanitizer removes or for combining marks, and headroom for whitespace. `csv` returns quoted fields already unescaped, so the same cap applies to every field. The cut is followed by `scrub("")`, which drops a character split by the byte cap. A `nil` field becomes `""`.
- A kept cell records `capped = true` when its text was longer than the cap. The Sanitizer then always ends it with "…" (section 5.3).
- `max_cell_chars` is enforced by the Sanitizer on the cleaned text, in grapheme clusters.

### 4.9 Delimiter sniffing (`delimiter: :auto`)

Candidates, in tie-breaking order: `,` `;` `\t` `|`.

`csv` does not sniff, so this stays the gem's job; it runs on the normalised text (4.2) and parses with `csv` like everything else.

1. **Sample:** the first 65,536 bytes of the text (`byteslice` then `scrub("")`). If the text is longer than the sample, cut the sample after its last LF (if it has one), so its last record is less likely to be cut.
2. **Parse the sample once per candidate** with `Records` (appendix A) and `keep_rows: 30`, `keep_columns: 64`, `kept_only: true` (stop after 30 non-blank records), `complete:` true only when the sample is the whole text. Quotes are respected, so delimiters inside quoted fields do not count, and the recovery rules of 4.6 apply, so a stray quote in the sample cannot abort sniffing. Bounded: at most 4 × 64 KiB of `csv` input, and usually far less because each pass stops after 30 records.
3. **Per candidate**, over those records:
   - `widths` = the record widths (4.7 rule 6); `mode` = the most common width (ties go to the larger width); `consistency` = the fraction of records whose width equals `mode`.
   - `clean` = the fraction of non-empty kept cells (stripped of spaces) that either contain none of the *other three* candidate characters, or are numbers by `CellKind.cell` (so `1,5` is a clean cell for `;` in a decimal-comma file).
4. **Choose:**
   1. Discard candidates whose `mode < 2` (the delimiter does not split the file).
   2. If none remain, use `,` (single-column file).
   3. Keep the candidates whose `consistency >= best_consistency - 0.10`.
   4. Among those, pick the highest `clean`, then the highest `mode`, then the earliest in candidate order.

Verified cases (measured with the `csv`-based prototype): a 23-column comma export with quoted amounts like `"-$1,284.50"` gives `,`; `Datum;Betrag` with `-1.284,50` gives `;`; the classic ambiguity `1,5;2,5\n3,5;4,5` gives `;` (the `clean` step decides it); `Name;Amount\nFoo, Inc;1,50` gives `;`; a TSV with commas inside text gives `\t`; pipes give `|`; a single column gives `,`; a comma file with semicolons in text gives `,`; `"a;b",c` gives `,`; a comma file with a stray quote in its second row gives `,`.

An explicit `delimiter` skips sniffing. It must be a single ASCII character other than `"`, CR, LF or NUL, otherwise `ArgumentError` (see [proposed change 2](#14-proposed-changes-to-the-overview)).

### 4.10 Header detection (`header_row: :auto`)

Run after the kept records are sanitized. Let `R0` be the first non-blank record and `R1..Rk` the following kept records (`k <= max_rows`), all over the columns `0...column_count`.

Classify each cleaned cell:

```ruby
DATE = /\A(?:\d{4}[-\/.]\d{1,2}[-\/.]\d{1,2}|\d{1,2}[-\/.]\d{1,2}[-\/.]\d{2,4})
         (?:[ T]\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:\s?(?:[AaPp][Mm]|Z|[+-]\d{2}:?\d{2}))?)?\z/x

def klass(cell)
  return :empty  if cell.empty?
  return :number if CellKind.cell(cell) == :number
  return :date   if cell.length <= 40 && DATE.match?(cell)
  :text
end
```

Decision:

1. **Only one record** (`k == 0`): it is a header iff every one of its cells is `:text` (non-empty, not a number, not a date). So `Name,Amount,Date` alone is a header; `Coffee,4.50,2026-03-14` alone is data.
2. Otherwise compute a score, starting at 0. For each column `c` with at least one non-empty data cell:
   - `dtype` is `:number` if at least 80% of the non-empty data cells are `:number`, else `:date` if at least 80% are `:date`, else `:text`.
   - If `dtype` is `:number` or `:date`: add **+2** if `klass(R0[c])` is `:text`; add **-2** if it equals `dtype`; otherwise 0.
   - If `dtype` is `:text`: add **-1** if `R0[c]` is empty. If `R0[c]` is `:text`, there are at least 2 data cells, and they all have the same length `L`: add **+1** if `R0[c].length != L`, **-1** if it equals `L`.
3. Add **-1** if `R0` has duplicate non-empty values.
4. It is a header iff `score > 0`, or `score == 0` and every cell of `R0` is `:text`. (With no evidence either way, assume a header: exported files almost always have one, and the cost of a wrong guess is only that one row is styled as a header.)

Verified cases (prototype): numbers or dates under text labels give a header; an all-number first row is data; a first row starting with a date is data; `Name` over names is a header; a duplicate-valued first row over text is data; a blank header cell over numbers is still a header. Known, accepted false positive: a headerless all-text file (`Alice,Smith\nBob,Jones`) is treated as having a header.

`header_row: true` always uses `R0` as the header; `header_row: false` never does.

### 4.11 Building the `Sample`

```ruby
Parser.normalize!(text)
delimiter = config.delimiter == :auto ? sniff(text, complete: result.complete) : config.delimiter
records = Records.new(text, complete: result.complete, delimiter:, keep_rows: max_rows + 1,
                      keep_columns: max_columns, raw_cap: RAW_CAP, deadline:).call
kept      = records.kept       # up to max_rows + 1 records, each an Array of up to max_columns RawCells
widths    = records.widths     # record width (capped at max_columns) for each kept record
count     = records.count      # non-blank records seen
max_width = records.max_width  # widest record seen
complete  = records.complete   # false if the Reader stopped early, the field guard stopped the parse,
                               # or a recovery pass was rejected (4.6)

cleaned  = kept.map { |cells| cells.map { |c| Sanitizer.clean(c.text, max_cell_chars:, capped: c.capped) } }
header   = case header_row when true then count > 0 when false then false else HeaderDetector.header?(cleaned, ...) end
data     = header ? cleaned[1, max_rows] || [] : cleaned.first(max_rows)
used     = header ? widths.first(max_rows + 1) : widths.first(max_rows)
```

| `Sample` field | Value |
|---|---|
| `column_count` | `used.max \|\| 0` (at most `max_columns`): the widest of the header and the kept data rows. Columns that are blank in every shown row past the last non-blank one are not shown. |
| `headers` | `header ? pad_or_cut(cleaned[0]) : nil` |
| `rows` | `data.map { \|r\| pad_or_cut(r) }`: each exactly `column_count` strings, padded with `""` |
| `total_columns` | `max_width`: the widest record in everything parsed, using 4.7 rule 6 (trailing blank fields do not count). After a field-guard stop it is the width read before the stop. |
| `rows_read` | `count - (header ? 1 : 0)` |
| `total_rows` | `complete ? rows_read : nil` |
| `rows_truncated?` | `rows_read > rows.size \|\| !complete` |
| `columns_truncated?` | `total_columns > column_count` |
| `column_kinds` | `(0...column_count).map { \|c\| CellKind.column(rows.map { \|r\| r[c] }) }` (header excluded) |
| `delimiter` | the delimiter used (the sniffed one, `","` when nothing could be sniffed, or the explicit one) |
| `encoding` | from the Reader |
| `empty?` | `count.zero?` |

All strings and arrays in the `Sample` are frozen; the `Sample` itself is frozen. Value equality (`==`) compares all fields, so a test can assert that sampling twice gives equal samples.

Note on `empty?`: it describes the bytes read. When `complete` is false, `empty?` can be true while data exists further into the file (the first `max_input_bytes` were blank). The empty-state image must not claim the whole file is empty in that case; see [`rendering.md`](./rendering.md).

### 4.12 Empty input

| Input | Result |
|---|---|
| 0 bytes | `empty?` true, `headers` nil, `rows` `[]`, `column_count` 0, `total_columns` 0, `rows_read` 0, `total_rows` 0, both truncated flags false, `column_kinds` `[]`, `delimiter` `","` (or the explicit one), `encoding` `"UTF-8"` (or the explicit one) |
| only spaces, tabs, CR, LF (after any BOM) | same as 0 bytes |
| only blank lines and delimiter-only lines (`,,,\n,,`) | same as 0 bytes |
| a single header row | not empty: `headers` set, `rows` `[]`, `rows_read` 0 |

`render` on empty input does **not** raise: it returns the small "empty file" image designed in [`rendering.md`](./rendering.md), as the overview requires. `layout` returns a Layout for that image.

### 4.13 `csv` versions

- **What Ruby ships.** Ruby 3.3 ships csv 3.2.8 as a default gem (Ruby 3.3.0 NEWS; `lib/csv/version.rb` on the `ruby_3_3` branch, both checked 2026-11-15). From Ruby 3.4, csv is a bundled gem and must be declared; the Ruby 3.4.12 and 4.0.2 installations used here carry 3.3.5. The newest release is 3.3.7.
- **Gemspec:** `spec.add_dependency "csv", ">= 3.2.8", "< 4"`. 3.2.8 is the oldest version a supported Ruby provides without installing anything, so on Ruby 3.3 Bundler can use the default gem. The upper bound is there because the Parser depends on behaviour that is public only in practice (chunked reads through `gets`, the exact results of `liberal_parsing`, the contents of `csv.line`), which a major version could change.
- **What was compared.** Everything the Parser relies on was checked on csv 3.2.6, 3.2.8, 3.2.9, 3.3.0, 3.3.2, 3.3.5 and 3.3.7, on Ruby 3.4.12 and 4.0.2: the IO methods `csv` calls, `quote_char: nil`, the lenient results of 4.7, the contents of `csv.line`, which errors are raised, and that exceptions raised in `gets` propagate unchanged. The prototype's seeded fuzz runs produced identical result digests on every version (measured). No behaviour difference was found between 3.2.x and 3.3.x for this use. (The class raised for invalid byte sequences differs between versions; it cannot happen here, because the Parser only ever sees valid UTF-8.)
- **CI** runs the Parser tests against both ends of the range (PS-36): csv 3.2.8 in the Ruby 3.3 job and the newest csv in the Ruby 3.4 and 4.0 jobs. `Gemfile.lock` is git-ignored, so Dependabot cannot propose in-range csv releases (it only proposes updates that widen the requirement); the newest-csv CI jobs resolve the latest release on every run instead. PS-31 and PS-34 are the tests most likely to catch a behaviour change.

---

## 5. Sanitizer

### 5.1 What it does, per character class

The Sanitizer turns raw cell text into a single line of literal, displayable text. It runs on every kept cell (header and data) and on nothing else.

| Characters | Treatment | Why |
|---|---|---|
| Line breaks and tabs: CR, LF, CRLF, TAB, VT (U+000B), FF (U+000C), NEL (U+0085), LINE SEPARATOR (U+2028), PARAGRAPH SEPARATOR (U+2029) | Each **run** becomes **one space** | Cells are drawn on one line. Pango breaks lines on U+2028 and paragraphs on CR, LF and U+2029, so these must never reach it. |
| Other C0 controls (U+0000 to U+0008, U+000E to U+001F), DEL (U+007F), other C1 controls (U+0080 to U+0084, U+0086 to U+009F) | **Removed** | Invisible or rendered as boxes. U+0000 must go: ruby-vips raises `ArgumentError` on a NUL in text (measured). |
| Bidi embeddings and overrides U+202A to U+202E (LRE, RLE, PDF, LRO, RLO); isolates U+2066 to U+2069 (LRI, RLI, FSI, PDI) | **Removed** | They reorder visible text: an RLO (U+202E) placed before `00.001$` makes it display as `$100.00`. |
| Bidi marks U+200E (LRM), U+200F (RLM), U+061C (ALM) | **Removed** | They cannot reorder letters but can move digits and punctuation around them in mixed-direction text, which is exactly where an amount could be misread. The cost is a slightly different placement of neutral characters in some mixed RTL cells, which is acceptable for a preview. Together with the row above this is the full Unicode `Bidi_Control` set, written out explicitly so it does not shift with Ruby's Unicode version. |
| Invisible format characters U+200B (ZERO WIDTH SPACE), U+2060 (WORD JOINER), U+FEFF (BOM / ZWNBSP, anywhere in a cell), U+FFF9 to U+FFFB (interlinear annotation) | **Removed** | Invisible at best, a missing-glyph box at worst. |
| U+200C (ZWNJ) and U+200D (ZWJ) | **Kept** | Required for emoji sequences (family, profession emoji) and for correct shaping in Persian and Indic scripts. |
| Variation selectors, emoji tag characters, regional indicators | **Kept** | Needed for emoji and flags. |
| Runs of more than 8 nonspacing or enclosing marks (`\p{Mn}`, `\p{Me}`) | Cut to the first **8** | Stops "Zalgo" text from drawing far outside its row. Real scripts rarely stack more than 3 or 4. |
| U+FFFD | **Kept** | It is the visible sign of undecodable bytes. |
| Leading and trailing ASCII spaces (including those produced above) | **Trimmed** | Invisible except as misalignment; common in exports padded for fixed width. Non-breaking spaces are kept. |
| Everything else (letters, digits, symbols, emoji, CJK, RTL letters, `<`, `&`, `=`, `+`, `@`) | **Kept literally** | |

Strong right-to-left letters (Hebrew, Arabic) still display right to left inside their own cell; that is correct and cannot affect neighbouring cells as long as the renderer lays out each cell as its own paragraph, which [`rendering.md`](./rendering.md) must guarantee. Unicode normalisation is not applied (text is shown as written).

### 5.2 Reference implementation

```ruby
module CsvPreview
  module Sanitizer
    ELLIPSIS   = "…"
    BREAKS     = /(?:\r\n|[\t\n\v\f\r\u0085\u2028\u2029])+/
    REMOVE     = /[\u0000-\u0008\u000E-\u001F\u007F-\u0084\u0086-\u009F\u061C\u200B\u200E\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF\uFFF9-\uFFFB]+/
    MARK_RUN   = /[\p{Mn}\p{Me}]{9,}/
    EDGE_SPACE = /\A +| +\z/

    module_function

    def clean(text, max_cell_chars:, capped: false)
      s = text.gsub(BREAKS, " ")
      s.gsub!(REMOVE, "")
      s.gsub!(MARK_RUN) { |run| run[0, 8] }
      s.gsub!(EDGE_SPACE, "")
      clusters = s.each_grapheme_cluster.first(max_cell_chars + 1)
      return s.freeze if clusters.size <= max_cell_chars && !capped
      (clusters.first(max_cell_chars - 1).join.sub(/ +\z/, "") + ELLIPSIS).freeze
    end
  end
end
```

Its input is at most `RAW_CAP` bytes (4.8), so every regex here runs on bounded text (about 50 to 150 µs per cell in the worst case, measured). The regexes contain no nested quantifiers.

### 5.3 Truncation to `max_cell_chars`

- "Characters" means **extended grapheme clusters** (`String#each_grapheme_cluster`), so a family emoji, a flag or "e" plus a combining accent is never split. (Ruby 3.3 and 3.4 both implement Unicode 15.0 segmentation.)
- A cell longer than `max_cell_chars` clusters, or whose raw content was capped, becomes its first `max_cell_chars - 1` clusters, with trailing spaces removed, followed by "…" (U+2026). No `Sample` cell is ever longer than `max_cell_chars` clusters. With `max_cell_chars: 1`, a long cell is just "…".
- This is the only truncation in the `Sample`. Fitting text to a column's pixel width is the Layout's job ([`rendering.md`](./rendering.md)), which also re-applies the cluster cap with an extra code-point limit; because a `Sample` cell already has at most `max_cell_chars` clusters, the two rules agree.

### 5.4 Formulas are data

Cells such as `=HYPERLINK("http://example.com","x")`, `+cmd|' /C calc'!A0`, `@SUM(A1:A2)` and `-2+3` are kept exactly as written: never evaluated, never prefixed with `'`, never altered. A preview image cannot execute anything. `-2+3` is classified as text (it is not a number pattern). Applications that copy `Sample` cells into a spreadsheet or a new CSV must apply their own formula-injection defence; the README's security notes should say so.

### 5.5 Markup escaping is not the Sanitizer's job

The Sanitizer output may contain `<`, `>`, `&`, quotes and anything else. `Vips::Image.text` always parses its input as Pango markup (an unescaped `&` raises `Vips::Error: text: invalid markup in text`, measured), so **`text.rb` must escape every string it passes to libvips** (cells, headers, footer, empty-state text): `&` to `&amp;`, `<` to `&lt;`, `>` to `&gt;`, `'` to `&apos;`, `"` to `&quot;`. Keeping escaping in one place, at the point of use, means the `Sample` stays literal for applications that render it as HTML (which must HTML-escape it themselves).

---

## 6. CellKind

### 6.1 Cell patterns

A cell is classified **after** sanitizing (so it is trimmed). `CellKind.cell(s)` returns `:empty`, `:number` or `:text`.

```ruby
module CsvPreview
  module CellKind
    CURRENCY_CODES = %w[
      USD EUR GBP JPY CNY CAD AUD NZD CHF HKD SGD INR KRW TWD THB MYR IDR PHP VND
      MXN BRL ARS CLP COP PEN ZAR SEK NOK DKK ISK PLN CZK HUF RON TRY ILS AED SAR
      RUB UAH NGN KES EGP
    ].freeze
    SYMBOL = '(?:US\$|CA\$|C\$|A\$|AU\$|NZ\$|HK\$|S\$|R\$|MX\$|[$€£¥₹₩₽₪₫₱₴₺₦₵₸₼₾¢฿]|kr|Kč|zł)'
    CUR    = "(?:#{SYMBOL}|#{CURRENCY_CODES.join("|")})"
    SP     = '[ \u00A0\u202F]?'          # at most one (possibly non-breaking) space between parts
    GROUP  = '[ \u00A0\u202F\u2009]'     # space-like thousands separators
    SIGN   = '[-+\u2212]'                # hyphen-minus, plus, true minus
    NUM = "(?:" + [
      '\d{1,3}(?:,\d{3})+(?:\.\d+)?',              # 1,234,567.89
      '\d{1,3}(?:\.\d{3})+(?:,\d+)?',              # 1.234.567,89
      '\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d+)?',        # 12,34,567.89 (Indian grouping)
      "\\d{1,3}(?:#{GROUP}\\d{3})+(?:[.,]\\d+)?",  # 1 234 567,89
      '\d{1,3}(?:[\'’]\d{3})+(?:\.\d+)?',     # 1'234'567.89 (Swiss)
      '\d+(?:[.,]\d+)?(?:[eE][-+]?\d{1,3})?',      # 1234.56, 1234,56, 1234, 1.5e10
      '[.,]\d+'                                    # .5
    ].join("|") + ")"
    NUMBER = Regexp.new('\A(?:' + [
      "#{SIGN}?#{SP}#{NUM}#{SP}%",                                # -3.5 %
      "#{SIGN}?#{SP}(?:#{CUR}#{SP})?#{NUM}(?:#{SP}#{CUR})?",      # -$1,284.50, 1.234,56 €, USD 12.00
      "#{CUR}#{SP}#{SIGN}#{SP}#{NUM}",                            # $-12.00
      "(?:#{CUR}#{SP})?#{NUM}-",                                  # 12.00- (trailing minus)
      "\\(#{SP}(?:#{CUR}#{SP})?#{NUM}(?:#{SP}#{CUR})?#{SP}\\)",   # (45.00), ($45.00)
      "#{CUR}#{SP}\\(#{NUM}\\)"                                   # $(45.00)
    ].join("|") + ')\z')
    BARE_INTEGER      = /\A\d+\z/
    PLACEHOLDER       = /\A(?:[-\u2010-\u2015\u2212]{1,3}|n\/?a|null|none|nan)\z/i
    MAX_NUMBER_LENGTH = 40
    NUMBER_SHARE      = 0.8

    module_function

    def cell(s)
      return :empty if s.empty?
      return :text if s.length > MAX_NUMBER_LENGTH || !NUMBER.match?(s)
      if BARE_INTEGER.match?(s)
        return :text if s.length > 15 || (s.length > 1 && s.start_with?("0"))
      end
      :number
    end
  end
end
```

Rules encoded above:

- At most one sign, at most one currency on each side, percent and currency are exclusive, and at most one space between parts. The pattern is normative: a prefix and a suffix may both appear (`-$12.00 USD` is a number; accepting it only right-aligns the cell). The alternatives are enumerated rather than made optional so that `-$-12` and `12.00 USD EUR` are text.
- Currency symbols that are also ordinary letters or common prefixes (`R`, `RM`, `Rp`, `Fr.`) are excluded because `R2` or `RM101` would otherwise be numbers. ISO codes come from a fixed list of 43 common currencies; a generic `[A-Z]{3}` would make `ABC 12.00` a number.
- A **bare integer** (digits only, no sign, separator, decimal, currency or percent) is an identifier, not a number, when it has a leading zero and more than one digit (ZIP `02139`, account `0012`) or more than 15 digits (beyond exact double precision: reference numbers, card numbers).
- Cells longer than 40 characters are text without running the regex, which also bounds regex work (the slowest case measured was 17 µs on a 40-character adversarial string).
- Both `-` and the true minus `−` (U+2212) are accepted. Replacing `-` with `−` for display is the Layout's choice ([`rendering.md`](./rendering.md)); the `Sample` keeps the literal text.

| Number (`:number`) | Not a number (`:text`) |
|---|---|
| `1234.56`, `$1,234.56`, `-12.00`, `(45.00)`, `1.234,56 €`, `12%` | `02139`, `94105-1234` (ZIP codes) |
| `USD 12.00`, `12.00 USD`, `−12.00` (true minus), `-$1,284.50`, `$-12.00` | `24692165073000312345678` (reference number), `4111 1111 1111 1111` (card) |
| `€1.234,56`, `12,50`, `1 234,56` (NBSP), `1'234.50`, `₹1,23,456`, `R$ 12,00`, `kr 100` | `•••• 4821` (masked card), `INV-001`, `ABC 12.00`, `R2`, `RM101` |
| `0`, `0.5`, `.5`, `+7`, `42`, `1,284`, `1.284`, `1.5e10`, `-3.5 %` | `(415) 555-1234`, `415-555-1234`, `+1 415 555 1234`, `+44 20 7946 0958` (phones) |
| `($45.00)`, `$(45.00)`, `12.00-` | `2026-03-14`, `03/14/2026`, `14.03.2026`, `12:30`, `1.2.3`, `v1.2.3` |
| | `N/A`, `-`, `$`, `%`, `--12`, `1,23,4`, `12 34`, `-$-12`, `-2+3` |

Bare integers such as MCC codes (`5942`), card last-4 (`4821`), years (`2026`) and phone numbers without punctuation (`4155551234`) are numbers at the cell level; the column rule below turns such columns back into text.

### 6.2 Column rule

```ruby
def column(cells)
  numbers = []
  texts = 0
  cells.each do |c|
    next if c.empty? || PLACEHOLDER.match?(c)    # "", "-", "\u2014", "N/A", "null", "none", "nan"
    cell(c) == :number ? numbers << c : texts += 1
  end
  return :text if numbers.empty? || numbers.size < NUMBER_SHARE * (numbers.size + texts)
  return :text if identifier_like?(numbers)
  :number
end

# Every numeric cell is a bare integer, there are at least two, and all have the
# same number of digits, at least 4: MCC codes, last-4, years, phone numbers.
def identifier_like?(numbers)
  numbers.size >= 2 && numbers.all? { |n| BARE_INTEGER.match?(n) } &&
    numbers.map(&:length).uniq.then { |l| l.size == 1 && l[0] >= 4 }
end
```

- A column is `:number` when at least **80%** of its non-empty, non-placeholder cells in the **shown data rows** (header excluded) are numbers, and it is not identifier-like. Placeholders are ignored so that `12.00, -, N/A, 3.50` stays numeric.
- Columns with no countable cells are `:text`.
- Accepted misclassification: a column whose values are all, say, 4-digit integer amounts (`1200`, `3400`) is treated as identifiers. Since all values have the same width, left versus right alignment looks almost the same.

Verified on a 23-column statement export (prototype): Amount, Balance, Exchange Rate and Original Amount are `:number`; Transaction Date, Card (`•••• 4821`), MCC, Reference ID and all text columns are `:text`. Quantities `1, 2, 10` are `:number`; ZIP, MCC, last-4, years and phone columns are `:text`; `1500000, 250000, 75000` is `:number`.

Work: at most `max_rows × max_columns` regex checks on strings of at most 40 characters.

---

## 7. Bounds and worst cases

### 7.1 Work bound

Let `B = max_input_bytes`, `R = max_rows`, `C = max_columns`, `K = max_cell_chars`, `T` the decoded text (at most `3B` bytes).

| Step | Work | Why it is bounded |
|---|---|---|
| Read | `O(B)` in at most `ceil(B / 64 KiB)` calls | the loop stops at `B` bytes; oversize chunks are cut |
| Binary detection | `O(1)` + `O(8 KiB)` | fixed windows |
| Encoding decision, decode | `O(B)` C-level passes | one `valid_encoding?`, at most one `scrub`, one `encode` |
| Normalising line breaks | `O(len(T))` | two C passes (`tr!`, `squeeze!`), in place |
| Sniffing | `O(4 × 64 KiB)` | fixed sample; each pass stops after 30 records |
| Parsing with `csv` | `O(len(T))` | `csv` reads the text forward through the `Feed`; recovery (4.6) adds at most two further passes, each starting at the rejected record and moving forward, plus one line, so at most `3 × len(T)` bytes are parsed. Every record is built and dropped, and the field guard (4.5) keeps any one record under about 82,000 fields. |
| Sanitizing | `O(R × C × K)` | `(R + 1) × C` cells, each at most `RAW_CAP = O(K)` bytes |
| Header detection, CellKind | `O(R × C)` | regexes on at most 40 characters |
| Layout and painting | `O(R × C × K)` | at most `(R + 1) × C` cells of at most `K` clusters each ([`rendering.md`](./rendering.md)) |

Total: `O(B) + O(R × C × K)`, independent of the file's size beyond `B` and of its shape. With the defaults that is at most three `csv` passes over the decoded text plus at most 21 × 12 × 60 characters of cell text.

### 7.2 Peak memory

| Item | Size (default `B` = 2 MiB) |
|---|---|
| Raw buffer | `B` = 2 MiB (released after decoding) |
| Decoded text | `<= 3B` = 6 MiB worst case (Windows-1252 full of `80`); about `B` typically |
| Transient copies while decoding (`scrub("")` for the encoding decision, the `encode` output) | `<= B + 3B` |
| Normalising | none: `tr!` and `squeeze!` work in place |
| `csv` input | one chunk of at most 8 KiB at a time (the `Feed` hands out copies, which are short-lived) |
| Regex engine | at most about 400 KB: every `csv` match is confined to one chunk (4.3), about 48 bytes per byte matched |
| One record | at most about 82,000 fields (4.5), about 6 MB of row array; a single field can be as long as the text (`csv` joins it across chunks), at most `3B` |
| Recovery | the cut-tail pass copies the rest of the text once (`<= 3B`); other passes take shared `byteslice`s |
| Kept cells | `(R + 1) × C × RAW_CAP` = 21 × 12 × 552 bytes, about 140 KB |
| Sniffing | 64 KiB sample plus 4 × 30 × 64 small strings |

Parse peak: about **25 MiB above baseline** in the worst case. Measured: the largest growth over all the shapes in 7.3 was 20 MB (an unclosed quote followed by 2 MiB of letters, including the cut-tail copy), and the whole Ruby process never exceeded 43 MB maximum RSS (Ruby with `csv` loaded is about 20 MB). Reading 2 MiB of a 50 MB file and parsing it grew RSS by 11 MB. Without the `Feed` and the field guard the same shapes grew it by up to 202 MB (4.1).

Rendering adds the canvas (at most `max_width_px × max_height_px × 4` bytes, about 21 MB at the defaults), libvips working buffers, the encoder, and anything libvips' operation cache retains (default limits: 100 operations, 100 MB; text images for 60-character cells are small). See [`rendering.md`](./rendering.md). The 200 MB target leaves a wide margin.

### 7.3 Hostile shapes considered

All are 2 MiB (the default limit) unless noted. Times are for `Parser.normalize!` plus `Records` (appendix A), best of three runs, Ruby 3.4.12 and csv 3.3.5 on a loaded M1 Pro (load average 10 to 15 for the slow shapes); the YJIT column is the same with `--yjit`. "Growth" is the increase in the whole process's maximum RSS over a run that only built the input. Every shape gave the same counts on csv 3.2.8.

| Shape | What it attacks | Time | YJIT | Growth |
|---|---|---|---|---|
| Realistic 23-column export, repeated (9,800 rows, quoted amounts) | baseline | 0.24 s | 0.16 s | 5 MB |
| One line of `x,` repeated (about 1,000,000 fields); `one_line_million_columns.csv` | per-field allocation; field guard (stops at 69,632 fields) | 0.06 s | 0.04 s | 5 to 6 MB |
| Only `,` (one line of 2,097,152 empty fields) | blank detection; field guard | 0.07 s | 0.04 s | 4 MB |
| Only `\n`; only `\r\n`; only spaces; ` ,` repeated | blank-record skipping, normalisation | 0.003 s; 0.003 s; 0.02 s; 0.07 s | similar | 1 to 14 MB |
| `a\n` repeated (1,048,576 rows) | per-record cost (quote-free mode) | 1.41 s | 0.75 s | 0 MB |
| `a\r\n` repeated (699,051 rows) | per-record cost after normalisation | 0.92 s | 0.51 s | 0 MB |
| `"h","i"` then `a\n` repeated | quote-free switch after the header | 1.40 s | 0.75 s | 0 MB |
| One 2 MiB unquoted cell; one 2 MiB quoted cell | huge field, regex memory | 0.02 s | 0.02 s | 14 MB; 11 MB |
| Only `"`; one quoted field of `""` pairs | quote runs, escapes | 0.02 s | 0.02 s | 13 to 14 MB |
| `"` then 2 MiB of letters, input cut | cut-tail recovery (4.6 rule 2) | 0.04 s | 0.04 s | 20 MB |
| `"` then lines of text, input cut (one multi-line quoted field from the first byte) | stray-quote recovery on a kept record (116,508 rows) | 0.18 s | 0.11 s | 14 MB |
| `,"` repeated; `"",` repeated (700,000 empty quoted fields); `"a",` repeated | quote state flips; field guard | 0.05 to 0.10 s | 0.04 to 0.06 s | 2 to 6 MB |
| `"a","b"\n` repeated (262,144 rows) | quoted rows | 1.11 s | 0.64 s | 0 MB |
| `"\n"\n` repeated (524,288 blank quoted records) | per-record cost, quoted path | 1.47 s | 0.84 s | 0 MB |
| `"\n",` repeated (one record of multi-line fields) | field guard inside quotes | 0.13 s | 0.08 s | 6 MB |
| `"a"b,` (text after quotes); ` "a",` (whitespace before quotes); `a"b,` (mid-field quotes), each repeated | lenient results, field guard | 0.07 to 0.16 s | 0.04 to 0.11 s | 4 to 6 MB |
| `a,"x\n` then 2 MiB of `1,2,3\n` | stray quote, guard stop undone (rule 1), all 349,526 rows counted | 0.54 s | 0.31 s | 2 MB |
| `€é漢字🙂,` repeated | multibyte text, field guard | 0.11 s | 0.08 s | 8 MB |
| Realistic export cut mid-record; the same with CRLF, cut inside a quoted field | cut handling (rule 2 for the second) | 0.24 s | 0.16 to 0.20 s | 0 to 2 MB |
| 50 MB file (only 2 MiB read) | bounded read | 0.25 s read + parse | | 11 MB |

Shapes that never reach `csv`: binary files with NUL bytes, magic numbers (section 3.3); BOM-only files (empty after the BOM).

### 7.4 Performance budget

- **Target:** parsing (Reader + Parser) any 2 MiB input finishes in under 2 s on a current developer laptop without YJIT. With YJIT (which Rails 7.2 and later enable by default in production) the slowest shape measured about 1.2 s on a loaded M1 Pro; that is accepted for 0.1, since the `timeout` option bounds the cost in production and realistic exports parse far faster. This is twice the budget of the hand-written tokenizer: `csv` builds every record, and the slowest inputs are a million tiny records at about 1.4 µs each.
- **CI assertion** (PS-18): every shape in 7.3 completes `CsvPreview.sample` in under 5 s on the CI runner. The margin avoids flaky tests; the `timeout` option protects production regardless.
- Realistic exports of 2 MiB parse in about 0.15 to 0.25 s.
- Since the slowest hostile inputs cost about one and a half seconds of CPU without YJIT, applications that preview inline in web requests should prefer background generation (Active Storage already does this for preprocessed variants).

---

## 8. Deadline and timeouts

### 8.1 Why not `Timeout.timeout`

- **It can corrupt state.** `Timeout.timeout` raises asynchronously in the calling thread at whatever line is running, including inside `ensure` blocks, while a mutex is held, or in the middle of another library's bookkeeping (a connection pool, an Active Storage download). The gem runs inside Puma and Sidekiq threads it does not own, so it must not inject asynchronous exceptions into them.
- **It cannot stop the slow part anyway.** A thread only receives the exception when it next checks for interrupts, which does not happen inside a C call made through FFI. Measured: `Timeout.timeout(0.02) { image.write_to_buffer(".png") }` on a large image raised only after **0.18 s**, when the libvips call returned (the call alone took 0.18 to 0.19 s).

### 8.2 Design

```ruby
module CsvPreview
  class Deadline
    CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    def initialize(seconds, clock: CLOCK)
      @seconds = seconds
      @clock = clock
      @expires_at = clock.call + seconds
    end

    def check!(stage)
      return if @clock.call <= @expires_at
      raise TimeoutExceeded, "csv_preview exceeded its #{@seconds}s timeout (#{stage})"
    end

    def remaining = [@expires_at - @clock.call, 0.0].max
  end
end
```

- Monotonic clock, so wall-clock changes do not matter.
- Cooperative: the code calls `check!` at checkpoints. Nothing is interrupted asynchronously; a timeout surfaces as an ordinary exception at a known, safe point.
- One `Deadline` per call, created at the API entry point; no shared state.
- The `clock:` keyword exists for tests only (internal classes accept `deadline:`), so tests can expire the deadline at a chosen checkpoint deterministically.
- `timeout` must be a positive `Numeric` (validated by `Configuration`).
- A `check!` costs one `clock_gettime` (well under 100 ns), so hot loops call it every 1,024 work units rather than every iteration.

### 8.3 Checkpoints

| Stage | Where `check!` is called |
|---|---|
| `:read` | before every chunk read (every 64 KiB) |
| `:decode` | after binary detection, after the encoding decision, after transcoding |
| `:sniff` | before each candidate delimiter |
| `:parse` | before every chunk the `Feed` hands to `csv` (at most every 8 KiB of text, even inside one record), and every 1,024 records |
| `:sanitize` | before each kept record |
| `:layout` | before each cell measured ([`rendering.md`](./rendering.md)) |
| `:paint` | before each cell drawn, and immediately before the final encode |

### 8.4 How late can a timeout be?

A `TimeoutExceeded` is raised at the first checkpoint after the deadline, so the overrun is the longest stretch of work between two checkpoints:

- Work between parse checkpoints: `csv` parsing at most one 8 KiB chunk, or at most 1,024 records, whichever ends first: a few milliseconds.
- The longest single C calls before rendering: transcoding 2 MiB, about 10 to 20 ms; normalising line breaks and copying the tail for the cut-tail recovery, a few milliseconds each.
- A libvips text call: its input is one cell of at most `max_cell_chars` clusters (plus the escaped markup), so it is short, typically about a millisecond. No libvips call ever receives unbounded text.
- The final image encode: bounded by the output pixel caps, not by the input. Its cost for the largest allowed canvas is measured in [`rendering.md`](./rendering.md).

So for parsing, the overrun is at most a few tens of milliseconds; for a whole render, that plus one encode of at most `max_width_px × max_height_px` pixels.

**`timeout: 0.001` on a large file:** the deadline expires during reading or decoding; the first checkpoint reached raises, whichever stage that is (`:read`, `:decode` or later, depending on how fast the host is). On a 50 MB file only the chunks read before that point (a few hundred KiB at most) are read. On `wide_long.csv`, `render` with `timeout: 0.001` always raises, because measuring and drawing hundreds of cells takes far longer than a millisecond even if parsing were instant (PS-21).

**Caveat:** a blocking `read` on a caller-supplied stream cannot be interrupted (section 3.2).

---

## 9. No subprocesses, no network, no eval, no ImageMagick, no writes

### 9.1 Rules for the code

- **Forbidden anywhere in `lib/`:** `system`, `spawn`, `exec`, `fork`, backticks and `%x()`, `IO.popen`, `Open3`, `Process.spawn`, `Kernel#open`, `IO.read`/`IO.readlines`/`IO.foreach`/`IO.write`, `URI.open`, `require "socket"`, `require "net/http"`, `require "open-uri"`, `eval`, `instance_eval`/`class_eval`/`module_eval` with a string, `binding`, `Marshal.load`, `YAML.load`, and `send`/`public_send` with a name derived from input. Also forbidden: the `csv` entry points that take a path or a whole string (`CSV.open`, `CSV.read`, `CSV.readlines`, `CSV.foreach`, `CSV.table`, `CSV.parse`, `CSV.parse_line`); the only one allowed is `CSV.new` with a `Feed` (4.3).
- **Input bytes never reach an image decoder.** The CSV buffer is never passed to `Vips::Image.new_from_buffer`, `new_from_file`, `new_from_source` or any `*load*` operation. Only sanitized, escaped cell text reaches libvips, through `Vips::Image.text`. So a PNG, SVG or PDF payload disguised as CSV can never exercise a libvips loader, even if it slipped past binary detection.
- **No writes.** `render`, `sample` and `layout` write no files: images are produced with `write_to_buffer`. (The Active Storage previewer's tempfile is created and removed by Active Storage itself.)
- **No ImageMagick or MiniMagick**, not even optionally.
- **No global libvips settings are changed** (section 10).

### 9.2 How the tests prove it

| Property | Test technique |
|---|---|
| No subprocesses | Prepend a guard module that raises to `Kernel` (covers `system`, `spawn`, `exec`, `fork`, `` ` ``, `%x()`, `open`), `Kernel.singleton_class`, `Process.singleton_class` (`spawn`, `fork`, `exec`), `IO.singleton_class` (`popen`) and `Open3.singleton_class` (all its singleton methods). Measured: this catches `system`, `Kernel.system`, backticks, `%x()`, `spawn`, `Process.spawn`, `IO.popen`, `Open3.capture2`, `exec`, `fork` and `open("\|cmd")`, including when called on arbitrary objects. Then render every fixture (PS-25). |
| No libvips loaders | Stub `Vips::Image.new_from_buffer`, `.new_from_file`, `.new_from_source` and any `Vips::Image` class method whose name contains `load` to raise; render every fixture (PS-25). |
| No network | (a) In-process: `require "socket"` in the test, then prepend raising guards to `TCPSocket`, `UDPSocket`, `Socket` (`new`, `tcp`, `udp_server_sockets`, `#connect`) and `Addrinfo.getaddrinfo`; render every fixture. WebMock's `disable_net_connect!` may be used too but only covers HTTP clients. (b) In a clean child process (`ruby -Ilib -e ...`): require the gem, render every fixture, and assert `$LOADED_FEATURES` contains no `socket`, `net/http`, `open-uri`, `resolv` or `open3`. Measured: requiring `ruby-vips` loads 52 files and none of these; requiring `csv` loads `forwardable`, `date`, `time`, `English`, `stringio`, `strscan` and its own files, none of these either (csv 3.2.8 and 3.3.5). (c) On Linux CI, run that child under `strace -f -e trace=execve,socket,connect` and assert there is exactly one `execve` (the child itself) and no `AF_INET`/`AF_INET6` sockets (PS-26). |
| No ImageMagick | Run in a child process with `PATH` set to an empty temporary directory (no `convert`, `magick`), with `Kernel#require` stubbed to raise `LoadError` for `mini_magick` and `rmagick`, and assert `!defined?(MiniMagick)` after rendering every fixture (PS-27). |
| No eval and no forbidden APIs | A source scan over `lib/**/*.rb` (Prism or Ripper, falling back to regexes) for every name in 9.1 (PS-28). |
| No stray writes | Render every fixture with `TMPDIR` and the working directory set to fresh empty directories and `HOME`/`XDG_CACHE_HOME` pointed at a temporary directory; after one warm-up render (fontconfig may build its cache on first use, which is system font infrastructure, not the gem), assert that `TMPDIR`, the working directory, the cache directory and the gem's own directory are unchanged by further renders. On Linux, additionally run under `strace -e trace=openat` and assert no open with `O_WRONLY`, `O_RDWR` or `O_CREAT` after the warm-up (PS-29). |

The Ruby-level stubs prove the gem's own code; the `strace` jobs also cover native code (libvips, Pango, fontconfig) and are cheap to add to the Ubuntu CI job.

---

## 10. Thread safety

- **Configuration snapshot per call.** `CsvPreview.config` holds a frozen `Configuration`. `CsvPreview.configure` yields a mutable copy, then freezes it and swaps the reference in one assignment (atomic in CRuby). Each API call merges per-call options into a **new frozen** `Configuration` at entry and uses only that. A concurrent `configure` therefore never changes a render halfway through. `configure` is meant for boot time.
- **No shared mutable state.** Regexes, tables and the `Theme` are frozen constants. `CSV` objects, `Feed`s, buffers, the `Deadline` and the `Sample` are per call; the gem never touches `csv`'s global tables (`CSV::Converters`, `CSV::HeaderConverters`) or its default options. No memoisation in module or class variables; if one is ever needed (for example a one-time libvips capability check), it must be guarded by a `Mutex` and be immutable once set. No reliance on `$~` across method boundaries.
- **libvips global settings are left alone.** The gem does not call `Vips.cache_set_max`, `cache_set_max_mem`, `cache_set_max_files`, `concurrency_set`, `vector_set`, `block_untrusted_set` or `leak_set`. Reasons:
  - they are process-wide and would silently change how the host application's other image processing behaves (for example its Active Storage variants);
  - libvips' operation cache is thread-safe, and cached results are immutable images, so sharing them between threads is safe (two threads rendering the same header text get the same cached image). This holds because the gem never draws in place (no `mutate` or `draw_*` operation, rendering.md 7.1): an in-place draw changes an image that could have come from the cache, and in a threaded host it can crash the process, because libvips signals earlier draw operations it holds no reference to and Ruby's GC on another thread can free one first;
  - the gem's operations give identical output at any concurrency setting, so there is nothing to gain;
  - the gem never uses a loader, so `block_untrusted_set` would protect nothing of ours. Applications may still set it for their own reasons.

  Measured defaults on the development machine: cache of 100 operations, 100 MB, 100 files; concurrency 8.
- **Proof** (PS-30): render a set of fixtures serially and record SHA-256 digests; then run 8 threads, each rendering a different fixture 10 times, and assert every result equals the serial digest. Add a unit test that `CsvPreview.config` is frozen and that `configure` replaces it with a new frozen object.

---

## 11. Acceptance tests

"Renders" means `CsvPreview.render` returns bytes with the correct image signature, decodable by libvips, within `max_width_px × max_height_px` and within the timeout. Unless stated, defaults are used (`max_rows` 20, `max_columns` 12, `max_cell_chars` 60, `max_input_bytes` 2 MiB, `timeout` 5). Assertions about display strings go through `CsvPreview.layout`; assertions about parsing go through `CsvPreview.sample`.

**Parsing and encodings**

- **PS-1** `wide_long.csv` (31 columns × 1,284 data rows, header): `column_count` 12, `total_columns` 31, `rows.size` 20, `rows_read` 1,284, `total_rows` 1,284, both truncated flags true, header detected. Renders. The layout's footer reports 20 of 1,284 rows and the shown columns out of 31 (exact wording in [`rendering.md`](./rendering.md)).
- **PS-2** `utf8_bom.csv`, `utf16le_bom.csv`, `utf16be_bom.csv`, `utf32le_bom.csv`, `windows1252.csv` (all containing `é`, `€`, `“smart quotes”` and `’`): the cells equal the expected Unicode strings exactly; `encoding` is `"UTF-8"`, `"UTF-16LE"`, `"UTF-16BE"`, `"UTF-32LE"`, `"Windows-1252"`; the first header cell does not start with U+FEFF. All render.
- **PS-3** `utf16le_nobom.csv`: `encoding` `"UTF-16LE"`, cells correct.
- **PS-4** `invalid_utf8.csv`: `encoding` `"UTF-8"`; the stray bytes appear as U+FFFD in the expected cells; valid accented text is intact; renders.
- **PS-5** Delimiters: `semicolon_decimal_comma.csv` gives `";"`, `semicolon_2col_decimal.csv` gives `";"`, `tabs.tsv` gives `"\t"`, `pipes.csv` gives `"|"`, `single_column.csv` gives `","`. An explicit `delimiter: ";"` on `semicolon_decimal_comma.csv` gives the same cells.
- **PS-6** `quoted_newlines.csv` (cells with embedded CRLF and LF, commas, `""` escapes, a quoted empty field): cell boundaries and contents exactly as expected, embedded line breaks shown as single spaces. `mixed_line_endings.csv` (CRLF, LF and lone CR record ends in one file, and blank lines of each kind): does not raise; every record present; the same cells as the LF-only version of the file.
- **PS-7** `ragged.csv` (rows of 2, 5 and 3 fields): `total_columns` 5, every row padded to `column_count`; renders. `unbalanced_quote.csv` (a field opening with `"` and never closed, followed by more rows): does not raise; the field shows the literal `"`; the following rows are present and counted (4.6 rule 3); renders. `junk_after_quote.csv`: `"Big" Bob's Diner` and `"a,b" c` kept verbatim as single cells, `5" monitor` and `a""b` kept verbatim, and `1, "Smith, John"` gives the three cells `1`, `"Smith` and `John"` (4.7 rules 1, 3 and 4).
- **PS-8** Edge shapes, each renders: `header_only.csv` (`headers` set, `rows` empty, not `empty?`); `single_column.csv`; `blank_lines.csv` (blank lines, whitespace lines and `,,,` lines skipped, `rows_read` counts only real rows); `whitespace_only.csv`, `delimiters_only.csv` and `empty.csv` (0 bytes): `empty?` true, all counts 0, and `render` returns the empty-file image without raising; `single_row_data.csv` (`Coffee,4.50,2026-03-14`): no header, one data row.
- **PS-9** `cut_mid_char_utf8` and `cut_mid_char_utf16` (generated so that byte `max_input_bytes` falls inside a multi-byte character, read with a small `max_input_bytes`): no U+FFFD at the end of the last cell; `total_rows` nil.
- **PS-10** `header_row:` option on `numbers.csv`: `true` and `:auto` give the same headers; `false` gives `headers` nil and the header line as the first data row.

**Sanitizing and classification**

- **PS-11** `numbers.csv`: every cell listed as a number in section 6.1 is classified `:number` and its column is `:number` and right-aligned in the layout; text columns are left-aligned.
- **PS-12** `identifiers.csv` (columns of ZIP codes, MCC codes, card last-4, 23-digit reference numbers, phone numbers, dates, years): every column is `:text`.
- **PS-13** `formulas.csv` (`=HYPERLINK("http://example.com","x")`, `+cmd|' /C calc'!A0`, `@SUM(A1:A2)`, `-2+3`): `sample.rows` returns the exact strings; each layout `cell_text` is either the same string or, when the column is too narrow, a grapheme-cluster prefix of it ending in "…"; `-2+3` is `:text`.
- **PS-14** `markup.csv` (`<b>bold</b>`, `&amp;`, `<span foreground="red">x</span>`, `a & b`): `sample.rows` returns the literal strings, the layout's `cell_text` returns them or a prefix ending in "…" (never an unescaped or escaped variant), and render does not raise (proves `text.rb` escapes).
- **PS-15** `bidi.csv` (cells containing U+202E, U+202D, U+2066 to U+2069, U+200E, U+200F, U+061C, and a ZWJ emoji sequence): every bidi control removed; ZWJ kept; renders.
- **PS-16** `controls.csv` (C0 controls including ESC and BEL, DEL, U+0085, U+0090, VT, FF, U+2028, U+2029, tabs inside quoted cells, U+200B, an inner U+FEFF, a Zalgo cell with 50 combining marks): removed or replaced exactly per section 5.1; combining run cut to 8; renders. Plus generated `nul_after_window.csv` (a header, 2,500 rows of `1,2`, then a row `x<NUL>y,z` starting at byte 10,004, so the NUL is after the 8 KiB window; the test passes `max_rows: 3000` so the row is kept): not rejected, NUL removed, renders.
- **PS-17** `long_cell.csv` (generated: one 100,000-character cell, plus a 100,000-byte cell of multi-byte characters): renders in under 1 s; the cell is exactly 60 grapheme clusters ending in "…".

**Bounds and hostile input**

- **PS-18** Hostile shapes (generated, every row of section 7.3 at 2 MiB): `sample` completes in under 5 s each on CI; results are as listed (row counts, widths, and whether the field guard or a recovery rule applied).
- **PS-19** `huge.csv` (generated, 50 MB of realistic rows) read through a counting IO wrapper: the wrapper sees at most `max_input_bytes` bytes and only `read(length)` calls (no `rewind`, `seek`, `close`, `eof?`); `total_rows` nil; `rows_truncated?` true; render finishes within the timeout. On Linux, peak RSS growth measured in a child process (`VmHWM` from `/proc/self/status` after a warm-up render of `simple.csv`, then after the large render) is under 200 MB. The same file passed as a path string also reads at most `max_input_bytes`.
- **PS-20** `one_line_million_columns.csv` (generated: `x,` × 999,999 + `x\n`, exactly 2,000,000 bytes, so it fits in 2 MiB): parsed with `header_row: false` (with `:auto` the single all-text record would become the header, 4.10): the field guard stops the parse inside the line (4.5): `column_count` 12, `total_columns` between 57,345 and 81,921 (69,632 with csv's 8 KiB chunks), `rows_read` 1, `total_rows` nil, `columns_truncated?` true; `sample` finishes in under 1 s with peak RSS growth under 30 MB (Linux child process, as in PS-19); `render` returns an image or raises `TimeoutExceeded` within `timeout + 1` s, never hangs.
- **PS-21** Timeouts: `render(wide_long.csv, timeout: 0.001)` raises `TimeoutExceeded`; `sample(huge.csv, timeout: 0.001)` raises within 0.1 s; with an injected fake clock that expires at the N-th call, each stage in section 8.3 raises from its own checkpoint (the message names the stage), including a `:parse` checkpoint reached inside the `Feed` while `csv` is in the middle of one 2 MiB record (the `TimeoutExceeded` comes out of `CSV#shift` unchanged).
- **PS-22** Binary input: `png_renamed.csv`, `zip_renamed.csv`, `xlsx_renamed.csv`, `xls_renamed.csv`, `pdf_renamed.csv`, `gif_renamed.csv`, `jpeg_renamed.csv`, `gzip_renamed.csv` raise `UnreadableInput`; generated `nul_in_window.csv` (a NUL in the first 8 KiB) and `controls_heavy.bin` (8 KiB with 10% C0 controls, no NUL) raise `UnreadableInput`; a 4-byte `a,b\x1A` file does not.
- **PS-23** IO contract: a `StringIO` positioned at byte 10 is read from byte 10 and left open and unrewound; an IO-like object that only implements `read(length)` works; an IO whose `read` returns more bytes than asked is cut to the budget; an IO returning UTF-8 strings with non-ASCII text works (`.b`); a path to a directory raises `ArgumentError`, and so does a FIFO with no writer, within 5 seconds; a missing path raises `Errno::ENOENT`.
- **PS-24** Options: an explicit `encoding: "Windows-1252"` on a UTF-8 file decodes as Windows-1252 (mojibake expected, no error); `encoding: "nope"`, `"UTF-16"` (dummy) and `"BINARY"` raise `ArgumentError`; `delimiter: "\""`, `"\n"`, `"ab"` and `"§"` raise `ArgumentError`.

**Side effects, threads, determinism**

- **PS-25** No subprocesses and no libvips loaders: with the guards of section 9.2 installed, every checked-in fixture renders (or raises `UnreadableInput` for the binary ones).
- **PS-26** No network: in-process socket guards, plus the clean-child `$LOADED_FEATURES` check, plus (Linux CI) the `strace` check.
- **PS-27** No ImageMagick: empty `PATH`, `mini_magick`/`rmagick` unloadable, every fixture renders, `MiniMagick` undefined.
- **PS-28** Source scan: no forbidden API from section 9.1 appears in `lib/`.
- **PS-29** No stray writes: the directory checks of section 9.2 (and `strace` on Linux).
- **PS-30** Thread safety: 8 threads × 10 iterations over `simple.csv`, `wide_long.csv`, `numbers.csv`, `emoji_cjk.csv`, `quoted_newlines.csv`, `bidi.csv`, `windows1252.csv`, `markup.csv` give the serial digests; `CsvPreview.config` is frozen and `configure` replaces it.
- **PS-31** Property-based fuzz (seeded, at least 20,000 inputs per run, strings of 0 to 60 characters drawn from `a`, `é`, `漢`, `🙂`, `,`, `;`, `"` (twice as likely), `\n`, `\r\n`, `\r`, space, tab, NUL and U+0001, with random delimiter, `complete`, `max_rows`, `max_columns` and `max_cell_chars`). For each input, `Parser.normalize!` then `Records`:
  - never raises (no `CSV::MalformedCSVError` or anything else escapes);
  - bounds hold: at most `max_rows + 1` kept records, each with at most `max_columns` cells; every cell valid UTF-8 and at most `RAW_CAP` bytes; every kept width between 1 and `max_columns`; `count` is 0 exactly when `max_width` is 0; `complete` is false whenever the input was cut;
  - offsets are exact: at every record, `text.byteslice(pos, csv.line.bytesize) == csv.line` (a test-only check);
  - deterministic: a second run gives an equal result;
  - independent of chunking: the same result with the `Feed` forced to chunks of 1 to 9 bytes (a test-only `chunk_limit:`), and with the quote-free switch disabled;
  - the field guard keeps the bounds with `MAX_RECORD_FIELDS` forced to 1 to 6.
  Separately, decoding random byte strings with every supported encoding (auto and explicit) never raises and always yields valid UTF-8. The prototype passed more than 1,000,000 such inputs with identical result digests on csv 3.2.6 to 3.3.7 (measured).
- **PS-32** Determinism of parsing: `sample` on every fixture twice gives `==` samples. (Image determinism is tested in [`rendering.md`](./rendering.md).)
- **PS-33** Privacy of errors: an `UnreadableInput` or `TimeoutExceeded` raised on a file containing the marker `SECRET-7f3a` never includes that marker (or any input bytes) in its message.

**Parsing with `csv`**

- **PS-34** Cuts inside quoted fields: `cut_sweep` (generated: a 400-record export with quoted amounts and multi-line quoted memos containing commas and `""`), parsed as cut at every byte offset (a `Records` call on each prefix, `complete: false`). The generator keeps delimiters off the first line of every multi-line memo, and rows with such a memo get an unquoted amount, because 4.6 rule 3 re-reads a stray-quote record's first line without quoting and can then report extra columns for that one record (known and accepted, 4.6). No cut raises; `total_columns` never exceeds the full file's width for this shape; every complete record among the kept ones equals a strict `CSV.parse` of the whole file; `rows_read` is never below the number of complete records before the cut. With `max_rows: 2`, `rows_read` is never more than one above that number. Plus the single cases of 4.6: a cut inside a quoted field on the last line (rule 2), one long line of quoted fields cut inside a quote (rule 2, all cells correct).
- **PS-35** Field guard and runaway quotes: `stray_quote_wide.csv` (generated: `a,"x` then 349,525 rows of `1,2,3`): all 349,526 records counted, `total_rows` exact, `total_columns` 3 (4.6 rule 1 undoes the guard's stop). `"\n",` repeated over 2 MiB: the guard stops inside the record; `complete` false; no exception.
- **PS-36** `csv` versions: the Parser tests (PS-1 to PS-10, PS-18, PS-20, PS-31, PS-34, PS-35) run against csv 3.2.8 (the gemspec floor, in the Ruby 3.3 job) and against the newest csv release (Ruby 3.4 and 4.0 jobs), and both give the same results. A unit test asserts that `Feed` is not a `StringIO` and that `CSV.new(feed)` calls only `gets`, `eof?`/`eof`, `external_encoding` and `internal_encoding` on it.

## 12. Fixtures

Small fixtures are checked in under `test/fixtures/`. Large or hostile ones are generated at test time into a temporary directory by deterministic helpers (fixed seeds, fixed content), so they never bloat the repository. Binary fixtures are tiny real files, checked in.

| Fixture | Made how | Exercises |
|---|---|---|
| `simple.csv` | checked in | 3 columns × 4 rows with header; shared with other sections |
| `wide_long.csv` | checked in (about 297 KB, produced once by a deterministic script that is also checked in) | 31 columns × 1,284 rows; truncation counts; PS-1, PS-21 |
| `utf8_bom.csv`, `utf16le_bom.csv`, `utf16be_bom.csv`, `utf32le_bom.csv` | checked in | BOM detection and removal |
| `utf16le_nobom.csv` | checked in | parity heuristic |
| `windows1252.csv` | checked in | `é` (`E9`), `€` (`80`), `“ ”` (`93 94`), `’` (`92`), and one undefined byte `81` (becomes U+FFFD) |
| `invalid_utf8.csv` | checked in | valid `Café`, `Ünïcode`, `漢字` cells plus a stray `FF`, a truncated `E2 82` and an overlong `C0 AF`; more valid multi-byte characters than invalid bytes, so UTF-8 is chosen |
| `semicolon_decimal_comma.csv` | checked in | `;` with `-1.284,50` amounts and `14.03.2026` dates |
| `semicolon_2col_decimal.csv` | checked in | the `1,5;2,5` ambiguity |
| `tabs.tsv`, `pipes.csv` | checked in | other delimiters, with commas inside text |
| `quoted_newlines.csv` | checked in | embedded CRLF and LF, commas, `""` escapes, empty quoted field, CRLF line endings |
| `mixed_line_endings.csv` | checked in | CRLF, LF and lone CR record ends and blank lines in one file (4.2) |
| `ragged.csv` | checked in | rows of 2, 5 and 3 fields; trailing delimiters |
| `unbalanced_quote.csv` | checked in | stray-quote recovery (4.6 rule 3) |
| `junk_after_quote.csv` | checked in | 4.7 rules 1, 3 and 4: text after a closing quote, quotes inside unquoted fields, whitespace before and after quotes |
| `header_only.csv`, `single_column.csv`, `single_row_data.csv` | checked in | header detection edge cases |
| `blank_lines.csv`, `whitespace_only.csv`, `delimiters_only.csv`, `empty.csv` (0 bytes) | checked in | blank-record skipping and empty input |
| `numbers.csv` | checked in | every number form in section 6.1 |
| `identifiers.csv` | checked in | ZIP, MCC, last-4, long references, phones, dates, years |
| `formulas.csv`, `markup.csv`, `bidi.csv`, `controls.csv` | checked in | sections 5.1, 5.4, 5.5 |
| `emoji_cjk.csv` | checked in | grapheme clusters, CJK, RTL; shared with rendering |
| `png_renamed.csv`, `gif_renamed.csv`, `jpeg_renamed.csv` | checked in (tiny images, under 1 KB) | magic numbers |
| `zip_renamed.csv`, `xlsx_renamed.csv`, `xls_renamed.csv`, `pdf_renamed.csv`, `gzip_renamed.csv` | checked in (minimal valid files, under 2 KB each) | magic numbers |
| `long_cell.csv` | generated | 100,000-character cells; raw cap and truncation |
| `huge.csv` | generated (50 MB) | bounded read, memory |
| `one_line_million_columns.csv` | generated (2,000,000 bytes) | field guard, timeout |
| hostile shapes of section 7.3 | generated (2 MiB each) | time and memory bounds |
| `cut_sweep` | generated (400 records, about 41 KB, cut at every offset) | cuts inside quoted fields (4.6 rule 2), PS-34 |
| `stray_quote_wide.csv` | generated (2,097,155 bytes, 3 over 2 MiB, so PS-35 passes `max_input_bytes: File.size(path)`) | guard stop undone for a runaway quote (4.6 rule 1), PS-35 |
| `nul_in_window.csv`, `nul_after_window.csv`, `controls_heavy.bin` | generated | NUL and control-ratio rules |
| `cut_mid_char_utf8`, `cut_mid_char_utf16` | generated | trimming at the byte limit |
| random fuzz inputs | generated (seeded) | property-based Parser fuzz, decoding never raises (PS-31) |

## 13. Open questions

1. **Preamble lines.** Bank exports often start with lines such as `Account: ...` or a title before the real header. They are currently treated as the first record (and may be detected as the header). A heuristic (skip leading records whose width is much smaller than the modal width) is possible but not specified.
2. **Legacy multi-byte encodings.** Shift_JIS, GBK, Big5 and EUC-KR files decode as Windows-1252 mojibake in `:auto` mode; they work with an explicit `encoding:`. Is detecting them worth the complexity?
3. **Header-name hints for identifier columns** ("ZIP", "ID", "Phone", "MCC", "Last 4") would improve `CellKind` but are language-specific. Deferred.
4. **Footer and empty-state wording when `total_rows` is nil**, including the case where the first `max_input_bytes` are blank (`empty?` true but the file may continue): owned by [`rendering.md`](./rendering.md).
5. **TSV content type.** Should the Active Storage previewer pass `delimiter: "\t"` for `text/tab-separated-values` blobs instead of relying on sniffing? For [`active-storage.md`](./active-storage.md).
6. **fontconfig cache writes** on first use interact with the no-writes test; [`rendering.md`](./rendering.md) should confirm how bundled fonts are registered and whether any cache is written.
7. **Grapheme clusters versus code points** for `max_cell_chars`: this document chose grapheme clusters; [`rendering.md`](./rendering.md) must count the same way when it truncates further.
8. **Combining-mark cap of 8:** believed safe for real scripts (including Tibetan stacks); worth a check with native readers before 1.0.
9. **Removing LRM/RLM/ALM** trades a little mixed-direction fidelity for spoofing resistance. Revisit if RTL users report problems.
10. **Inline web requests:** the slowest hostile 2 MiB inputs (a million tiny records) cost about 1.5 s of CPU without YJIT and 0.8 s with it. Should the README recommend a smaller `max_input_bytes` (for example 512 KiB) for inline use?
11. **`Feed` ignoring the separator.** Answering `gets("\n", 8192)` with multi-line chunks relies on `csv`'s chunked scanner treating chunks as a byte stream, which holds on every version tested and is pinned by PS-31 and PS-36. If a future `csv` breaks it, the fallback is to honour the separator (`StringIO#gets(separator, limit)`), about 1.6 times slower on tiny records. Worth raising upstream as a documented guarantee?
12. **Whitespace before an opening quote** now leaves the quote literal (4.7 rule 4), as RFC 4180 and Excel do, where the tokenizer used to skip the whitespace. Revisit if hand-written files with `, "..."` turn out to be common among adopters.

## 14. Proposed changes to the overview

> **Status: applied** to the overview on 2026-11-15 (items 2 to 7). Kept below for the reasoning.
>
> **Item 1 withdrawn.** An earlier draft proposed dropping `csv` from the runtime dependencies in favour of a hand-written tokenizer. It was decided on 2026-11-15 to parse with Ruby's `csv` library for trust and maintainability (overview section 14), and the overview keeps `csv` as a runtime dependency. Section 4 specifies how the Parser bounds and recovers around it; the gemspec line is in 4.13.

1. *(Withdrawn; see above.)*
2. **Restrict `delimiter`** (section 9.2 table): replace "any single character is accepted" with "any single ASCII character other than `\"`, CR, LF or NUL; anything else raises `ArgumentError`". `"` is the quote character, CR and LF are rewritten by normalisation (4.2), and the gem's own byte-level steps (`String#count` in the field guard and blank checks) assume a one-byte delimiter, even though `csv` accepts longer `col_sep` values. Non-ASCII delimiters are vanishingly rare.
3. **Clarify `Sample` strings** (section 9.3): replace "Strings are cleaned (decoded, sanitised, not yet truncated for display)" with "Strings are cleaned (decoded and sanitised) and cut to at most `max_cell_chars` grapheme clusters, the last being "…" when the cell was longer. They are not yet fitted to column widths." Also say that `rows` are padded with `""`.
4. **Clarify `column_count` and `total_columns`** (section 9.3): `column_count` is "the widest of the header and the shown rows, at most `max_columns`"; `total_columns` is "the widest row seen in the bytes read, ignoring trailing blank fields". Without the trailing-blank rule, Excel's trailing commas would inflate both.
5. **Clarify `total_rows`** (section 9.3): it is `nil` when the source was not fully read; an IO source exactly `max_input_bytes` long also reports `nil` (confirming end of file would need one more byte). And `empty?` describes the bytes read: it can be true while `total_rows` is `nil`.
6. **State the non-input errors** (section 9.5): "Invalid options (an unknown, dummy or binary encoding, a bad delimiter, non-positive limits) raise `ArgumentError`. Problems opening a path raise the usual `SystemCallError` (for example `Errno::ENOENT`). Neither is a `CsvPreview::Error`. Error messages never include input content."
7. **State the timeout guarantee precisely** (section 9.2 `timeout` row or section 7): "Checked cooperatively at checkpoints; a single step that cannot be interrupted (notably the final image encode, which is bounded by the pixel caps) can overrun by its own duration. A blocking `read` on a caller-supplied stream cannot be interrupted."

---

## Appendix A: reference Parser core

`Parser.normalize!` and `Parser::Records` implement sections 4.2 to 4.8 exactly; sniffing (4.9), header detection (4.10) and building the `Sample` (4.11) sit on top. This is the prototype that produced the measurements in this document, and it passed the property fuzz test of PS-31 (more than 1,000,000 inputs) with identical result digests on csv 3.2.6, 3.2.8, 3.2.9, 3.3.0, 3.3.2, 3.3.5 and 3.3.7. `chunk_limit:` exists for tests only. `deadline` is the per-call `Deadline` (section 8).

```ruby
require "csv"
require "stringio"

module CsvPreview
  class Parser
    # Rewrites line breaks in place: CRLF and lone CR become LF, then runs of LF
    # collapse to one. Display-equivalent (section 4.2).
    def self.normalize!(text)
      text.tr!("\r", "\n")
      text.squeeze!("\n")
      text
    end

    # Runs Ruby's csv library over normalised text, inside the gem's bounds.
    class Records
      MAX_RECORD_FIELDS = 65_536 # field guard, section 4.5
      CHECK_EVERY       = 1_024  # rows between deadline checks (every csv read is checked too)
      QUOTE             = '"'
      LF                = 0x0A
      NOT_LF            = /[^\n]/
      BLANK             = " \t\n"

      RawCell = Struct.new(:text, :capped)
      Result  = Struct.new(:kept, :widths, :count, :max_width, :complete, :too_wide, :recovered,
                           keyword_init: true)

      # The IO that csv reads. Deliberately not a StringIO: csv reads a StringIO
      # whole and runs its regexes over one long string, but reads any other IO
      # in chunks of at most 8 KiB (section 4.3).
      class Feed
        def initialize(text, base, owner, guard:, chunk_limit: nil)
          @io = StringIO.new(text)
          @base = base               # offset of text[0] in the parser's text
          @owner = owner
          @guard = guard
          @chunk_limit = chunk_limit # tests only: forces tiny chunks
          @stopped = false
        end

        # csv calls gets("\n", 8192). Up to `limit` bytes are returned whatever the
        # separator; csv's chunked scanner treats chunks as a byte stream.
        # StringIO#gets never splits a character.
        def gets(_separator, limit)
          return nil if @stopped
          @owner.checkpoint
          limit = [limit, @chunk_limit].min if @chunk_limit
          chunk = @io.gets(nil, limit) or return nil
          @stopped = @guard && @owner.too_wide?(chunk, @base + @io.pos)
          chunk
        end

        def eof? = @stopped || @io.eof?
        alias_method :eof, :eof?
        def external_encoding = Encoding::UTF_8
        def internal_encoding = nil
      end

      # text: normalised UTF-8 text (not modified). complete: the Reader read the
      # whole source. keep_rows: non-blank records to keep (max_rows + 1).
      # kept_only: stop once keep_rows records are kept (the sniffer).
      def initialize(text, complete:, delimiter:, keep_rows:, keep_columns:, raw_cap:, deadline:,
                     kept_only: false, chunk_limit: nil)
        @text = text
        @complete = complete
        @delimiter = delimiter
        @keep_rows = keep_rows
        @keep_columns = keep_columns
        @raw_cap = raw_cap
        @deadline = deadline
        @kept_only = kept_only
        @chunk_limit = chunk_limit
      end

      def call
        @end = @text.bytesize
        @last_quote = @text.byterindex(QUOTE)
        @kept = []
        @widths = []
        @count = @max_width = @rows_seen = @fields = 0
        @too_wide = @recovered = false
        catch(:enough) { parse }
        Result.new(kept: @kept, widths: @widths, count: @count, max_width: @max_width,
                   complete: @complete, too_wide: @too_wide, recovered: @recovered)
      end

      def checkpoint = @deadline.check!(:parse)

      # Feed callback. Counts delimiters since the last row csv returned (quoted
      # ones too, so it over-counts). Past the guard, csv's input ends here.
      def too_wide?(chunk, pos)
        @fields += chunk.count(@delimiter)
        return false if @fields <= MAX_RECORD_FIELDS
        @stop ||= [@end, @complete, @too_wide]
        @end = pos if pos < @end
        @complete = false
        @too_wide = true
        true
      end

      private

      def csv_options(quoting)
        { col_sep: @delimiter, row_sep: "\n", quote_char: (QUOTE if quoting),
          liberal_parsing: true, skip_blanks: true }
      end

      # Section 4.6: at most one stray-quote recovery, then one terminal pass.
      def parse
        start = 0
        stray_done = false
        while start < @end
          @stop = nil
          x = parse_from(start) or return
          # csv raised CSV::MalformedCSVError: the record at offset x has a quote
          # that is still open where csv's input ended.
          @recovered = true
          if @stop && !stray_done
            @end, @complete, @too_wide = @stop # the guard caught a runaway quote, not a wide record
          elsif @stop || (!@complete && cut_tail?(x))
            parse_string(@text.byteslice(x, @end - x) + QUOTE, x, quoting: true, guard: false)
            return
          end
          if stray_done
            parse_string(@text.byteslice(x, @end - x), x, quoting: false)
            return
          end
          stray_done = true
          lf = @text.byteindex("\n", x)
          stop = lf && lf < @end ? lf + 1 : @end
          parse_string(@text.byteslice(x, stop - x), x, quoting: false)
          start = stop
        end
      end

      # The byte limit cut record x, as far as the gem can tell: x is past the
      # kept records, or x starts on the last line read.
      def cut_tail?(x)
        lf = @text.byteindex("\n", x)
        @count >= @keep_rows || lf.nil? || lf >= @end - 1
      end

      # Parses @text[start...@end] with quoting on. Returns nil when csv finished,
      # or the offset of the record csv rejected.
      def parse_from(start)
        @fields = 0
        feed = Feed.new(@text.byteslice(start, @end - start), start, self,
                        guard: true, chunk_limit: @chunk_limit)
        csv = CSV.new(feed, **csv_options(true))
        pos = start
        while (row = csv.shift)
          pos = skip_blank_lines(pos) + csv.line.bytesize
          add(row)
          next unless @last_quote.nil? || pos > @last_quote
          # No quote character is left: quote-free mode gives the same rows, faster.
          parse_string(@text.byteslice(pos, @end - pos), pos, quoting: false) if pos < @end
          return nil
        end
        nil
      rescue CSV::MalformedCSVError
        skip_blank_lines(pos)
      end

      # A recovery or quote-free pass over a separate string. csv has nothing to
      # reject here (no quotes, or the open quote was closed); if it ever does,
      # the rest is dropped and the counts become lower bounds.
      def parse_string(str, base, quoting:, guard: true)
        @fields = 0
        feed = Feed.new(str, base, self, guard: guard, chunk_limit: @chunk_limit)
        csv = CSV.new(feed, **csv_options(quoting))
        while (row = csv.shift)
          add(row)
        end
      rescue CSV::MalformedCSVError
        @complete = false
      end

      # csv skips empty lines (skip_blanks) and leaves them out of csv.line.
      def skip_blank_lines(pos)
        return pos unless @text.getbyte(pos) == LF
        @text.byteindex(NOT_LF, pos) || @end
      end

      def add(row)
        @fields = 0
        @rows_seen += 1
        checkpoint if (@rows_seen % CHECK_EVERY).zero?
        last = row.rindex { |f| f && f.count(BLANK) != f.bytesize }
        return unless last # blank record: not kept, not counted
        width = last + 1
        if @count < @keep_rows
          @kept << row.first(@keep_columns).map { |f| cell(f) }
          @widths << [width, @keep_columns].min
        end
        @max_width = width if width > @max_width
        @count += 1
        throw :enough if @kept_only && @count >= @keep_rows
      end

      def cell(field)
        return RawCell.new("", false) if field.nil?
        return RawCell.new(field, false) if field.bytesize <= @raw_cap
        RawCell.new(field.byteslice(0, @raw_cap).scrub(""), true)
      end
    end
  end
end
```

## Appendix B: experiments

On Ruby 3.4.12 (csv 3.3.5 unless stated; strscan 3.1.2, ruby-vips 2.3.0, libvips 8.18.7) and Ruby 4.0.2, Apple M1 Pro, macOS, heavily loaded (timings are upper bounds). Earlier `csv` versions were installed into a scratch `GEM_HOME` and loaded with `-I`.

| Question | Result |
|---|---|
| Which csv does Ruby 3.3 ship? | 3.2.8, a default gem (Ruby 3.3.0 NEWS; `lib/csv/version.rb` on `ruby_3_3`). Ruby 3.4 and later: bundled gem (3.3.5 in the installations used). Newest release: 3.3.7. |
| Does `CSV` with `liberal_parsing` survive an unclosed quote? | No: `MalformedCSVError: Unclosed quoted field`; iteration stops after the rows before it. Same on 3.2.6 to 3.3.7. |
| Mixed CRLF and LF? | Raises `Unquoted fields do not allow new line`, with or without `liberal_parsing`. A lone CR in an unquoted field raises the same. |
| `"foo"bar`, `foo"bar`, `"a,b" c`, `a""b`, `"a" ,b`, ` "a",b` with `liberal_parsing`? | Kept as `"foo"bar`, `foo"bar`, `"a,b" c`, `a""b`, `"a" ` and ` "a"` (4.7). Identical on 3.2.6 to 3.3.7. |
| `strip`? | `strip: " "` skips whitespace before quotes but also turns `"Big" Bob's` into `"Big"Bob's` and silently drops whitespace-only lines (not in `csv.line`). `strip` with more than one character raises `ArgumentError`; `strip: true` with a tab delimiter raises. |
| `max_field_size` on a 2 MiB field? | Raises instead of truncating. |
| Errors raised with normalised text and liberal parsing | 100,000 random inputs (20,000 each on csv 3.2.6, 3.2.8, 3.3.0, 3.3.5, 3.3.7): only `Unclosed quoted field`. Re-parsing the rest with `quote_char: nil` never raised. |
| `csv.line` | The raw text of the record, line break included; empty lines skipped by `skip_blanks` are not included. Offsets rebuilt from it matched the text on every fuzz input. |
| Greedy regex memory (`StringScanner#scan` over 2 MiB) | `[^",\n]+`, `[^"]+`, `"+`, `[^\n]+`: +99 to +100 MB each, on Ruby 3.4.12 and 4.0.2. Lazy `[^",\n]+?`: no growth. |
| `CSV` over a String, 2 MiB shapes | One field: +99 MB; one quoted field: +98 MB; only `"`: +100 MB; stray quote then rows: +94 MB; unclosed quote then letters with a recovery pass: +202 MB; 1,000,000 fields in one line: +91 MB, 0.79 s; 2,097,152 empty fields: +67 MB, 1.37 s; 2 MiB of LF: 1.56 s. |
| What `csv` calls on a non-StringIO input | `gets("\n", 8192)`, `eof?` (and `respond_to?(:eof)` from 3.3.5, `:eof?` before), `external_encoding`, `internal_encoding`. Same set on all seven versions. |
| `StringIO#gets(sep, limit)` and `gets(nil, limit)` | Extend past `limit` to the end of a character; never return invalid UTF-8. |
| An exception raised inside `gets` | Propagates out of `CSV#shift` as the same class (csv 3.2.6, 3.2.8, 3.2.9, 3.3.0, 3.3.2, 3.3.5, 3.3.7). |
| `Feed` versus String input | Identical results (fuzz, chunks of 1 to 9 bytes); growth for the shapes above falls to 1 to 22 MB. |
| `Feed` chunks: one line per `gets` versus 8 KiB blocks | 1,048,576 one-character rows: 3.70 s versus 2.35 s; with YJIT 2.27 s versus 1.33 s (load average about 60). |
| `quote_char: nil` versus `'"'` (shift only) | 2.4 to 3.4 times faster without YJIT, 1.7 to 3.4 with it. |
| Field guard | 1,000,000 fields in one line: stops at 69,632 fields, +6 MB, 0.06 s. |
| Byte-limit sweep (4.6) | 41,641 cuts of a 400-record export with multi-line quoted memos: no exception, never wider than the file, kept complete records always correct; 396 cuts over-counted rows, all inside multi-line memos among the first 21 records. On csv 3.2.8, a sample of 5,949 cuts gave the same picture. |
| Prototype on the 7.3 shapes | 0.003 to 1.47 s (0.003 to 0.84 s with YJIT), growth 0 to 20 MB; identical counts on csv 3.2.8 and 3.3.5. |
| Property fuzz of the prototype (PS-31 shape) | More than 1,000,000 inputs over all runs; never raised; identical digests on csv 3.2.6 to 3.3.7 and on Ruby 4.0.2. |
| Delimiter sniffer and header detector prototypes | All cases listed in 4.9 and 4.10 behave as stated (sniffer re-run on the `csv`-based parser). |
| Features loaded by `require "csv"` | `forwardable`, `date`, `time`, `English`, `stringio`, `strscan` and csv's own files; none of `socket`, `net/*`, `open-uri`, `open3`, `resolv`. |
| `scrub` behaviour | One U+FFFD per maximal invalid subsequence; overlong and surrogate encodings give one per byte. |
| Windows-1252 undefined bytes | Plain `encode` raises `UndefinedConversionError`; `undef: :replace` gives U+FFFD. |
| UTF-16 odd byte, lone surrogate, UTF-32 out of range | All become U+FFFD with `invalid: :replace`. |
| Decoding fuzz (20,000 random strings × 8 encodings) | No exception, always valid UTF-8. |
| Transcoding 2 MiB | Windows-1252 0.02 s (worst case grows 3x), UTF-16LE 0.01 s, UTF-8 validation 0.006 s. |
| Appending UTF-8 non-ASCII to a BINARY buffer | Raises `Encoding::CompatibilityError` (hence `chunk.b`). |
| `IO#read(n)`, `StringIO#read(n)` encoding | BINARY. |
| BOM-less UTF-16 NUL parity | ASCII CSV: 0.00 / 1.00; Japanese CSV: 0.00 / 0.60; all-CJK text: 0.00 / 0.00; random bytes: about 0.01. |
| Bounded read of a 50 MB file | Exactly 2,097,152 bytes in 32 calls; read plus parse 0.25 s; +11 MB RSS. |
| `\p{Bidi_Control}` in Ruby | Supported, matches exactly the 12 characters listed in 5.1 (written out explicitly anyway). |
| Unicode version | 15.0 (grapheme segmentation via `each_grapheme_cluster`). |
| Subprocess guards | Catch `system`, `Kernel.system`, backticks, `%x()`, `spawn`, `Process.spawn`, `IO.popen`, `Open3.capture2`, `exec`, `fork`, `open("\|cmd")`. |
| Features loaded by `require "vips"` | 52 files, none of `socket`, `net/*`, `open-uri`, `open3`, `resolv`, `uri`, `timeout`. |
| libvips defaults | Operation cache 100 ops / 100 MB / 100 files; concurrency 8 on this machine. |
| `Timeout.timeout(0.02)` around a 0.18 s libvips encode | Raised only after 0.18 s, when the C call returned. |
| `Vips::Image.text` with an unescaped `&` | `Vips::Error: text: invalid markup in text`. |
| `Vips::Image.text` with a NUL | `ArgumentError: string contains null byte` (raised by ruby-vips). |
| CellKind on the section 6.1 examples | All classified as listed; slowest adversarial 40-character input 17 µs. |
