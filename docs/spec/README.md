# csv_preview: specification

- **Status:** accepted; implemented in 0.1
- **Started:** 2026-11-15
- **Scope of this document:** the overview, the pinned public contract, and the MVP cut. Detailed behaviour lives in the section documents:
  - [`parsing-and-safety.md`](./parsing-and-safety.md): reading untrusted input, encodings, delimiters, lenient parsing, cell sanitising, resource bounds, timeouts, thread safety.
  - [`rendering.md`](./rendering.md): the Ledger theme, layout algorithm, typography, fonts, image output.
  - [`active-storage.md`](./active-storage.md): the Active Storage previewer, registration, Rails integration, and recipes.
  - [`branding-and-discoverability.md`](./branding-and-discoverability.md): positioning, README, visual identity, metadata for search engines and AI agents, trust signals, and launch.
  - [`roadmap.md`](./roadmap.md): what comes after the MVP (more themes, analyzer, CLI, i18n).

## 1. What it is

`csv_preview` is a Ruby gem that turns a CSV file into a clean, readable preview image (PNG by default) and plugs into Active Storage as a previewer, so a CSV attachment gets a thumbnail and a detail image the same way images, PDFs and videos already do.

It draws real text with libvips and Pango. It does not need LibreOffice, a headless browser, ImageMagick, or any network service.

## 2. Why it exists

Rails apps increasingly let people upload CSV files, but Active Storage only ships previewers for PDFs and videos. The options today are all poor:

- **LibreOffice** (via a hand-rolled previewer; Basecamp's maintained `activestorage-office-previewer` is built for Office formats and does not accept CSV): a very large install with a [long list of security advisories](https://www.libreoffice.org/about-us/security/advisories/), a subprocess per preview, and slow to start, all run against untrusted files.
- **Headless browsers or wkhtmltoimage:** heavy, and wkhtmltoimage is unmaintained.
- **Cloud conversion APIs:** send private files to a third party, cost money, and need the network at render time.
- **Existing gems:** the only CSV-to-image gem found (`table2png`) dates from 2014 and depends on wkhtmltoimage. No maintained gem renders CSV to any image format, and none provides an Active Storage previewer. Details: [`../research/README.md`](../research/README.md).

Meanwhile libvips is already in most Rails apps' bundles (Rails' default variant processor since 7.0), and its text rendering through Pango is good enough to produce genuinely beautiful tables.

## 3. Use cases

These shape the defaults. Each one treats the CSV as **untrusted input**: anyone who can upload a file controls its bytes.

1. **Expense and receipt management.** People attach CSV exports as receipts: card or bank statement exports, online order histories, invoices and expense sheets saved from Excel or Google Sheets. A reviewer glances at a thumbnail in a list to recognise "that is the order export", then opens a detail view to read the first rows (merchant, date, amount, line items). They never need the whole file in the image; they can download the original. Files are often wide (20+ columns) and long (thousands of rows), with currency amounts, dates and long descriptions. Previews are generated in a background job at upload time, and sometimes inline in a web request.
2. **Chat, comments and helpdesk attachments.** A CSV dropped into a conversation shows a preview card, like an image or PDF does, instead of a generic file icon.
3. **File and document managers.** Grid views show a recognisable thumbnail for CSV files alongside other file types.
4. **Import flows.** Before importing, an app shows "here is what we read from your file". The gem's `sample` API gives the app the cleaned first rows to render as HTML, and the image can go into a confirmation email.
5. **Exports and notifications.** "Your export is ready" emails or chat messages include a picture of the first rows.
6. **Plain Ruby.** Scripts and bots that need a picture of a table, with no Rails involved.

## 4. Goals, non-goals, anti-goals

**Goals, in priority order:**

