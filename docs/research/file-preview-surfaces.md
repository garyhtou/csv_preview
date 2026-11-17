
# How real file-preview surfaces render CSV and spreadsheet data

> Screenshots of third-party products described here were captured for private reference and are not included in this repository. Each section names or links the live source instead. Mockups we rendered ourselves are in [`../design/mockups/`](../design/mockups/).

Research for the CSV preview gem (renders a CSV to a static PNG/JPG/WebP preview: a ~300px thumbnail in lists, a ~1024px image in a detail modal). Gathered 2026-11-15. Every value marked "computed" was read from the live page with `getComputedStyle`. Values marked "source" come from the product's own open-source code or generated output. Everything else is read off a screenshot and says so.

All observations were made logged out, in light mode unless noted.

## Summary table

| Surface | Header treatment | Lines | Zebra | Numbers | Long text | "More data" cue | Metadata shown |
|---|---|---|---|---|---|---|---|
| GitHub | `#f6f8fa` band, 12px/600 | full grid `#d1d9e0` | no | left, proportional | nowrap, row stays 1 line | none (all rows, or "too large" banner) | lines, loc, size |
| GitLab | none (same as body) | full grid `#dcdcde` | no | left | wraps, tall rows | none | file size |
| Hugging Face | white, name 700 + dtype + mini histogram | full grid gray-200 | yes, gray-50 | right | 2-line clamp + ellipsis | pager + dashed rule | split + row count |
| Kaggle | type glyph + name, description, optional histograms | full grid `#d9d9d9` | no | left, monospace | wraps | internal scroll | "10 of 12 columns" |
| Datasette | pale blue band, 13px/600 | horizontal rules only `#d8e6f5` | no | right, tabular, muted | pre-wrap | pagination | "15 rows" title |
| Jupyter / pandas | bold, 1px rule under | rule under header only | yes, `#f5f5f5` | right (everything right) | n/a | `...` row and column + "193 rows × 6 columns" | caption |
| Google Sheets (pubhtml) | column letters + row numbers chrome | full grid rgba(0,0,0,.15) | no (user fills) | right | clip, nowrap | sheet tabs | title, tabs |
| Google Drive CSV viewer | Sheets-like letters/numbers on dark chrome | full grid | no | right | clip | scroll | filename bar |
| macOS Quick Look | none | full grid `#DDDDDD` | no | left | nowrap | none (renders every row) | filename (window) |
| Box Preview | none | column dividers `#eaeaea` | yes, `#fcfcfc` | left | `white-space: pre`, scroll in cell | scroll | none |

---

## 1. GitHub CSV/TSV rendering

- **Looked at:** https://github.com/datasciencedojo/datasets/blob/master/titanic.csv (12 columns, 892 lines) and https://github.com/datasets/gdp/blob/main/data/top-economies.csv. Light mode was forced with `data-color-mode="light"`; dark values were read too.
- **Font (computed):** `"Mona Sans VF", -apple-system, system-ui, "Segoe UI", ...`. Body cells 12px / 18px line-height, weight 400. Header cells 12px, weight 600. Line numbers 12px.
- **Colors (computed, light):** text `#1f2328`; header fill `#f6f8fa`; gridlines `#d1d9e0`; line-number text `#59636e`; table background white.
- **Colors (computed, dark):** page and table `#0d1117`; header fill `#151b23`; gridlines `#3d444d`; text `#f0f6fc`; line numbers `#9198a1`.
- **Header row:** filled band (`#f6f8fa`), weight 600, original case, `white-space: nowrap`, not sticky (`position: static`).
- **Gridlines:** full grid. Each cell draws a 1px left and top border in `#d1d9e0`, `border-collapse: collapse`. The line-number gutter has no borders.
- **Row height / padding:** 35px rows; cell padding 8px all round. Line-number cell: 54px wide, right-aligned, padding 9px 16px 8px 12px.
- **Zebra:** none.
- **Numbers:** left-aligned like text; `font-variant-numeric: normal` (no tabular figures), so decimals do not line up ("7.25", "71.2833", "7.925").
- **Long cells:** stay on one line (headers `nowrap`; body text did not wrap in the 12-column sample). Columns size to content; the table scrolls horizontally.
- **Row numbers / column letters:** row numbers yes (they are file line numbers, so the header is line 1). No column letters.
- **Frame:** the table sits inside the file viewer box: 1px `#d1d9e0` border, 6px radius, no shadow.
- **"More data":** renders every row. Above a size limit it falls back to raw text with the banner "We can't make this file beautiful and searchable because it's too large." (seen on a 550 KB file).
- **Metadata:** file header shows "892 lines (892 loc) · 58.9 KB", plus Preview/Code/Blame tabs and a "Search this file" box.
- **Dark mode:** yes, follows the system setting.

