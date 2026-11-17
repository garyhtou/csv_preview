
# Designed data tables: visual research for the CSV preview renderer

> Screenshots of third-party products described here were captured for private reference and are not included in this repository. Each section names or links the live source instead. Mockups we rendered ourselves are in [`../design/mockups/`](../design/mockups/).

Last reviewed: 2026-11-15. Scope: publication table tools, well-designed product grids, design-system table tokens, table typography and bundleable fonts, and "shareable image" framing. Real file-preview surfaces (GitHub, Drive, Quick Look, Hugging Face, Jupyter) are covered separately in [`file-preview-surfaces.md`](./file-preview-surfaces.md).

**How values were obtained.** Design-system and library values were read from source code (gt `dt_options.R` and SCSS, Primer `Table.module.css`, Polaris `DataTable.module.css` plus token files, Atlassian compiled CSS on unpkg, MDC data-table SCSS, carbon.now.sh and ray.so source). Product UIs (Stripe, Notion) are estimates from screenshots and are marked "approx". Font facts were measured locally with fontTools on the Google Fonts files, and rendering was tested with Pango 1.58 (`pango-view`), the same Pango/HarfBuzz stack libvips uses for `text`.

## Reference images

Image index (our own mockups are linked; third-party screenshots are not included):

| File | What it shows | Why it is instructive |
|---|---|---|
| `gt-sp500.jpg` | gt (R) default theme on a financial table | The canonical "publication" look: grey rules only, tabular right-aligned currency, no fills |
| `stripe-payments.jpg` | Stripe Dashboard payments list (via saasframe.io) | Best-in-class money list: hairlines, quiet header, bold amount, muted currency code |
| `notion-table.jpg` | Notion database table | Soft gridlines both ways, no header fill, muted header with icons |
| `ibm-carbon-datatable-sizes.jpg` | IBM Carbon data table at its five row heights | Density ladder (24 to 64px) and a filled-header, filled-body treatment in IBM Plex Sans |
| `datawrapper-table.jpg` | Datawrapper table with sticky first column | Journalism style: heavy 2px header rule, light zebra, Roboto |
| `carbon-now-sh.jpg` | carbon.now.sh code image | The "premium shareable image" frame: window chrome, padding, big soft shadow |
| [`mock-ledger-default.jpg`](../design/mockups/mock-ledger-default.jpg) | Mock of the proposed **default** token set (Inter) | Rendered with real Pango text from a 23-column bank export |
| [`mock-grid-spreadsheet.jpg`](../design/mockups/mock-grid-spreadsheet.jpg) | Mock of the **spreadsheet** token set | Gridlines, row-number gutter, 28px rows |
| [`mock-report-card.jpg`](../design/mockups/mock-report-card.jpg) | Mock of the **document/card** token set | Title block, booktabs rules, card on a tinted canvas |
| [`mock-thumbnails-300px.jpg`](../design/mockups/mock-thumbnails-300px.jpg) | The three mocks downscaled to exactly 300px wide | What actually survives at thumbnail size |
| [`font-specimens-13px-1x.jpg`](../design/mockups/font-specimens-13px-1x.jpg) | Same 5-row table at 13px, 1x, in six candidate fonts | Small-size legibility and width comparison |

---

## 1. Sources and their visual treatment

### 1.1 gt (R) and great_tables (Python)

great_tables is a Python port of gt and ships the same default theme. Values from gt's `dt_options.R` and `gt_styles_default.scss`:

| Element | Value |
|---|---|
| Font | system stack: `system-ui, Segoe UI, Roboto, Helvetica, Arial, sans-serif` (+ emoji fonts) |
| Body text | 16px, `#333333`, weight normal |
| Background | `#FFFFFF` |
| Table top and bottom border | 2px solid `#A8A8A8` |
| Heading (title) | 125% size, centered; subtitle 85%; bottom border 2px `#D3D3D3` |
| Column labels | 100% size, **normal weight**, no fill, no text-transform; top and bottom borders 2px `#D3D3D3` |
| Body row rules | 1px solid `#D3D3D3` |
| Body top/bottom border | 2px `#D3D3D3` |
| Cell padding | 8px vertical, 5px horizontal (column labels 5px) |
| Row striping | off by default; when on, `rgba(128,128,128,0.05)` |
| Grand summary row | 6px **double** border `#D3D3D3` above totals |
| Source notes | 90% size |
| Numbers | `.gt_right { text-align: right; font-variant-numeric: tabular-nums; }`: right-aligned cells get tabular figures automatically |

**Why it looks polished** (see `gt-sp500.jpg`): only two greys, no fills anywhere, header is the same weight as the body (hierarchy comes from the rules, not from bold), a heavier rule frames the top and bottom (booktabs), and every currency column is right-aligned with tabular figures so decimal points stack. Title and subtitle are centered above the table. The weakness for our use: 2px rules and 8/5px padding are tuned for print and HTML, and the centered title wastes width in a wide preview.

`opt_stylize(style=1..6, color=...)` adds preset themes (colored header fills, striping), and `GT.save()` produces PNGs through a headless browser.

### 1.2 pandas Styler, Jupyter default, dataframe_image

pandas `Styler` emits bare HTML; the look comes from the notebook CSS. JupyterLab (`rendermime/style/base.css`): 13px, `rgba(0,0,0,0.87)`, `text-align: right` on **every** cell including text, bold `th`, header bottom border `#BDBDBD`, zebra on even rows (`--md-grey-100`, `#F5F5F5`), padding 0.5em, no row rules. `dataframe_image` screenshots that output via Chrome (or a matplotlib fallback that looks much worse). This is the "tidy but not beautiful" baseline: right-aligned text and zebra plus bold header is legible, but text columns look ragged and nothing has hierarchy. Screenshot in [`file-preview-surfaces.md`](./file-preview-surfaces.md) (`jupyter-pandas.jpg`).

### 1.3 Datawrapper (and Flourish)

Datawrapper's default table (see `datawrapper-table.jpg`): Roboto, bold header in near-black, a **2px dark rule** (about `#333`) under the header, 1px light rules (about `#E0E0E0`) between rows, very light zebra (about `#F5F5F5`) on long tables, numbers right-aligned, header aligned with its column. Their own guidance ([guide](https://www.datawrapper.de/blog/guide-what-to-consider-when-creating-tables)): favor rows over columns, shorten values (move repeated units into the header), use light grey stripes only on long tables with many columns, adjust row height to row count (compact layout for many rows), use color for meaning (pastel cell fills, saturated text). Flourish's table template follows the same news-graphics conventions (not inspected in detail).

### 1.4 Stripe Dashboard: payments list (approx, from screenshot)