1. **Drop-in Active Storage previewer.** One line of configuration makes `blob.preview`, `blob.representation`, `previewable?`/`representable?` and preprocessed variants work for CSV and TSV blobs.
2. **Beautiful by default.** The default Ledger look (section 8) should look designed, not like a spreadsheet screenshot, at full size and still read as a table in a thumbnail.
3. **Safe and bounded on hostile input.** Bounded bytes read, bounded work, bounded memory, bounded time, no evaluation of cell contents, no markup injection.
4. **Usable without Rails.** `CsvPreview.render` works in any Ruby process.
5. **Few, ordinary dependencies.** Runtime dependencies are `csv` (Ruby's standard CSV library, a bundled gem since Ruby 3.4) and `ruby-vips`. Parsing uses `csv` with the recovery rules in [`parsing-and-safety.md`](./parsing-and-safety.md).
6. **Easy to find and easy to trust (secondary).** Humans searching the web and AI agents choosing a gem should both find `csv_preview` for the questions it answers, and see clear evidence that it is safe, maintained and well tested. Details in [`branding-and-discoverability.md`](./branding-and-discoverability.md).

**Non-goals:** XLS, XLSX, ODS or Numbers files (possible later as separate inputs); previewing more than the first screen of data; multi-page output; charts; formula evaluation; reproducing cell styling from the source file; HTML view components; dark-mode images (a preview image is one static file).

**Anti-goals** (failing any of these is a failure even if everything else works):

- Shelling out to any program, or touching the network, at render time.
- Using ImageMagick or MiniMagick in any form.
- Reading a whole large file into memory, or doing work proportional to the file's size beyond `max_input_bytes`.
- Interpreting cell text: formulas, markup or bidi control characters must never change what is drawn beyond being shown literally (or stripped, for controls).
- A preview that looks like a 2005 spreadsheet screenshot.

## 5. Environment and constraints

- **Ruby** 3.3 or newer. CI covers 3.3, 3.4 and 4.0.
- **Rails / Active Storage** 7.2 or newer, optional. The core (`render`, `sample`, `layout`) never requires Rails. CI covers Rails 7.2, 8.0 and 8.1. (7.1 is not supported: `ActiveStorage::PreviewImageJob` only arrived in 7.1.4, and 7.1 is out of support.)
- **libvips 8.12 or newer** with Pango text support (Pango 1.44 or newer); 8.14.2 or newer recommended. CI runs Ubuntu 22.04 (libvips 8.12), Ubuntu 24.04 (8.15) and macOS Homebrew's current libvips. Feature-by-feature reasons are in [`rendering.md`](./rendering.md) section 9.
- **ruby-vips 2.2.2 or newer** (below 3). 2.2.1 added `Vips.block_untrusted`, but it cannot load on Ruby 4.0 unless the app's bundle has `logger`; 2.2.2 is the first version that works on every supported Ruby, and CI has a job pinned to it ([`rendering.md`](./rendering.md) section 9).
- **`csv` 3.2.8 or newer** (below 4): the version Ruby 3.3 ships as a default gem. CI runs the Parser tests on both ends of the range ([`parsing-and-safety.md`](./parsing-and-safety.md) 4.13).
- **Loads without libvips.** `require "csv_preview"` does not load ruby-vips (which raises `LoadError` when the libvips library is missing). `CsvPreview::Text` requires it on first use (the first `render`, `layout`, `text_supported?` or font warm-up). Without libvips, `require` and `sample` work, `text_supported?` is false, `render` and `layout` raise `RenderFailed` naming the missing library, and the previewer's `accept?` is false with one warning. Apps whose web servers never render (previews run in jobs) still boot.
- **Works with `Vips.block_untrusted(true)`.** Recent Rails (7.2.3.2, 8.0.5.1, 8.1.3.1 and later) and `image_processing` 2.x turn this on for the whole process. The gem only uses operations that stay allowed (text, compositing, PNG/JPEG/WebP savers), and input bytes never reach a libvips image decoder.
- **Must work where ImageMagick is locked down** to a few raster coders (for example only JPEG, PNG, GIF and WebP, with `TEXT`, `LABEL`, `SVG`, `MVG`, `PS`, `PDF` and all delegates denied). The gem itself never uses ImageMagick; the app's variant processor (vips or mini_magick) later resizes the PNG the gem produces, so the preview must be a raster format the app allows. PNG is the default for that reason.
- **No subprocesses, no network, no `eval`**, and no writes outside temporary files that are cleaned up.
- **Thread-safe** under Puma and Sidekiq (several threads rendering at once).

## 6. Prior art and alternatives considered

| Approach | Why not |
|---|---|
| LibreOffice (hand-rolled previewers, `docpdf`; `activestorage-office-previewer` targets Office formats, not CSV) | Very large install and attack surface, a subprocess per preview, slow to start. |
| Headless browser / wkhtmltoimage (`table2png`) | Heavy, subprocess; wkhtmltoimage is unmaintained. |
| Build an SVG, then rasterise it | Still needs libvips/Pango to measure text for column widths and truncation; adds an XML attack surface; many locked-down ImageMagick policies refuse SVG anyway. |
| Pure-Ruby pixel drawing (e.g. ChunkyPNG plus a font rasteriser) | No proper shaping, hinting or font fallback, so it cannot meet the "beautiful" goal; slow. |
| Prawn to PDF, then Rails' PDF previewer | Rails' PDF previewers shell out to poppler or mupdf; two conversions. |
| Paid cloud conversion APIs | Network at render time, cost, and private files sent to a third party. |
| **libvips + Pango, laid out in Ruby (chosen)** | Real typography with font fallback, already in most Rails bundles, thread-safe, no subprocess. |

## 7. Architecture

A pipeline of small, separately testable steps. Every step after parsing works on bounded data.

```
source (IO or path)
  -> Reader      bounded byte read, binary detection, encoding detection and transcoding
  -> Parser      delimiter sniffing, lenient CSV parsing, header detection, counting
  -> Sample      cleaned, sanitised cells (public, stable)
  -> Layout      cell kinds and alignment, measured column widths, truncation, footer text
  -> Painter     draws the Layout with libvips, encodes PNG/JPEG/WebP
  -> bytes
```

A `Deadline` object travels through every step so a render that runs past `timeout` raises `CsvPreview::TimeoutExceeded` at the next checkpoint (details in [`parsing-and-safety.md`](./parsing-and-safety.md)).

## 8. Visual design (decided)

- **Default theme: Ledger.** Inter, header band with semibold muted labels, rules between rows only, numbers right-aligned in tabular figures with a true minus sign, columns that do not fit fade out at the right edge, and a quiet footer stating what was left out. Mockup: [`../design/mockups/mock-ledger-default.jpg`](../design/mockups/mock-ledger-default.jpg). Exact tokens and the layout algorithm: [`rendering.md`](./rendering.md). Where `rendering.md` and the mockup token file differ, `rendering.md` wins (it darkens the header band to `#EEF0F3` so it survives thumbnails).
- **Grid** (spreadsheet-like) and **Card** (document-like) were designed and mocked too, and are recorded as future themes in [`roadmap.md`](./roadmap.md). Their mockups and token files are in [`../design/mockups/`](../design/mockups/). The code must keep theme values in data (a `Theme` object), not scattered through the painter, so those themes can be added without restructuring.
- Research behind the choice: [`../research/README.md`](../research/README.md).

## 9. Public API (pinned)

Section documents may refine behaviour but must not rename or remove anything here without updating this section.

```ruby
require "csv_preview"

png   = CsvPreview.render(source, **options)   # => String (binary image bytes)
data  = CsvPreview.sample(source, **options)   # => CsvPreview::Sample
plan  = CsvPreview.layout(source, **options)   # => CsvPreview::Layout (for debugging and tests)

CsvPreview.configure do |config|
  config.max_rows = 20
  config.previewer_content_types += ["text/x-csv"]
end
CsvPreview.config        # => CsvPreview::Configuration (the global defaults)
CsvPreview.text_supported?  # => true when libvips can draw text (delegates to CsvPreview::Text.supported?)
```

`CsvPreview::ActiveStoragePreviewer.text_supported?` exposes the same check for Rails health checks.

### 9.1 `source`

- An `IO`-like object responding to `read(length)` (File, Tempfile, StringIO, a socket-like stream). It is read **sequentially**, at most `max_input_bytes`, and is **never rewound, closed or fully read** by the gem. The caller owns it.
- A `String` or `Pathname` is always treated as a **path** to a file, which the gem opens read-only and closes.

### 9.2 Options

Every option can be passed per call or set globally with `CsvPreview.configure`. Per-call values win. Invalid values (an unknown option, a non-positive limit, a bad delimiter or encoding, or a value below a floor listed here) raise `ArgumentError` when the options are resolved, before any input is read.

| Option | Default | Meaning |
|---|---|---|
| `max_input_bytes` | `2_097_152` (2 MiB) | Bytes read from the start of the source. Nothing past this is read. |
| `max_rows` | `20` | Data rows shown (header not counted). |
| `max_columns` | `12` | Most columns kept and shown. Fewer are shown if they do not fit the width. |
| `max_cell_chars` | `60` | Characters kept per cell before measuring; longer cells end in "…". |
| `max_width_px` | `2048` | Cap on output width in pixels, not a target: the layout width is `min(1024 * scale, max_width_px)` and small tables produce narrower images. At least `160 * scale`. |
| `max_height_px` | `2600` | Cap on output height in pixels. At least `110 * scale`. |
| `scale` | `2` | Pixel density, an Integer from 1 to 4: all theme sizes are logical pixels multiplied by this. |
| `timeout` | `5` (seconds) | Wall-clock budget for one call, checked cooperatively at checkpoints (no `Timeout.timeout`). One step that cannot be interrupted, notably the final image encode (bounded by the pixel caps), can overrun by its own duration, and a blocking `read` on a caller-supplied stream cannot be interrupted. |
| `header_row` | `:auto` | `:auto`, `true` or `false`. |
| `delimiter` | `:auto` | `:auto` (sniffs `,` `;` tab `|`) or any single ASCII character other than `"`, CR, LF or NUL. |
| `encoding` | `:auto` | `:auto` or an encoding name (`"UTF-8"`, `"Windows-1252"`, ...). |
| `format` | `:png` | `:png`, `:jpeg` or `:webp`. The Active Storage previewer always produces PNG and ignores this. |
| `theme` | `:ledger` | Only `:ledger` in the MVP. |
| `font` | `nil` | `nil` uses the bundled Inter; a String names a system font family to use instead. |

Global-only settings (Active Storage): `previewer_content_types` (default `["text/csv", "text/tab-separated-values"]`). Rails settings are in [`active-storage.md`](./active-storage.md).

### 9.3 `CsvPreview::Sample` (stable)

An immutable value object describing what was read. Strings are cleaned (decoded and sanitised) and cut to at most `max_cell_chars` grapheme clusters, the last being "…" when the cell was longer. They are not yet fitted to column widths. Short rows are padded with `""`.

| Method | Type | Meaning |
|---|---|---|
| `headers` | `Array<String>` or `nil` | Header cells, `nil` when no header row was detected or requested. |
| `rows` | `Array<Array<String>>` | Up to `max_rows` data rows, each padded or cut to the kept column count. |
| `column_count` | `Integer` | The widest of the header and the shown rows, at most `max_columns`. |
| `total_columns` | `Integer` | The widest row seen in the bytes read, ignoring trailing blank fields (so Excel's trailing commas do not inflate it). |
| `total_rows` | `Integer` or `nil` | Data rows in the whole file if it was fully read within `max_input_bytes`; otherwise `nil` (unknown). An IO source exactly `max_input_bytes` long also reports `nil`. |
| `rows_read` | `Integer` | Data rows seen within the bytes read (a lower bound when `total_rows` is `nil`). |
| `rows_truncated?` / `columns_truncated?` | Boolean | Whether anything was left out. |
| `column_kinds` | `Array<Symbol>` | `:number` or `:text` per kept column. |
| `delimiter` | `String` | The delimiter used. |
| `encoding` | `String` | The source encoding detected or used. |
| `empty?` | Boolean | True when the bytes read have no non-blank cells (it can be true while `total_rows` is `nil`). |

### 9.4 `CsvPreview::Layout` (for debugging and tests; shape may change before 1.0)

Exposes at least: `sample`, `visible_columns` (Integer, fully visible columns), `columns` (each with `index`, `kind`, `align` (`:left`/`:right`), `width` in logical px (may be fractional), `width_px` and `x_px` in device px), `peek_column` (the partly visible column under the fade, or `nil`), `rows_shown`, `cell_text(row, col)` and `header_text(col)` (the exact display strings after sanitising and truncation; column letters when there is no header row), `footer_text` (String or `nil`), `message` (the empty-state text or `nil`), `width_px` and `height_px` (output pixel size), `scale`, `theme`, and `text_calls` (instrumentation for tests). The Painter reads further `@api private` members (`placements`, a list of `Layout::Placement` with `run`, `x`, `y` and `box`; `geometry`; per-cell placement lookups) that are not part of the contract. Exact meanings: [`rendering.md`](./rendering.md) section 6.11.

### 9.5 Errors

```
CsvPreview::Error < StandardError
  CsvPreview::UnreadableInput    # binary, undecodable, or not text at all (e.g. a PNG or ZIP renamed .csv)
  CsvPreview::TimeoutExceeded    # the call ran past `timeout`
  CsvPreview::RenderFailed       # libvips or font failure, or libvips lacks text support
```

Invalid options raise `ArgumentError`, and problems opening a path raise the usual `SystemCallError` (for example `Errno::ENOENT`); neither is a `CsvPreview::Error`. **Error messages never include input content.**

The Active Storage previewer converts every `CsvPreview::Error` into `ActiveStorage::PreviewError` (see [`active-storage.md`](./active-storage.md)).

**Empty input** (0 bytes, or only blank lines and whitespace) does **not** raise: `render` returns a small image saying the file is empty, and `sample.empty?` is true. That keeps uploads of empty files from failing background jobs.

## 10. Code layout (pinned)

```
lib/csv_preview.rb                         # public API: render, sample, layout, configure, config
lib/csv_preview/version.rb
lib/csv_preview/configuration.rb           # defaults, validation, merging per-call options
lib/csv_preview/errors.rb
lib/csv_preview/deadline.rb                # timeout checkpoints
lib/csv_preview/reader.rb                  # bounded read, binary detection, encoding
lib/csv_preview/parser.rb                  # delimiter sniffing, lenient parsing, header detection
lib/csv_preview/sanitizer.rb               # control and bidi characters, replacement chars
lib/csv_preview/cell_kind.rb               # number vs text classification
lib/csv_preview/sample.rb
lib/csv_preview/theme.rb                   # Theme value object + Theme::LEDGER
lib/csv_preview/text.rb                    # Pango markup escaping, measuring and drawing text via libvips
lib/csv_preview/layout.rb
lib/csv_preview/painter.rb
lib/csv_preview/active_storage_previewer.rb  # loaded only when Active Storage is present
lib/csv_preview/railtie.rb                 # loaded only when Rails is present
fonts/Inter-Regular.ttf, fonts/Inter-SemiBold.ttf, fonts/OFL.txt
test/fixtures/*.csv                        # see the fixture list in each section document
test/dummy/                                # minimal Rails app for the Active Storage tests
gemfiles/                                  # rails_7_2, rails_8_0, rails_8_1, no_rails, csv_floor (csv 3.2.8), common
skills/csv-preview/SKILL.md                # integration guide for AI coding agents (packaged)
llms.txt                                   # short index for AI tools
README.md, CHANGELOG.md, SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, LICENSE
docs/assets/                               # brand mark, hero and gallery images (not packaged)
bin/brand-images                           # development only: renders README and social images with the gem
.yardopts
.github/workflows/ci.yml, .github/workflows/release.yml, .github/dependabot.yml
```

## 11. MVP scope

**In the MVP (0.1):**

- Everything in sections 9 and 10; the Ledger theme; PNG, JPEG and WebP output; the Active Storage previewer with explicit and opt-in automatic registration.
- The acceptance tests in the section documents; CI on Ubuntu 22.04 and 24.04 and macOS, Ruby 3.3 to 4.0, Rails 7.2 to 8.1.
- The README, in this order: pitch, hero render, three-line Rails setup, gallery, installation (with libvips prerequisites for Ubuntu and macOS), Rails and plain Ruby usage, options, how it works, comparison table, security table linked to named tests, compatibility matrix, FAQ, and a section for AI coding agents. Exact wording and the reasons for each element: [`branding-and-discoverability.md`](./branding-and-discoverability.md) section 3.
- Trust and discoverability files: `SECURITY.md` (with a short threat model), `CHANGELOG.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `llms.txt`, `skills/csv-preview/SKILL.md`, YARD docs, the release workflow with RubyGems trusted publishing, Dependabot, the social preview and README images rendered by `bin/brand-images`, and `rake docs:check` (keeps the pitch and claims consistent across README, gemspec, `llms.txt` and the skill).

**After the MVP:** see [`roadmap.md`](./roadmap.md): Grid and Card themes, theme token overrides, an optional title line, an Active Storage analyzer for row and column counts, a command-line tool, translated footer text, and more input formats.

## 12. Packaging

- Gem name `csv_preview`, module `CsvPreview`. `spec.licenses = ["MIT", "OFL-1.1"]`: the code is MIT and the bundled Inter fonts are under the SIL Open Font License.
- Gemspec summary, description and metadata (`homepage_uri`, `source_code_uri`, `changelog_uri`, `documentation_uri`, `bug_tracker_uri`, `rubygems_mfa_required`) and the packaged file list are specified in [`branding-and-discoverability.md`](./branding-and-discoverability.md) sections 4.2 and 4.6.
- Runtime dependencies: `csv` and `ruby-vips`. No dependency on Rails, ImageMagick, MiniMagick, Chrome or LibreOffice.
- Bundles Inter Regular and SemiBold with the SIL Open Font License text.
- README and gallery images are composited by `bin/brand-images` from renders made on the pinned ubuntu-24.04 CI image (the golden environment), by a manually triggered workflow. Sample data may use real merchant names, as a real statement export would; people's names and card numbers stay fictional.
- Golden images rendered by the gem itself: `simple`, `wide_long`, `numbers`, `emoji_cjk` (also used in the README) and `statement` (the mockup's own data, the best regression check for the look).

## 13. Cross-section notes

Points where one section relies on another, collected so a builder sees them in one place.

- **Display strings vs data.** `Layout#cell_text` is the width-truncated display string and uses a true minus (U+2212) in `:number` cells. Tests that compare against raw input should use `CsvPreview.sample` or short text cells. ([`rendering.md`](./rendering.md) 6.11, [`parsing-and-safety.md`](./parsing-and-safety.md))
- **Cell kinds live in one place.** `CellKind`, the `Sanitizer` and `Sample` are specified in [`parsing-and-safety.md`](./parsing-and-safety.md); [`rendering.md`](./rendering.md) adds no classification of its own.
- **Font warm-up.** `CsvPreview::Text.warm_up!` registers the bundled fonts and checks they are active. The Railtie calls it after boot, only when the previewer is registered and the app has not set its own `font:` (an app that always passes `font:` never needs the bundled-font self-check), so the first preview job does not pay for it. On macOS the gem sets `PANGOCAIRO_BACKEND=fontconfig` when loaded, so apps should `require "csv_preview"` at boot (Bundler does this by default). ([`rendering.md`](./rendering.md) 5.3 and 5.4)
- **Empty states.** The wording for empty files, and for "no data in the first 2 MB" when `total_rows` is unknown, is in [`rendering.md`](./rendering.md) 6.9.
- **Greyscale text on every host.** The gem corrects libvips' subpixel (coloured-edge) text drawing on hosts whose fontconfig enables it, so output looks the same everywhere; the mechanism and its limits are in [`rendering.md`](./rendering.md) section 9, and it is why some strings cost two counted text calls (4.7, 10).
- **Tests and CI names.** Acceptance tests are named `test_<ID>_<description>` with the ID's dash as an underscore (`test_PS_5_delimiters`, `test_REN_9_footer_wording`), so the README's security table can be checked against the suite. The CI gemfiles are `gemfiles/no_rails.gemfile`, `rails_7_2`, `rails_8_0`, `rails_8_1`, `csv_floor` and `ruby_vips_floor`, sharing `common.gemfile` ([`active-storage.md`](./active-storage.md) 9.2). Golden comparison is exact only with `CSV_PREVIEW_GOLDEN=exact` on the pinned image ([`rendering.md`](./rendering.md) 11).
- **Showing previews crisply.** Previews are drawn at `scale` 2, so apps get the sharpest result displaying them at `width_px / scale` CSS pixels or smaller.

## 14. Decisions from the spec review (2026-11-15)

A review of these documents before the build flagged the points below, and building it settled a few more (marked "build decision"). Where a section document disagreed, it has been corrected to match.

- **Missing libvips:** the gem loads and `sample` works without libvips; only rendering needs it (section 5).
- **Bounded read in the previewer:** the previewer downloads at most `max_input_bytes`, the same bound the core reads, so a blob and the same file passed as a path give identical results ([`active-storage.md`](./active-storage.md) 3.4).
- **README images vs golden images:** both come from the pinned ubuntu-24.04 CI environment; `bin/brand-images` composites README images from those renders (section 12).
- **Theme members for future themes:** the MVP `Theme` holds only what Ledger draws; later themes add their switches with defaults that leave Ledger unchanged ([`rendering.md`](./rendering.md) 2.1, [`roadmap.md`](./roadmap.md)).
- **Sample data:** real merchant names are fine in mockups and README images; people and card numbers are fictional.
- **CSV parsing (decided 2026-11-15):** use Ruby's standard `csv` library rather than a hand-written tokenizer, for trust and maintainability. [`parsing-and-safety.md`](./parsing-and-safety.md) specifies how the gem bounds and recovers around it (unclosed quotes, mixed line endings, oversized fields).
- **Greyscale text correction (build decision):** libvips before 8.17.1 draws coloured fringes on hosts whose fontconfig enables subpixel rendering, including the pinned ubuntu-24.04 CI image. The gem detects this once per process at warm-up and recolours every run, so output is greyscale-antialiased everywhere, with emoji colours preserved by a second counted drawing; no process-global state is changed ([`rendering.md`](./rendering.md) section 9). This replaces the earlier assumption that server images do not need it.
- **ruby-vips floor (build decision):** `>= 2.2.2`, not 2.1 or 2.2.1: see section 5.
- **Gemfile names (build decision):** `gemfiles/rails_7_2.gemfile`, `rails_8_0`, `rails_8_1`, `no_rails`, `csv_floor`, `ruby_vips_floor` and the shared `common.gemfile`.
- **Ruby `csv` library details (build decision):** the gemspec says `csv >= 3.2.8, < 4`; `Gemfile.lock` is git-ignored, so Dependabot cannot propose in-range csv releases and the newest-csv CI jobs resolve the latest release on every run ([`parsing-and-safety.md`](./parsing-and-safety.md) 4.13).
- **Release environment (build decision):** the GitHub `release` environment is created with a `v*` tag deployment rule before the RubyGems pending publisher, and required reviewers wait until the repository is public ([`branding-and-discoverability.md`](./branding-and-discoverability.md) 5.4).
- **Security policy (decided 2026-11-15):** `SECURITY.md` makes no response-time commitment.
- **Definition of done for the MVP (decided 2026-11-15):** release-ready, not published. The build ends with a repository that is ready to make public and tag. Making it public, setting up RubyGems trusted publishing and MFA, uploading the social preview, enabling private vulnerability reporting and tagging 0.1.0 follow the checklist in [`RELEASING.md`](../RELEASING.md). The macOS CI job runs by hand for now; step 6 of that checklist switches it to run on every push.