## 2. GitLab CSV rendering

- **Looked at:** https://gitlab.com/gitlab-org/gitlab/-/blob/master/spec/fixtures/csv_gitlab_export.csv (light mode forced by swapping `gl-dark` for `gl-light`).
- **Font (computed):** `"GitLab Sans"` 14px / 20px, weight 400, color `#3a383f`.
- **Header row:** effectively unstyled. The real `<thead>` is hidden (0px tall) and the CSV header row renders as an ordinary row in the same weight and color as the body.
- **Gridlines:** full grid, 1px `#dcdcde` on every side.
- **Padding:** 10px 16px, `vertical-align: top`.
- **Long cells:** wrap freely. A short description becomes a 9-line cell, and every row is padded to at least ~80px tall, so 4 rows fill the whole viewport.
- **Numbers:** left-aligned. No zebra, no row numbers, no column letters.
- **Metadata:** file name and "1.09 KiB" in the file header bar.
- **Dark mode:** yes (follows system).
- **Takeaway:** the clearest example of what to avoid. Without a header distinction and with wrapping, it reads as a document, not a table.

## 3. Hugging Face dataset viewer

- **Looked at:** https://huggingface.co/datasets/fka/awesome-chatgpt-prompts (text-heavy) and https://huggingface.co/datasets/scikit-learn/iris (numeric). Light mode forced by removing `html.dark`.
- **Font (computed):** `"IBM Plex Mono"` 12px / 16px for the whole table (monospace body and header).
- **Colors (computed, light):** text Tailwind v4 gray-900 (`oklch(0.21 0.034 264.665)`, about `#101828`); column type label gray-500 (about `#6a7282`); borders gray-200 (about `#e5e7eb`); zebra gray-50 (about `#f9fafb`); string-length histogram bars gray-300 (about `#d1d5dc`); numeric and class histograms indigo (about `#6366f1`, read off screenshot).
- **Colors (computed, dark):** background `#0b0f19`; zebra `#101623`; rules `#141c2e`; text gray-200; type label gray-400.
- **Header row:** three stacked lines per column. Column name in 700. Then the dtype (`string`, `float64`, `bool`) plus an italic stat label (`lengths`, `classes`). Then a mini histogram (about 30px tall) with min and max under it (for example "29 ... 144k"), or "2 classes" / "3 values" under a proportional bar for categoricals. Header is ~97px tall, `position: sticky` with a white fill, and a sort control at the right.
- **Gridlines:** full grid. Each row has a 1px gray-200 bottom border; cells have a 1px gray-200 right border.
- **Row height / padding:** 33px rows for single-line cells; 8px padding.
- **Zebra:** yes. Odd rows gray-50, even rows transparent.
- **Numbers / booleans:** right-aligned. Strings left-aligned.
- **Long cells:** `-webkit-line-clamp: 2` with an ellipsis, so text rows grow to two lines at most (about 55px) and the rhythm stays even.
- **Frame:** card with 1px gray-200 border, 8px radius, shadow `0 1px 2px rgba(0,0,0,.05)`. Card title "Dataset Viewer" with action pills.
- **"More data":** pager row "< Previous 1 2 3 ... 30 Next >" separated by a dashed top rule.
- **Metadata:** split selector "train · 3k rows"; the sidebar shows "Number of rows" and "Total file size".
- **Takeaway:** the best-looking surface studied. The typed header with a histogram is a real per-dataset fingerprint, and the 2-line clamp is an elegant truncation rule.