See `stripe-payments.jpg`. Rows about 36 CSS px; header and badges 12px; body 14px; white surface; hairline rules about `#EAEEF1`; no zebra; no vertical rules; header row has no fill, 12px semibold dark text. The **amount is the first column, semibold, left-aligned**, followed by the currency code (`USD`) in muted grey and a status pill (mint `#CFF8BD`-ish "Succeeded", pink "Failed"); dates are muted (`Feb 24, 2022, 10:44 AM`). Footer: "Viewing 1 to 20 of 844 results" with Previous/Next. Lessons: one emphasized column carries the row; secondary data goes muted rather than smaller; hairlines plus generous whitespace read as premium. (Stripe's font, Sohne, is proprietary; text colors in their UI are approximately `#414552` body and `#687385` muted.)

### 1.5 Notion database table (approx, from screenshot)

See `notion-table.jpg`. 14px body in `#37352F` (warm near-black); header 14px regular in muted grey (about `#787774`) with a small property-type icon; **no header fill**; 1px warm grey gridlines (about `#E9E9E7`) both horizontally and vertically, but no outer left/right border; rows about 33 to 36px; title column semibold-ish with an emoji/page icon; select values as rounded pastel pills. It looks "light" because there is no fill at all and the header is quieter than the body.

### 1.6 Spreadsheet archetype: Airtable grid, Apple Numbers, Google Sheets (qualitative)

Airtable's grid defaults to "Short" rows (one line, densest); Medium/Tall/Extra tall show 2/4/6 lines ([docs](https://support.airtable.com/docs/airtable-grid-view)); pixel values are not published (inspected UI from memory: about 32px short rows, 13px text, light grey fill on the header, gridlines both ways, a frozen primary field with a stronger divider, a row-number gutter). Numbers' default table uses a header row and header column whose fill comes from the table style; values not verified. The common spreadsheet signature: **gridlines both directions, a filled header, a row-number gutter, 28 to 32px rows, 12 to 13px text, columns cut off at the edge instead of faded.** That signature survives downscaling better than hairline designs (see section 3c).

### 1.7 Linear and Vercel (qualitative)

Linear's lists: 13px Inter-family text, no header row, hairline separators, metadata in muted grey, rows about 36 to 44px; the polish comes from strict alignment and few colors. Vercel's Geist design system: the Table docs explicitly say "Apply `tabular-nums` (or Geist Mono) to numeric columns so digits align across rows" ([Geist table](https://vercel.com/geist/table)); the dashboard uses Geist Sans with hairline rules and no fills. Retool and Glide were not examined (generic component-library tables, nothing distinctive).

### 1.8 Design-system data-table tokens

| System | Row height | Cell padding | Body text | Header | Rules | Zebra | Numbers |
|---|---|---|---|---|---|---|---|
| **GitHub Primer** DataTable | from padding: condensed 4/8px, normal 8/12px, spacious 12/16px (block/inline); line-height 20px | first/last cell inline padding 16px | **12px**, `fgColor-default` | semibold, `fgColor-muted` (`#59636E`), fill `bgColor-muted` (`#F6F8FA`) | 1px `borderColor-default` (`#D1D9E0`) on rows **and** an outer border; radius 6px | no | `align: 'end'` for numeric columns |
| **IBM Carbon** DataTable | xs 24, sm 32, md 40, lg 48, xl 64px; header matches row size | 16px left/right | 14px/400 (`body-compact-01`), `text-secondary` (`#525252`) | 14px/600 (`heading-compact-01`), `text-primary` (`#161616`), fill `layer-accent` (`#E0E0E0` in white theme) | 1px `border-subtle` (`#C6C6C6` on layer 01) | optional, `layer-accent` | no rule stated |
| **Shopify Polaris** DataTable | from padding 8px vertical (header 12px) | 6px horizontal, 12px on first/last | 13px/20px (`body-md`), Inter, `#303030` | **regular weight**, `#303030`, bottom border `#E3E3E3` | 1px `#EBEBEB` between rows | optional, `#F7F7F7` | `numeric` type right-aligns; totals row semibold (650) on `#F7F7F7` |
| **Atlassian** dynamic table | from padding 4px vertical | 8px horizontal, **0 on first/last** (flush with surrounding text) | body default (about 14px, not verified) | 12px/16px bold (653) | header bottom **2px** `color.border` (`#0B120E24`, about 14% black); no row rules | no | not specified |
| **Material** (M2 / MDC) | 52px rows, 56px header, min 36px (dense) | 16px leading and trailing | 14px `body2`, 87% black | 14px medium `subtitle2`, 87% black | 1px 12% black (about `#E0E0E0`); outline 1px, radius 4px | no | `--numeric` cells right-aligned |
| **Material 3** | no data-table component published | | | | | | |
| **Apple HIG** | no data-table tokens; macOS list/table views use alternating row backgrounds and right-aligned numbers by convention | | | | | | |

Takeaways: every system right-aligns numeric columns and aligns the header with its data; most use **one** light rule between rows and no zebra by default; header emphasis ranges from "regular weight, no fill" (Polaris, gt) to "semibold, muted color, light fill" (Primer); text sizes are 12 to 14px with 8 to 16px horizontal padding.

### 1.9 Shareable-image analogs

| Tool | Framing values (from source) |
|---|---|
| **carbon.now.sh** (`carbon-now-sh.jpg`) | padding 56px all sides; default background `rgba(171,184,195,1)` (`#ABB8C3`); window radius 5px; drop shadow `0 20px 68px rgba(0,0,0,0.55)`; macOS traffic-light window controls; Hack 14px, line-height 133%; window width 680px (320 to 1280); exported at 2x |
| **ray.so** | padding options 16/32/64/128px, default **64**; window radius **18px**; 1px inner highlight plus 1.5px outer border; "withShadow" is a six-layer smooth shadow (`0 2.8px 2.2px rgba(0,0,0,.034)` up to `0 100px 80px rgba(0,0,0,.12)`); 24px title bar; light frame `rgba(255,255,255,0.95)` over a gradient or image |
| **Vercel OG (`@vercel/og`)** | 1200x630 canvas; typical templates: big centered title (60 to 72px), small logo, flat or gradient background |
| **table-to-image generators** (tableconvert.com, "CSV to Table Image", CodeShack, CyberChef) | theme galleries: colored header bands, heavy borders, often centered text; they look templated rather than designed |

What makes these feel premium: generous outer padding, a single soft large shadow, rounded window with a hairline edge, an opinionated background, exporting at 2x, and a title bar that names the thing. **For a file preview most of this is wrong**: the host UI (list cell, modal) already supplies the frame and radius, outer padding and background waste thumbnail pixels, and a shadow implies a floating object inside an object. Keep only: 2x export, a hairline edge, and (optionally) a compact title/meta strip. Reserve the padded card with shadow for a "share" or social output mode.

---

## 2. Typography for tabular data

### 2.1 Tabular figures and Pango/libvips

- **Tabular figures** (`tnum`) give every digit the same advance width so columns of numbers align on the decimal point; proportional figures (`pnum`) are tighter and nicer in running text and in dates. Use tabular for quantities (amounts, balances, counts); proportional is fine for left-aligned dates in fonts whose tabular "1" leaves gaps (Inter).
- **Pango supports OpenType features in markup**: `<span font_features="tnum">` (CSS syntax, comma-separated, e.g. `font_features="tnum, zero"`), available since Pango 1.38 ([markup docs](https://docs.gtk.org/Pango/pango_markup.html)). Verified locally on Pango 1.58: Inter's `1,111.11` widens with `tnum` on. Other useful markup: `foreground` with alpha (1.38+), `letter_spacing` (1024ths of a point), `line_height` (1.50+), `allow_breaks` / `insert_hyphens` (1.44+).
- **libvips `text`** (from `libvips/create/text.c`): takes Pango markup; options `font`, `fontfile`, `width`, `height`, `align`, `justify`, `dpi`, `spacing`, `rgba`, `wrap`. Practical notes for the renderer:
  - `fontfile` registers the file with fontconfig (`FcConfigAppFontAddFile`); you still name the family in `font`. libvips creates its font map with `pango_cairo_font_map_new()`, which on **macOS defaults to the CoreText backend and ignores `fontfile`** (libvips even warns "try setting PANGOCAIRO_BACKEND=fontconfig"). Set `ENV["PANGOCAIRO_BACKEND"] = "fontconfig"` before the first text call, or dev machines will silently render Helvetica. Reproduced locally with `pango-view`.
  - There is **no ellipsize option**: truncation with `…` must be done by measuring the rendered width and trimming (binary search on characters), then appending U+2026.
  - `rgba: true` is needed for markup colors and color emoji; otherwise output is a 1-band mask you colorize yourself.
  - Each call returns `Xoffset`/`Yoffset`, useful to align cells in a row on a common baseline.
  - Use `dpi: 72` so "Inter 13" means 13px; render at 2x by doubling sizes, not by upscaling.
- **Static instances need correct names.** When instancing a variable font to static Regular/SemiBold, set `usWeightClass` and the name table, or fontconfig sees two "Regular" faces and picks either (hit this while testing). Alternatively ship the variable font: recent Pango (HarfBuzz-based, 1.44+) can pick a weight from it, through fontconfig's named instances or the `@wght=600` font-description syntax. Static files are the more predictable choice across distro Pango versions.
- **Licence nuance (OFL Reserved Font Names).** IBM Plex ("Plex") and Source Sans 3 / Noto CJK ("Source") reserve their names: a subset or instanced file is a modified version and must be renamed, or you ship the official files unmodified. Inter, Geist, Roboto Flex, Public Sans and JetBrains Mono have no RFN, so subsetting is simple. OFL fonts can be bundled in an MIT gem (ship `OFL.txt` alongside).

### 2.2 Candidate fonts (measured)

Sizes: Google Fonts variable file; a static instance per weight (fontTools instancer, unhinted); and that instance subset to Latin, Latin-1, Latin Extended-A/B, general punctuation and currency symbols. Width columns: the same sample at 13px (numeric `2026-03-14 $18,402.17` with `tnum`, text `AMZN Mktp US*2K4L19RT0 Office Supplies`); smaller means more columns fit.

| Font | Licence | Variable / static per weight / Latin subset | Figures by default | Features | Width @13px numeric / text | Coverage (cmap) | Small-size verdict |
|---|---|---|---|---|---|---|---|
| **Inter** 4 | OFL 1.1, no RFN | 856 KB / 333 KB / 130 KB | proportional | `tnum`, `zero`, `ss01`, `cv01`, `case`, `frac`, `calt`; `opsz` 14 to 32 axis | 162.5 / 269.9 px | 2,849 codepoints: Latin incl. Vietnamese, Cyrillic, Greek; all tested currencies ($ € £ ¥ ₹ ₩ ₽ ₺ ₫ ₱ ₦ ₴ ₿) | Excellent UI legibility at 12 to 14px. Tabular digits are wide (as wide as JetBrains Mono) and `tnum` dates look gappy; ASCII `-` gets a tabular-width slot, so use U+2212 `−` |
| **Geist** | OFL 1.1, no RFN | 165 KB / 88 KB / 45 KB | proportional | `tnum`, `ss01`, `ss02`, `case`, `frac` (no `zero`) | 144.6 / 258.8 px | 728 codepoints: Latin, Cyrillic, Greek; **missing ₩ ₺ ₫ ₦ ₿** | Sharpest, most "premium" look in tests; narrow numerics; needs a fallback font for some currencies |
| **IBM Plex Sans** | OFL 1.1, RFN "Plex" | 525 KB / 213 KB / 87 KB | **tabular** (all digits 600 units) | `zero`, `ss01`, `ss02`, `onum`, `frac` (no `pnum`) | 145.3 / 253.6 px | 891 codepoints, all tested currencies; sister families Plex Sans JP/KR/Arabic/Hebrew/Thai/Devanagari | Crisp, slightly technical; tabular without any feature flag (robust); good at 12px |
| **Source Sans 3** | OFL 1.1, RFN "Source" | 631 KB / 371 KB / 105 KB | **tabular** | `pnum`, `onum`, `zero`, `case`, `frac` | 121.2 / 229.6 px | 1,615 codepoints; missing ₿ | Narrowest, but small x-height (0.478 em) reads a size smaller: use 14px where others use 13px |
| **Roboto Flex** | OFL 1.1, no RFN | 1,745 KB (13 axes) / 94 KB / 50 KB | **tabular** | `pnum` | 135.2 / 250.9 px | 826 codepoints; missing ₿ | Compact and solid; looks generic (Android) |
| **Public Sans** | OFL 1.1, no RFN | 101 KB / 60 KB / 42 KB | proportional | `tnum`, `pnum`, `onum`, `lnum` | 166.4 / 265.7 px | 565 codepoints; no Cyrillic; missing ₽ ₱ ₴ ₿ → | Wide, a bit heavy; no advantage over Inter |
| **JetBrains Mono** (also Geist Mono 168 KB, IBM Plex Mono 132 KB static) | OFL 1.1, no RFN | 183 KB / 112 KB / 62 KB | monospaced | `zero`, `calt` | 163.8 / 296.4 px | 976 codepoints; missing ₹ ₩ ₺ ₱ ₦ ₴ | Only for IDs/hashes; far too wide for body text |
| **Noto Sans CJK / SC / JP** | OFL 1.1, RFN "Source" | Noto Sans SC variable 17.4 MB; JP 9.4 MB | n/a | n/a | n/a | CJK | Too big to bundle; use as a system fallback |

See `font-specimens-13px-1x.jpg` for the side-by-side.

**CJK and emoji plan.** Bundle one Latin family only. Build the Pango font description as a family list, e.g. `"Inter, Noto Sans CJK SC, Noto Sans CJK JP, Noto Color Emoji, sans-serif"`, and keep system fonts visible to fontconfig (`fontfile` adds to the default config rather than replacing it), so missing glyphs fall back per character. Document `apt install fonts-noto-cjk fonts-noto-color-emoji` for servers. Optionally publish a companion gem with a Noto CJK subset. Never let a missing glyph render as tofu silently: detect fallback via a coverage check (fontconfig `FcCharSet`) and log it.

---

## 3. Synthesis

### (a) What makes a data table look beautiful rather than merely tidy

1. **One family, two weights, three ink levels.** Body ink (`#1F2328`), muted (`#5B6472` to `#6B7280`) for headers and secondary text, faint for rules. Hierarchy comes from weight and color, not from many sizes. Header 1px smaller than the body, semibold, muted (Primer, Stripe, Notion) looks expensive; bold black uppercase header on a dark band looks like Excel.
2. **Quantities aligned like a ledger.** Right-align quantity columns with tabular figures, keep the source's decimals consistent, use a true minus `−`, and right-align the header over them. Everything else, including dates and IDs, left-aligns.
3. **Rules are hairlines and horizontal.** 1px, about 6 to 8% darker than the background; no vertical rules except in a spreadsheet look. gt/booktabs adds weight only at the top and bottom edges.
4. **Generous, constant rhythm.** Row height about 2.75x the font size (36px for 13px text), 12px horizontal cell padding, a larger 20px gutter at the left and right edges so text never hugs the border. Rows never wrap: one line per row keeps the rhythm.
5. **Cool, consistent neutrals.** Fills, rules and text all come from one grey ramp of the same hue (slightly blue-grey slate here). Mixing warm and cool greys is what makes many generated tables look off.
6. **Honest, designed overflow.** Long text ends in `…`; hidden columns fade out at the right edge; a footer says how much is not shown. Nothing is clipped mid-glyph.
7. **Content-aware column widths.** Measure the header and the visible cells with the exact attributes used to draw them (including `tnum`), cap text columns, never cap or truncate numbers.
8. **Rendering quality.** Grayscale antialiasing, subpixel positioning, no hinting distortion; render at 2x and let the host downscale.

### (b) Anti-patterns

- Right-aligning everything (Jupyter) or centering anything (generator themes). Headers aligned differently from their data.
- Proportional figures in amount columns; mixed decimal places; ASCII hyphen as the minus sign under `tnum` (wide gap in Inter).
- Full black grid in both directions, double borders, heavy outer frames; saturated header bands (Excel "Table Style Medium 2", theme galleries).
- Zebra *and* row rules *and* a header fill together: three competing structures. Pick one structure for the body.
- Filling every body cell grey (Carbon's `#F4F4F4` layer) in a static image: heavy and dated outside its app context.
- Wrapping long descriptions onto two or three lines (breaks the row rhythm, and one long cell sets the whole image height); hard-clipping text at the cell edge.
- Shrinking the font to squeeze in more columns: at 10px the modal becomes unreadable and the thumbnail becomes noise.
- Synthesized bold (bundling only Regular and asking for 600), tofu for missing glyphs, fallback fonts with mismatched metrics mid-row.
- Decorative framing in a preview: gradient backgrounds, big shadows, macOS window chrome, large outer padding.
- Rendering `null`, `NaN`, `-` placeholders for empty cells instead of leaving them blank.

### (c) What survives scaling to about 300px wide

Tested by rendering at 2048px (2x of 1024) and downscaling to 300px (`mock-thumbnails-300px.jpg`); the scale factor is about 0.29 of the logical size, so 13px text becomes about 4px.

- **Text is unreadable, but each row of text becomes a grey bar.** That row texture plus white column gutters is what says "table". Keep rows dense enough (36px or less at 13px) that bars form a regular stripe pattern.
- **1px hairlines mostly vanish** (they average down to about 15% of their contrast). A design that relies only on hairlines looks like a page of text at 300px.
- **Area fills survive:** a header band at least as dark as about `#EEF0F3`, zebra stripes, a row-number gutter, and the grid's vertical lines all stay visible. The spreadsheet set is the most recognizable thumbnail; the default set is recognizable through its header band and text bars.
- **Right-aligned numeric columns** keep a distinctive ragged-left edge, which reads as "money".
- **A title at 17px semibold** is borderline readable at 300px; anything at 12px is not.
- **Empty margins are wasted:** a 32px canvas padding plus shadow costs about 10% of the thumbnail for no information.
- Practical rule: design for the 1024px modal, make sure the header band and row rhythm carry the thumbnail, keep the aspect near the host's thumbnail slot (about 16:10), and never add detail that only matters below 300px. If a host wants a truly legible thumbnail, expose a separate thumbnail mode (fewer columns, larger type) rather than compromising the main render.

### (d) Proposed token sets

All values are logical px at 1x; **render at scale 2** (a 1024 logical-wide canvas becomes a 2048px image). Colors are sRGB hex. "Edge" padding is the extra inset on the first and last column.

#### Default: "Ledger" (`mock-ledger-default.jpg`)

```yaml
canvas:
  width: 1024              # logical; output 2048px at scale 2
  target_aspect: 16:10     # add body rows until height reaches about 640, then stop
  background: "#FFFFFF"
  frame: { border: 1px "#E1E4E8", radius: 0, padding: 0, shadow: none }   # host supplies radius/shadow
font:
  family: "Inter, Noto Sans CJK SC, Noto Color Emoji, sans-serif"   # bundle Inter opsz=14 statics: 400, 600
  body:   { size: 13, weight: 400, color: "#1F2328" }
  header: { size: 12, weight: 600, color: "#5B6472", case: as-is, tracking: 0 }
  meta:   { size: 12, weight: 400, color: "#6B7280" }
  features: { quantity_columns: "tnum", dates: none, identifiers: "tnum" }
layout:
  row_height: 36
  header_height: 36
  cell_padding_x: 12
  edge_padding_x: 20       # first and last column
  min_col_width: 56
  max_text_col_width: 260  # numbers are never capped
  max_header_lines: 1
header:
  fill: "#F4F5F7"
  bottom_rule: 1px "#E1E4E8"
body:
  row_rule: 1px "#EDEFF2"  # horizontal only, full width
  zebra: none
  vertical_rules: none
  empty_cell: blank
numbers:
  align: right             # header right-aligned too
  minus: "U+2212"          # replace leading ASCII '-' in numeric columns
  reformat: false          # keep the CSV's own currency symbols, separators, decimals
  negative_color: null     # optional "#B42318"; off by default (statements are mostly debits)
  positive_color: null     # optional "#067647" for credits
text:
  overflow: ellipsis_end   # U+2026, measured trim
  whitespace: preserve     # optionally collapse runs of spaces
overflow:
  hidden_columns: { right_fade: 72px "#FFFFFF" 0% to 100%, note_in_footer: true }
  hidden_rows: { note_in_footer: true }
footer:
  height: 36
  top_rule: 1px "#E1E4E8"
  text: "{rows} rows · {cols} columns · {hidden_cols} more columns not shown"
  style: meta
```

Column-type rules used by the mock: a column is a **quantity** if more than 80% of non-empty values match a number/currency pattern (optional sign or parentheses, currency symbol, digits with separators, optional decimals or %); a column of **same-length pure digits** (MCC, ZIP, account or reference numbers) is an **identifier**: left-aligned with `tnum`. ISO dates are left-aligned.

#### Alternative: "Grid" (spreadsheet-like, `mock-grid-spreadsheet.jpg`)

```yaml
canvas: { width: 1024, background: "#FFFFFF", frame: { border: 1px "#C9CED6", radius: 0 } }
font:
  family: Inter            # or IBM Plex Sans 12px if a second family is bundled (tabular by default)
  body:   { size: 12, weight: 400, color: "#1F2328" }
  header: { size: 12, weight: 600, color: "#374151" }
layout: { row_height: 28, header_height: 28, cell_padding_x: 8, edge_padding_x: 8, min_col_width: 48, max_text_col_width: 220 }
header: { fill: "#F1F3F5", bottom_rule: 1px "#C9CED6" }
body:
  row_rule: 1px "#E3E6EA"
  vertical_rules: 1px "#E3E6EA"
  zebra: none
row_numbers:
  width: 40
  fill: "#F8F9FA"
  text: { size: 11, weight: 400, color: "#8A919C", align: right, inset: 8, features: tnum }
  divider: 1px "#E3E6EA"
numbers: { align: right, features: tnum, minus: "U+2212" }
overflow:
  hidden_columns: cut at canvas edge (no fade), like a spreadsheet window
  footer: none
```

#### Alternative: "Report" (document/card-like, `mock-report-card.jpg`)

```yaml
canvas:
  width: 1024
  background: "#EEF1F5"    # opaque, so JPG works; use only for share/social output
  padding: 32
card:
  background: "#FFFFFF"
  radius: 14
  border: 1px "#E4E7EC"
  shadow: [ "0 1px 2px rgba(16,24,40,0.07)", "0 10px 28px rgba(16,24,40,0.09)" ]
font:
  family: Inter
  title:  { size: 17, weight: 600, color: "#101828" }   # file name
  meta:   { size: 12, weight: 400, color: "#667085" }   # "20 rows · 23 columns", under the title
  body:   { size: 13.5, weight: 400, color: "#101828" }
  header: { size: 12.5, weight: 600, color: "#475467" }
layout: { title_block_height: 76, row_height: 38, header_height: 40, cell_padding_x: 12, edge_padding_x: 24 }
rules:                      # booktabs; all inset 24px to align with the text
  top: 2px "#344054"
  header_bottom: 1px "#344054"
  rows: 1px "#EAECF0"
  bottom: 2px "#344054"
header: { fill: none }
numbers: { align: right, features: tnum, minus: "U+2212" }
overflow: { hidden_columns: right_fade 72px, footer_note: "Showing the first {shown} rows and leftmost columns" }
```

A dark variant can reuse any set by swapping the ramp (for example background `#0D1117`, header fill `#161B22`, rules `#21262D`, body `#E6EDF3`, muted `#8B949E`), but a static preview cannot follow the viewer's theme, so light should stay the default.

### Recommendation in one line

Ship "Ledger" as the default, bundle Inter (two static weights from the `opsz=14` instance, about 130 KB each as a Latin subset or 333 KB full; Inter has no Reserved Font Name so subsetting is allowed), apply `tnum` and a true minus to quantity columns only, and render at 2x. Geist is the strongest alternative if a smaller gem and a sharper look matter more than currency coverage (it lacks ₩ ₺ ₫ ₦ ₿).
