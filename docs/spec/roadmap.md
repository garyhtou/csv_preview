# Roadmap: after the MVP

Ideas designed or discussed during the spec, deliberately left out of the MVP to keep it small. Each entry says what it is, why it is useful, and what the MVP must already do so it can be added later without restructuring.

## Themes

### Grid (spreadsheet-like)

Row numbers in a gutter, a full light grid, a bold header, and slightly shorter rows, so more columns and rows fit. As a thumbnail it is the most recognisable of the three looks, because gridlines and the row-number gutter survive heavy downscaling. It suits file managers and apps whose users think in spreadsheets.

- Mockup: [`../design/mockups/mock-grid-spreadsheet.jpg`](../design/mockups/mock-grid-spreadsheet.jpg)
- Tokens: [`../design/mockups/grid.tokens.json`](../design/mockups/grid.tokens.json)

### Card (document-like)

The filename as a title with the row and column counts underneath, and the table inside a rounded card on a tinted background, with heavier rules above and below the table. It is the most polished as a standalone image (an email, a chat message, a social card), but its frame wastes space inside apps that already frame thumbnails, and it shows the fewest rows and columns.

- Mockup: [`../design/mockups/mock-report-card.jpg`](../design/mockups/mock-report-card.jpg)
- Tokens: [`../design/mockups/report.tokens.json`](../design/mockups/report.tokens.json)

**What the MVP must do so these fit later:** keep every colour and size in the `Theme` value object, and keep the painter free of hard-coded Ledger values. Following [`rendering.md`](./rendering.md) section 2.1, the MVP defines no theme members it does not draw; Grid and Card add their switches (row gutter, vertical rules, frame, title block) with defaults that leave Ledger unchanged. `theme:` already exists as an option with `:ledger` as its only value.

## Theme overrides

Let apps adjust tokens to match their brand without writing a theme from scratch, for example `CsvPreview.configure { |c| c.theme = CsvPreview::Theme::LEDGER.with(header_fill: "#FFF7ED") }`. Validation must reject values that would break bounds (font sizes, row heights) or fail to parse (colours).

## Title line

An optional line above the table with the filename and counts, for example "orders-2026.csv · 1,284 rows · 31 columns". At thumbnail size this title is often the only readable text, so it helps people recognise a file in a list. The Active Storage previewer would pass `blob.filename`. In the MVP the footer already carries the counts.

## Active Storage analyzer

`CsvPreview::ActiveStorageAnalyzer` adds `rows`, `columns`, `delimiter`, `encoding` and `headers` to `blob.metadata` when a CSV is analysed, so apps can show captions such as "1,284 rows · 31 columns" or validate an import before it starts. It would reuse `Reader` and `Parser` with the same bounds; when the file is larger than `max_input_bytes`, `rows` is absent rather than guessed.

## Command-line tool

`csv_preview path/to/file.csv -o preview.png [--format webp] [--max-rows 30]`, for trying the gem, generating README images, and debugging a file a user reported. The MVP may keep a development-only script under `bin/` for golden images.

## Translated footer text

Footer strings ("20 of 1,284 rows", "12 of 31 columns", "Empty file") through Rails I18n when it is loaded, with English defaults, plus locale-aware number formatting ("1.284" in German). The MVP keeps these strings in one place so translation is a small change.

## More input formats

XLSX, ODS and Numbers files as separate, optional readers that produce the same `Sample`, so the layout and painter are reused unchanged. Each needs its own safety review (ZIP bombs, XML entity expansion) and would be opt-in, never accepting `application/vnd.ms-excel` blobs that might be binary XLS by default.

## Dark theme

A dark variant of each theme. Active Storage stores one preview image per file, so a dark image only helps apps that render their own previews with `CsvPreview.render`, or that store two previews themselves.