## 4. Kaggle Data Explorer

- **Looked at:** https://www.kaggle.com/datasets/yasserh/titanic-dataset, Data Card tab, Data Explorer in "Detail" and "Compact" modes (the cookie banner was hidden with CSS for the screenshot, not accepted).
- **Fonts (computed):** header `"Google Sans Flex"` 12px, column name weight 300 in `#1f1f1f`, column description 12px/300 in `#5a5a5a`. Body `"Google Sans Code"` 12px / 16px, weight 300, `#5a5a5a`.
- **Header row:** a type glyph before each name (`#` numeric, `A` with underline for string, a key icon for an ID), a sort icon at the right, and in Detail mode a one-line column description plus a summary row: blue (`#4d94ff`) histograms with min and max, "891 unique values" for high-cardinality text, top categories for low-cardinality text.
- **Gridlines:** full grid, 1px `#d9d9d9` (cell right borders plus row bottom borders).
- **Padding:** 8px 12px; columns fixed at about 175px (Detail) or 135px (Compact).
- **Long cells:** wrap; rows grow to 4 lines. Numbers left-aligned in monospace (so they align by accident).
- **Zebra:** none. **Row numbers:** none.
- **"More data":** internal scroll; "10 of 12 columns" column picker at top right.
- **Takeaway:** the type glyphs are a cheap, legible way to show column types. The light-300 gray monospace looks washed out and would vanish in a thumbnail.

## 5. Datasette

- **Looked at:** https://latest.datasette.io/fixtures/facetable (the current Datasette design).
- **Font (computed):** `"Helvetica Neue"` 14px / 20.3px, text `#0f0f0f`.
- **Header row:** pale blue band `rgba(238,246,255,.88)` (about `#eef6ff`), 13px, weight 600, `nowrap`, padding 7.2px 8px 7.2px 12px, 1px `#d8e6f5` bottom border. Each header has a small gear (column actions) icon.
- **Gridlines:** horizontal rules only: 1px `#d8e6f5` (`border-top` on each cell). No vertical lines.
- **Row height / padding:** 37px rows; cells padding 8px 12px; `white-space: pre-wrap`.
- **Numbers:** right-aligned, `font-variant-numeric: tabular-nums`, muted `#666`, with extra right padding (36.6px) so they clear the header gear icon.
- **Links / keys:** primary keys are bold links (`#276890`, 600); foreign keys show the label as a link plus the raw id in small gray.
- **Frame:** card with 1px `#d8e6f5` border, 8px radius, shadow `0 1px 2px rgba(15,40,70,.04)`.
- **Zebra:** none. **Row numbers:** the primary key column plays that role.
- **Metadata:** large table title ("facetable") and "15 rows" above the table.
- **Dark mode:** none observed.
- **Takeaway:** the most "editorial" of the group. Rules-only plus a tinted header plus muted tabular numbers looks calm and expensive.

## 6. Jupyter / pandas DataFrame HTML

- **Looked at:** nbviewer renderings of https://github.com/justmarkham/pandas-videos/blob/master/pandas.ipynb (truncated 193-row frame) and https://github.com/jakevdp/PythonDataScienceHandbook/blob/master/notebooks/03.08-Aggregation-and-Grouping.ipynb (`planets.head()`).
- **Font (computed, nbviewer):** `system-ui` 13px, color `rgba(0,0,0,.87)`. (JupyterLab itself uses 12px.)
- **Header row:** bold (700), right-aligned, no fill; `thead` has a 1px `#bdbdbd` bottom border.
- **Gridlines:** none besides that header rule.
- **Row height / padding:** 29px rows; padding 6.5px (0.5em).
- **Zebra:** yes, `#f5f5f5` on alternate rows, white otherwise.
- **Alignment:** everything is right-aligned, text included. The index column is bold.
- **"More data":** pandas inserts a `...` row in the middle (head and tail shown) and a `...` column when columns are elided, then a caption under the table: "193 rows × 6 columns".
- **Takeaway:** the `...` row plus a dimension caption is the most widely recognised "this is a slice of a bigger table" idiom. Right-aligning text is the anti-pattern here.

