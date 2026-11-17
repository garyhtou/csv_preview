# Changelog

All notable changes to csv_preview are recorded here. The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and csv_preview follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html): before 1.0, a breaking change bumps the minor version and its entry includes an upgrading note.

Rendered pixels are not part of the API. Any release may change how previews look, and its entry says so when it does. Existing Active Storage previews keep their old look until they are regenerated (see [Regenerating previews](https://github.com/garyhtou/csv_preview#regenerating-previews)).

## [Unreleased]

## [0.1.0] - 2026-11-17

### Added

- `CsvPreview.render(source, **options)` renders the first rows of a CSV or TSV file, or of any IO-like object, as a PNG, JPEG or WebP image in the Ledger look: Inter, a tinted header band, rules between rows, numbers right-aligned in tabular figures with a true minus sign, a fade for columns that do not fit, and a footer that says what was left out. A String or Pathname source is always a path.
- `CsvPreview.sample` reads and cleans the cells without rendering (and without libvips), returning a `CsvPreview::Sample`. `CsvPreview.layout` returns the `CsvPreview::Layout` for debugging and tests; its shape may change before 1.0.
- Options, per call or global through `CsvPreview.configure`: `max_input_bytes`, `max_rows`, `max_columns`, `max_cell_chars`, `max_width_px`, `max_height_px`, `scale`, `timeout`, `header_row`, `delimiter`, `encoding`, `format`, `theme` and `font`.
- Detection of the encoding (UTF-8 with or without a byte order mark, UTF-16, UTF-32 and Windows-1252), the delimiter (comma, semicolon, tab or pipe) and the header row, with lenient parsing of malformed, ragged and unbalanced input through Ruby's `csv` library.
- `CsvPreview::ActiveStoragePreviewer` for Rails 7.2 and newer: makes CSV and TSV attachments work with `preview`, `representation`, `previewable?` and preprocessed variants; reads only the first `max_input_bytes` of each blob with a ranged read; always produces PNG; and turns csv_preview's errors into `ActiveStorage::PreviewError`. Opt-in automatic registration with `config.csv_preview.register_previewer = true`.
- `CsvPreview.text_supported?` and `CsvPreview::ActiveStoragePreviewer.text_supported?` for health checks. The gem loads, and `sample` works, without libvips.
- Bounds for untrusted input: at most 2 MiB read by default, a cooperative `timeout` (5 seconds by default), capped image size, and no subprocesses, network, `eval`, ImageMagick, image decoders or file writes, each proved by a named test.
- `CsvPreview::UnreadableInput`, `CsvPreview::TimeoutExceeded` and `CsvPreview::RenderFailed`, all `CsvPreview::Error`. Messages never include input content, and each one links the README section that explains the fix.
- Bundled Inter 4.1 Regular and SemiBold fonts under the SIL Open Font License 1.1, and greyscale text antialiasing on every host.
- An integration guide for AI coding agents, packaged with the gem as an Agent Skill in `skills/csv-preview/SKILL.md`.

[Unreleased]: https://github.com/garyhtou/csv_preview/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/garyhtou/csv_preview/releases/tag/v0.1.0