## 7. Google Sheets "published to the web"

- **Looked at:** a public sheet published to the web (a `pubhtml` URL, found embedded on a university page), both the default and with `headers=true` (which shows column letters and row numbers).
- **Cells (computed):** Arial 13.33px (10pt), black, padding 2px 3px, `vertical-align: bottom`, `white-space: nowrap`, 21px rows. Gridlines 1px `rgba(0,0,0,.15)` on right and bottom.
- **Chrome (computed):** column letters and row numbers in `"Google Sans"` 12px, `#444746`, centered, on white, with 1px `#c4c7c5` borders; the top-left corner cell is `#efeded`. Column header row 24px; row-number gutter 46px.
- **Header row:** no automatic styling. Whatever the author formatted shows (in the sample: yellow fill, bold, underlined).
- **Numbers:** right-aligned (Sheets typing). Text left.
- **Frame:** none; title line ("<document title> : Sheet1") top left in plain text, sheet tabs bar at the bottom (active tab `#0b57d0` text, bold, on `#dde3ea`).
- **Takeaway:** letters plus row numbers instantly say "spreadsheet", even at small sizes. User-applied fills (the blue rows) are the most visible thing in a thumbnail.

## 8. Google Drive: CSV previewer and grid thumbnails

- **Looked at (via public images, no Drive account):**
  - CSV previewer: image from a "How to Import CSV Files in Google Sheets" tutorial, https://images.ctfassets.net/pt9zoi1ijm0e/1R2rPD4PJFKvFa7V3dYmlQ/6f0f5d9ee67caeccbd4b5687f7f382bf/method_2_pt_6.png
  - Grid thumbnails: https://i0.wp.com/drkblake.com/wp-content/uploads/2014/12/GoogleDriveGrid.png (older Drive UI, 2014; current Drive uses rounded cards but the same thumbnail idea).
- **CSV previewer (from screenshot):** dark viewer chrome (about `#202124` with white text) with the filename and an "Open with" button on top. The CSV renders like a Sheet: column letters and row numbers on dark gray with light gray text, white cells, Arial-like ~13px, right-aligned numbers ("28", "34"), light gray 1px grid, nowrap with clipping. No header styling for the CSV's first row.
- **Grid thumbnails (from screenshot):** each tile is the top of the first "printed page", scaled to ~175px wide: white page, tiny unreadable text, light gridlines, lots of empty white when the sheet is narrow. Under it, a strip with the green Sheets (or Excel "X") icon and the truncated filename. Recognition comes from the icon and name strip plus the grey "texture" of the grid, not from readable content. Sheets with a chart or colored fills are much easier to tell apart.

## 9. macOS Quick Look and Finder thumbnails

- **Looked at:** generated directly on this Mac (macOS 26) with `qlmanage -p -o` (Quick Look preview, which writes the generated HTML) and `qlmanage -t -s 600 -o` (the Finder thumbnail), using a 14-row sample `transactions.csv` and a 5,000-row stress file. Also the third-party QuickLookCSV plugin via https://victorlin.github.io/assets/img/png/quicklook-csv-screenshot.png.
- **Native preview (source: the generated `Preview.html`, from `/System/Library/QuickLook/Office.qlgenerator`):**
  ```css
  body { font: 10px Verdana; }
  table { border-collapse: collapse; }
  td { font-family: Verdana, Arial; font-size: 10; border: solid 1px;
       padding: 5px; white-space: nowrap; border-color: #DDDDDD; }
  ```
  Every cell is a `<td>`: no header styling, numbers left-aligned, no zebra, no row numbers. It renders all 5,000 rows (962 KB of HTML), so there is no truncation or "more" cue. The window title is the filename.
- **Finder thumbnail (source: `qlmanage -t`):** the same HTML rendered at the top-left of a white square canvas. A 14-row file leaves the bottom ~45% of a 600px square blank. A wide 5,000-row file fills the square with an 8-column grid whose text is illegible at 256px but whose 1px grid still reads as "table".
- **QuickLookCSV plugin (third party, from screenshot):** shows a metadata header above the table: "**3** columns, **24** rows" and "**500 Byte**, Comma-Separated, UTF-8" (numbers bold), then a bordered table with gray zebra rows. A nice example of the metadata line.
- **Numbers / XLSX / iOS Files:** not captured. Numbers documents carry their own embedded preview image; XLSX and iOS previews were not verified.

## 10. Box, Dropbox, OneDrive, Slack, Gmail

- **Box Preview (source: open-source `box/box-content-preview`, `src/lib/viewers/text/CSV.scss` and `BoxCSV.js`):** react-virtualized grid. `HEIGHT_ROW = 30`, columns equal width, at least 160px, stretched to fill the container. Cell padding `0 0.5em`, text `#000`, `white-space: pre`, 1px right border `#eaeaea`, odd rows `#fcfcfc` (an almost invisible zebra). Long cells scroll inside the cell rather than truncate. No header styling and no row numbers. No screenshot.
- **Dropbox (from a 2018 screenshot, https://help.qlik.com/talend/en-US/talend-cloud-getting-started/Cloud/Content/Resources/images/use_case-royalties_output_dropbox.png):** spreadsheet-style grid in a side panel with the file name and "Modified just now" on top. A semicolon-delimited file was not split, so every row sits in column A. That is an anti-pattern worth guarding against (delimiter sniffing). Current Dropbox UI not verified.
- **OneDrive / Excel for web, Slack, Gmail attachment cards:** not captured; no clean public image was found within the time box, so no details are claimed here.

---

## Synthesis

### (a) Patterns shared by the best-looking examples (Hugging Face, Datasette, GitHub)

1. **A contained card.** 1px border in a very light cool gray (`#e5e7eb`, `#d1d9e0`, `#d8e6f5`), 6 to 8px radius, a shadow so faint it is almost not there (`0 1px 2px` at 4 to 5% black). The table never floats on raw white.
2. **A header band that differs from the body in two ways at once:** fill (`#f6f8fa`, pale blue `#eef6ff`) or a structural element (HF's histogram row), plus weight 600 to 700. Size is the same as the body or 1px smaller (12 to 13px). Original case, no all-caps. Always `nowrap`.
3. **Quiet lines.** Either horizontal rules only (Datasette) or a very light full grid (GitHub, HF). Always 1px, and always much lighter than the text, so lines organise the content without competing with it.
4. **Compact, steady rhythm.** 12 to 14px type in 29 to 37px rows, about 8px vertical padding. One line per row (or HF's hard cap of two), so the grid stays even.
5. **Numbers treated as numbers.** Right-aligned (HF, Datasette, Sheets), ideally with tabular figures (Datasette), sometimes muted in color so text columns carry the eye.
6. **Truncation that protects row height:** `nowrap` plus clipping (GitHub, Sheets) or a 2-line clamp with an ellipsis (HF).
7. **Context next to the grid:** a title and size or count line ("892 lines · 58.9 KB", "train · 3k rows", "15 rows", "193 rows × 6 columns", "3 columns, 24 rows, 500 Byte, Comma-Separated, UTF-8").
8. **A muted index gutter** (GitHub's `#59636e` right-aligned line numbers, Sheets' row numbers). It anchors the left edge and makes the thing look like a data file.
9. **Type awareness as decoration with meaning:** HF's dtype line and histograms, Kaggle's `#` / `A` glyphs.
10. **Near-black text, not pure black:** `#1f2328`, `#0f0f0f`, `#101828`. The two that use pure black (Quick Look, Box) look the most dated.

### (b) Anti-patterns that make previews look cheap or unreadable

- **Wrapping long text** (GitLab, Kaggle): one long description makes a row 4 to 9 lines tall, so the preview shows 3 or 4 rows and reads as a document, not a table.
- **Header row identical to data** (GitLab, macOS Quick Look, Box, Dropbox, Drive's CSV viewer): no hierarchy, so the eye cannot find the column names.
- **Everything right-aligned** (pandas): ragged left edges on text columns.
- **Numbers left-aligned in a proportional font** (GitHub, Quick Look): decimals wobble.
- **Equal-width columns** (Box, at least 160px): either wasted space next to a 1-character column or clipped text next to it.
- **Dated defaults:** Verdana 10px, pure black on pure white, `#DDDDDD` box grid (Quick Look).
- **Thin, light, low-contrast type** (Kaggle's 300-weight `#5a5a5a` monospace): elegant at 100% and invisible when scaled down.
- **A small table on a big empty page** (Quick Look thumbnail, Drive thumbnails): a 5-column file becomes a blank white square with a smudge in the corner.
- **Not detecting the delimiter** (Dropbox with semicolons): one giant column.
- **No "there is more" cue** (GitHub, Quick Look): a 20-row crop of a 50,000-row export looks complete.

### (c) What survives being scaled down to ~300px wide

Tested by shrinking the 1,300px screenshots to 300px (a 4.3x reduction) and comparing them side by side.

- **Text does not survive a 4x reduction.** Every 12 to 14px table became ~3px text: pure texture. Only the Quick Look thumbnail (rendered at 600px, so only 2x reduction) and HF's larger header labels stayed partly readable. So the thumbnail must be **laid out for 300px**, not downscaled from the 1024px image: 3 to 5 columns, 6 to 10 rows, body text about 11px at 1x (render at 2x or 3x for retina), header the same size and bold.
- **What makes it read as "a table" at a glance:** (1) a distinct header band, (2) a regular row rhythm, (3) clean column edges from consistent alignment, (4) a left gutter. Zebra striping survives downscaling much better than 1px rules: the pandas and HF stripes stayed crisp while GitHub's `#d1d9e0` grid and Datasette's `#d8e6f5` rules nearly disappeared.
- **Fill the frame.** Crop to the data and let it bleed off the right and bottom edges, ideally with a soft fade, instead of centering a small table on white. A preview that is 45% empty looks broken.
- **Identity beats content for "that export".** In Drive's grid it is the type icon plus filename strip, and in Sheets it is the user's colored cells, that make one file distinguishable from another. Candidates for a static image: the header row's actual column names in the largest type in the image, one accent color, and a small "CSV · 1,204 rows" badge.
- **Uneven rows destroy recognition.** GitLab's wrapped rows look like a text document at 300px. One line per row is mandatory at thumbnail size.

### (d) Three candidate visual directions

**Direction 1: "Quiet card" (GitHub plus Datasette).** White card, 1px `#e5e7eb` border, 8px radius, faint shadow. Header band `#f6f8fa` with 12 to 13px semibold near-black names and a 1px rule under it. Rows 32 to 36px, horizontal hairlines only (`#eef0f2`), optional faint zebra (`#fafbfc`). Muted right-aligned row-number gutter. Numbers right-aligned with tabular figures in a slightly muted color; text left with an ellipsis. Footer strip in 11px muted gray: "1,204 rows · 12 columns · 58 KB". Right and bottom edges fade to white when there are more columns or rows. Dark variant: `#0d1117` background, `#151b23` header, `#3d444d` rules, `#f0f6fc` text.
```
╭──────────────────────────────────────────────────╮
│    date        merchant          amount   memo   │  <- #f6f8fa band, 600
├──────────────────────────────────────────────────┤
│  1 2026-10-01  Tidepool Coffee…    -6.50  Team c░│
│  2 2026-10-02  Amazon Web Servi… -1,243.87 Month░│
│  3 2026-10-03  Stripe Payout     15,000.00 Payo░│
│  4 2026-10-04  Office Depot         -89.12 Print░│
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │  <- fade = more rows
├──────────────────────────────────────────────────┤
│  transactions.csv · 1,204 rows · 6 columns       │
╰──────────────────────────────────────────────────╯
```

**Direction 2: "Sheet" (Google Sheets, Drive, Excel).** Spreadsheet chrome: a column-letter row (A, B, C) and a row-number gutter in 11 to 12px gray (`#444746`) on `#f8f9fa`, with `#c4c7c5` dividers. Cells on white with a full 1px `rgba(0,0,0,.12)` grid, ~13px Inter or Arial, 21 to 24px rows, numbers right-aligned. The CSV's first row is bold, lightly tinted, and the grid is cropped at the right and bottom edges (no frame), the way a real sheet scrolls. A small green-ish "CSV" corner badge. The most instantly recognisable as "spreadsheet file" at 300px, and the least distinctive as a design.
```
┌───┬────────────┬──────────────┬──────────┬──────
│   │ A          │ B            │ C        │ D
├───┼────────────┼──────────────┼──────────┼──────
│ 1 │ date       │ merchant     │   amount │ memo     <- bold, tinted
│ 2 │ 2026-10-01 │ Tidepool Co… │    -6.50 │ Team
│ 3 │ 2026-10-02 │ Amazon Web S │ -1243.87 │ Mont
│ 4 │ 2026-10-03 │ Stripe Payou │ 15000.00 │ Payo
│ 5 │ 2026-10-04 │ Office Depot │   -89.12 │ Prin
└───┴────────────┴──────────────┴──────────┴──── [CSV]
```

**Direction 3: "Dataset profile" (Hugging Face plus Kaggle).** Card as in Direction 1, but each header cell is a mini column profile: a type glyph (`#`, `Aa`, calendar, check) plus the column name in semibold; under it a 20 to 28px sparkline histogram (numbers and dates) or a category bar (low-cardinality text) in one accent color; then a tiny min/max or "3 values" label. Body in a compact monospace or a tabular-figure sans at 12px with a 2-line clamp, faint zebra, right-aligned numbers. At 1024px it reads as a data-quality summary; at 300px the row of histograms survives as a colorful, file-specific fingerprint even when no text is legible. The highest ceiling for "beautiful", but more computation (it needs a full pass over the data for the profiles) and more to get wrong on messy CSVs.
```
╭────────────────────────────────────────────────────╮
│ ▦ transactions.csv                  1,204 rows · 6 │
├────────────┬──────────────┬──────────┬─────────────┤
│ ◷ date     │ Aa merchant  │ # amount │ Aa category │
│ ▁▂▄▆█▆▄▂▁  │ ▇▃▂▁▁ lengths│ ▁▁▂█▃▁▁  │ ███▆▃ 5 vals│ <- accent histograms
│ 10-01 10-31│ 4         31 │ -8k  15k │             │
├────────────┼──────────────┼──────────┼─────────────┤
│ 2026-10-01 │ Tidepool Co… │    -6.50 │ Food        │
│ 2026-10-02 │ Amazon Web…  │ -1243.87 │ Software    │
│ 2026-10-03 │ Stripe Payo… │ 15000.00 │ Income      │
╰────────────┴──────────────┴──────────┴─────────────╯
```

**Shared recommendation for all three:** render two layouts, not one image at two sizes. The 1024px "detail" layout shows as many columns as fit at 13px. The 300px "thumbnail" layout shows 3 to 5 columns and 6 to 10 rows at about 11px, keeps the header band and zebra (which survive), drops hairlines and secondary labels (which do not), and always fills the frame edge to edge.

