# Rendering: Ledger theme, layout, typography, fonts, output

- **Status:** accepted; implemented in 0.1
- **Started:** 2026-11-15
- **Scope:** everything needed to build `Theme`, `Text`, `CellKind`, `Layout` and `Painter` (files `theme.rb`, `text.rb`, `cell_kind.rb`, `layout.rb`, `painter.rb` in the pinned code layout) so that `CsvPreview.render` produces the Ledger look shown in [`../design/mockups/mock-ledger-default.jpg`](../design/mockups/mock-ledger-default.jpg).
- **Conforms to:** the pinned public contract in [`README.md`](./README.md) (sections 9 and 10). Where this document adds members to `CsvPreview::Layout`, they are additions allowed by "exposes at least". Suggested changes to the overview are collected in [section 14](#14-proposed-changes-to-the-overview).

**How the claims here were checked.** Every behaviour marked *verified* was reproduced with a throwaway Ruby prototype of this design (the same algorithm, run through `ruby-vips`) on macOS 26 (Apple M1 Pro) with libvips 8.18.7, Pango 1.58.2, HarfBuzz 15.1.0, cairo 1.18.6, fontconfig 2.18.3, Ruby 3.4.12 and ruby-vips 2.3.0, rendering the mockup's own `statement.csv` and the fixtures named in section 12. Library-history claims come from the libvips `ChangeLog` and the `libvips/create/text.c` source of versions 8.9 to 8.18. Behaviour on Ubuntu is marked *to confirm in CI* where it could not be run locally.

---

## 1. Pipeline and units

```
Sample ──> Layout ──────────────────────────────> Painter ──> bytes
            │  CellKind (per column)                │  canvas, fills, rules, frame
            │  Text: display strings, one libvips   │  one n-ary composite of the
            │        text call per string (the      │  text images built by Layout
            │        image is the measurement)      │  plus the fade layer
            │  widths, visible columns, peek,       │  flatten, encode
            │  truncation, footer, output size      │
```

- **Logical px** are the units of theme tokens (the mockup's units). **Device px** are output pixels.
- `px(v) = (v * scale).round` converts a token to device px. It is applied once per token, never to sums, so rounding never accumulates. Every rule and border is `max(1, px(width))`.
- Text is measured in device px (it is rendered at `size * scale`), so `Layout` works in device px internally. Public widths are reported in both units (section 6.11).
- `scale` is expected to be an Integer from 1 to 4 (see section 14). Non-integer scales would make 1-logical-px rules land on half pixels.

`Layout` does all measuring and keeps the rendered text images; `Painter` never calls `Vips::Image.text`, it only composites the images `Layout` built. This is what keeps the cost at one libvips text call per drawn string (section 10).

## 2. Theme

### 2.1 Structure

`CsvPreview::Theme` is an immutable value object (`Data.define`) holding every colour, size and structural switch the layout and painter use. Neither `Layout` nor `Painter` contains a visual literal: no colours, sizes, weights or paddings appear outside `theme.rb`. Strings shown in the image ("Empty file", "rows", "columns") are not theme data; they live in one frozen hash, `CsvPreview::Layout::STRINGS`, so translation later is a one-file change.

```ruby
module CsvPreview
  Theme = Data.define(:name, :font_family, :body_size, :body_weight, ...) do
    def rgb(token) = ...        # "#1F2328" -> [31, 35, 40]
  end
  Theme::LEDGER = Theme.new(name: :ledger, ...).freeze
  Theme::ALL    = { ledger: Theme::LEDGER }.freeze
  def Theme.fetch(name) = Theme::ALL.fetch(name) { raise ArgumentError, "unknown theme #{name.inspect}" }
end
```

Validation at construction: colours match `/\A#\h{6}\z/`; sizes, heights, paddings and widths are positive Integers (rule and frame widths may be 0, meaning "not drawn"); `fade_exponent` is a positive Float; `min_width <= max_width`. These values are interpolated into Pango markup attributes (section 4.2), so validation is also what keeps markup attributes safe.

**How Grid and Card are added later, as data.** Each needs a few structural switches Ledger does not use: vertical rules (`vertical_rule_width`, `vertical_rule_color`), a row-number gutter (`gutter_width`, `gutter_fill`, `gutter_text_color`), overflow style (`overflow: :fade` or `:clip`), whether a footer is drawn (`footer: true`), and for Card a title block, canvas padding, corner radius and shadow. The rule for adding them: each new member gets a default that reproduces Ledger exactly (0, `nil`, `:fade`, `true`), so `Theme::LEDGER` and its golden images do not change, and the painter gains the branch for that switch in the same change. The MVP does not define members it does not draw.

### 2.2 `Theme::LEDGER` tokens

Logical px at `scale: 1`; the "at scale 2" column is what the default render uses. Values match [`../design/mockups/ledger.tokens.json`](../design/mockups/ledger.tokens.json) except where the last column says otherwise; where they differ, this table wins.

| Token | Value | At scale 2 | Notes |
|---|---|---|---|
| `font_family` | `"Inter"` (bundled) | | Files in section 5. `font:` replaces the family only. |
| `body_size`, `body_weight` | 13, 400 | 26 px | Data cells. |
| `header_size`, `header_weight` | 12, 600 | 24 px | Header labels, original case, no tracking. |
| `footer_size`, `footer_weight` | 12, 400 | 24 px | Footer and the empty-file message use `muted_color`. |
| `number_features` | `"tnum"` | | Applied to every cell and the header of `:number` columns, and to the footer. |
| `true_minus` | `true` | | Sign hyphen becomes U+2212 in number cells (section 4.1). |
| `text_color` | `#1F2328` | | 15.8:1 on white. |
| `muted_color` | `#6B7280` | | Footer, messages. 4.83:1 on white. |
| `header_text_color` | `#5B6472` | | 5.24:1 on the header fill. |
| `header_fill` | `#EEF0F3` | | **Changed** from the mockup's `#F4F5F7` for thumbnails (section 8). |
| `header_rule_color`, `header_rule_width` | `#DDE1E6`, 1 | 2 px | **Changed** from `#E1E4E8` to stay one step darker than the fill. Drawn at the bottom of the header band. |
| `row_rule_color`, `row_rule_width` | `#EDEFF2`, 1 | 2 px | Between data rows only, full width, horizontal only. |
| `footer_rule_color`, `footer_rule_width` | `#E3E6EA`, 1 | 2 px | Top edge of the footer band. |
| `frame_color`, `frame_width` | `#E3E6EA`, 1 | 2 px | Inside the image bounds, all four sides. No radius, no shadow. |
| `background` | `#FFFFFF` | | Canvas, body, footer. Output has no alpha. |
| `header_height` | 36 | 72 px | |
| `row_height` | 36 | 72 px | About 2.75 times the body size. |
| `footer_height` | 36 | 72 px | Includes its top rule. |
| `cell_padding` | 12 | 24 px | Left and right inside every column box. |
| `edge_padding` | 20 | 40 px | Distance from the image's outer edge to the first column's text, and from the last column's text to the right edge when everything fits. |
| `min_column_width` | 56 | 112 px | Whole column box, padding included. |
| `max_column_width` | 260 | 520 px | Whole column box; **text columns only**. Number columns are never capped. |
| `min_width` | 320 | 640 px | New. Smallest image width (section 6.6). |
| `max_width` | 1024 | 2048 px | New as a token (was the mockup canvas width). The layout width cap is `min(px(max_width), max_width_px)`. |
| `fade_width` | 72 | 144 px | Right-edge fade when columns are hidden. |
| `fade_exponent` | 1.5 | | Alpha of the fade at fraction `t` of its width is `255 * t**1.5`. |
| `peek_width` | 120 | 240 px | New. Most space given to the partially visible column (section 6.5). |
| `empty_body_rows` | 3 | | New. Body height of the empty-file image, in rows. |

Derived value used below: `inset = edge_padding - cell_padding` (8 logical, 16 px): the gap between the image edge and the first column box, which together with the box's own padding puts text 20 logical px from the edge.

### 2.3 Geometry

All values device px at scale 2, for the mockup's `statement.csv` (23 columns, 20 rows):

```
x=0 ┌────────────────────────────────────────────────────────────────────┐ y=0   frame (2)
    │ inset│ pad text pad │ pad text pad │ ... │ pad peek...  ░░▒▒▓▓██│      │
    │  16  │◄─ column 0 ─►│◄─ column 1 ─►│     │◄── peek ──►│◄ fade ►│      │ header band 72, fill #EEF0F3,
    │══════════════════════════════════════════════════════════════════│      │   rule (2) at its bottom
    │      │ 2026-03-14   │ 2026-03-15   │ ... │            ░░▒▒▓▓██│      │ row 0, 72
    │──────────────────────────────────────────────────────────────────│      │ row rule (2) at top of rows 1..n-1
    │      │ ...          │              │     │            ░░▒▒▓▓██│      │
    │──────────────────────────────────────────────────────────────────│      │ footer rule (2)
    │  20 rows · 7 of 23 columns                                         │      │ footer 72 (only when something is hidden)
    └────────────────────────────────────────────────────────────────────┘ y=1588 frame (2)
                                                                  x=2048
```

- `y0 = frame`. Header band `[y0, y0 + header)`; its rule occupies the band's last `rule` px.
- Row `i` (0-based) occupies `[y0 + header + i*row, + row)`; for `i >= 1` its rule occupies the row's first `rule` px.
- Footer, when present, starts at `y0 + header + n*row`; its rule occupies its first `rule` px.
- Height = `2*frame + header + n*row + (footer ? footer_height : 0)`.
- Column `j`'s box is `[x_j, x_j + w_j)` with `x_0 = inset`; text sits inside `[x_j + pad, x_j + w_j - pad)`.
- The fade zone is `[W - frame - fade, W - frame)`, from the top of the header band to the bottom of the last row. It never covers the footer or the frame.

## 3. Cell kinds

`CellKind` (`cell_kind.rb`) is specified in [`parsing-and-safety.md`](./parsing-and-safety.md) section 6: `CellKind.cell(s)` returns `:empty`, `:number` or `:text`, and `Sample#column_kinds` gives `:number` or `:text` for each kept column (at least 80% numbers among non-empty, non-placeholder cells, and not an identifier-like column of same-length integers). Rendering uses both results and adds nothing to the classification.

What the kind changes:

| | `:number` column | `:text` column |
|---|---|---|
| Alignment of cells and header | right | left |
| Font features | `tnum` on every cell and the header | none (dates keep proportional figures, which look better in Inter) |
| True minus | on cells where `CellKind.cell` is `:number` | never |
| Width cap | none (`min_column_width` only) | `max_column_width` |
| Truncation of cells | never (except the degenerate case in 6.5) | measured ellipsis |

Other cells inside a `:number` column (placeholders such as `N/A` or `-`, or stray text) are right-aligned with the rest of the column and keep their text unchanged.

## 4. Text (`text.rb`)

### 4.1 Display strings

`Layout` draws `Sample` strings, which the Sanitizer has already made single-line and literal: line breaks and tabs collapsed to one space, control characters, bidi controls and zero-width format characters removed, runs of combining marks cut to 8, edges trimmed, and anything longer than `max_cell_chars` grapheme clusters cut to `max_cell_chars - 1` clusters plus `…` ([`parsing-and-safety.md`](./parsing-and-safety.md) section 5). That is why a Ledger row is always one line: libvips would otherwise draw an embedded newline as a second line (*verified*). `Layout` changes the strings only in these ways:

1. **Column letters** replace the header labels when the file has no header row (6.2).
2. **True minus.** In a `:number` column, in a cell where `CellKind.cell(s) == :number`, every U+002D becomes U+2212. CellKind's number pattern allows a hyphen only as the sign (leading, after a currency, or trailing as in `12.00-`) or in an exponent, so every hyphen in such a cell is a minus sign. `-$1,284.50` becomes `−$1,284.50`, `$-12.00` becomes `$−12.00`, `12.00-` becomes `12.00−`. Why: Inter's ASCII hyphen under `tnum` sits in a figure-width slot and leaves a visible gap (*verified*: `-$1,284.50` and `−$1,284.50` are both 149 px wide at 26 px with `tnum`, but only the true minus fills the slot). Cells such as `-2+3` and placeholders such as `-` are not `:number` and are never changed.
3. **Measured truncation** to the column width (section 4.5), after widths are known.

Internal runs of spaces are kept as written. `Layout#cell_text` and `Layout#header_text` return the final strings. Code that needs the untouched values uses `layout.sample.rows`.

### 4.2 Pango markup and escaping

libvips `text` always parses its input as Pango markup and fails the whole call on invalid markup. *Verified*: `a < b` and `AT&T` raise `Vips::Error` "text: invalid markup in text", and unescaped `<b>bold</b>` or `<span foreground="red">x</span>` render bold or red, which is markup injection. Every string goes through:

```ruby
ESCAPES = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&apos;" }.freeze
def self.escape(s) = s.gsub(/[&<>"']/, ESCAPES)     # same set as GLib's g_markup_escape_text
```

and is wrapped in one span whose attribute values come only from the validated theme, never from cell content:

```ruby
%(<span weight="#{style.weight}" foreground="#{style.color}"#{' font_features="tnum"' if style.tnum}>#{escape(s)}</span>)
```

*Verified*: after escaping, all of `a < b`, `AT&T`, `<b>bold</b>`, `&amp;`, `<span foreground="red">x</span>` and strings with quotes render literally. Control characters U+0001 to U+001F do not break the markup parser (they draw as hex boxes), but NUL makes ruby-vips raise `ArgumentError` ("string contains null byte") before libvips is called. The Sanitizer removes both; `Text` still replaces any NUL with U+FFFD and scrubs invalid UTF-8, because it also draws strings that do not come from the Sanitizer (footer, messages, column letters, and anything a future caller passes).

### 4.3 One call measures and draws

Every drawn string is rendered exactly once, with one exception: on a host that draws subpixel (coloured) text edges, a string that can contain a colour glyph is drawn a second time in a contrasting colour, with the same layout, to tell its emoji from its text (section 9, "Greyscale antialiasing"). That second drawing is not a measurement and costs a counted call (4.7, 10):

```ruby
Vips::Image.text(markup, font: "#{family}, #{size_px}", fontfile: path_or_nil, dpi: 72, rgba: true, **align_opts)
```

- `dpi: 72` makes the font size a pixel size. Sizes are already multiplied by `scale`.
- `rgba: true` returns a 4-band sRGB image with the markup colour applied, and is required for colour emoji.
- The returned image is cropped to the **ink** rectangle. Its `xoffset` and `yoffset` give the ink's left and top relative to the layout origin (libvips sets these to the ink offsets since 8.8).
- The image is kept in a `Run` and later composited by the painter, so **measuring and drawing use the same call with the same font, size, weight and features**. There is no separate measurement path that could disagree (for example by forgetting `tnum`, which changes `1,111.11` from 74 px to 114 px at 26 px, *verified*).

```ruby
Run = Data.define(:string, :image, :xoffset, :yoffset, :extent, :align)
```

**Left-aligned strings** (text columns, the footer, messages) are rendered without `width`. `extent = xoffset + image.width` is the distance from the origin to the ink's right edge; the image is placed at `x = cell_text_left + xoffset`.

**Right-aligned strings** (number columns and their headers) need the *logical* right edge, not the ink edge: digits have different right side bearings, so aligning ink edges misaligns decimal points by 1 to 2 px in Inter and more in fonts with narrow `1` glyphs. libvips does not report logical width, so `Text` renders right-aligned strings with `width: RIGHT_BOX, align: :high` where `RIGHT_BOX = 32_768`. Pango then places the line's logical right edge exactly at `RIGHT_BOX`, and `xoffset` becomes `RIGHT_BOX - logical_width + left_bearing`. So:

- `extent = RIGHT_BOX - xoffset` (space needed from the ink's left edge to the logical right edge),
- the image is placed at `x = cell_text_right - RIGHT_BOX + xoffset`.

*Verified*: for `10.00`, `10.01`, `10.11` and `$4,200.00` the ink stops 1 to 2 px short of the logical edge, and the trick aligns the logical edges. `RIGHT_BOX` is far larger than any capped string (60 clusters at 26 px is under 2,000 px), so the `width` never causes wrapping; `RIGHT_BOX * 1024` still fits Pango's 32-bit units.

**Right-to-left guard.** Pango sets each paragraph's direction from its first strong character and swaps left and right alignment for right-to-left paragraphs. *Verified*: `غير متوفر` rendered with `align: :high` comes back with `xoffset = 0`, so the formula above would report an extent of 32,768 px and blow the column up. Rule: if a right-aligned render returns `xoffset + image.width <= RIGHT_BOX / 2`, the paragraph was right-to-left; treat it as left-aligned for measurement (`extent = xoffset + image.width`) and place it so its ink right edge sits on `cell_text_right` (`x = cell_text_right - image.width`).

### 4.4 Blank strings

libvips raises "no text to render" when a string has no ink. *Verified* for spaces, U+00A0, U+200B, U+2063, U+00AD, U+034F, U+FE0F, U+180E, U+3000, U+3164, tag characters, and U+2800 (Braille blank). Rules:

1. Strings matching `/\A[\p{Space}\p{Default_Ignorable_Code_Point}]*\z/` are blank: no call, no `Run`, extent 0. This catches everything above except U+2800.
2. If libvips still raises an error whose message contains `no text to render`, the string is treated as blank too.
3. Any other `Vips::Error` from `text` becomes `CsvPreview::RenderFailed`.

Blank cells draw nothing. Empty cells are never filled with placeholders such as "null" or "-".

### 4.5 Ellipsis truncation

libvips has no ellipsize option, so `Text.fit` trims by measuring. Inputs: the full `Run` (already rendered while measuring natural widths), the style and alignment, and `max_extent` (the column's text width in device px). The ellipsis is U+2026 appended to a prefix of whole grapheme clusters with trailing spaces removed (`"COSTCO WHSE #0145 MOUNTAIN…"`, never `"MOUNTAIN …"`).

```text
clusters = string.grapheme_clusters            # the string is already capped at max_cell_chars
n        = clusters.size
fits(k)  = k == 0 or extent(render(clusters[0, k].join.rstrip + "…")) <= max_extent
k0       = floor((max_extent - extent("…")) * n / full.extent), clamped to 0..n-1
gallop from k0 (up if fits(k0), down otherwise) with steps 1, 2, 4, ... until the answer is bracketed,
then binary-search the bracket for the largest k with fits(k).
result   = render(prefix(k) + "…")             # k == 0 gives "…" alone
```

- Grapheme safety: cutting only between `String#grapheme_clusters` boundaries means emoji ZWJ sequences, flags, skin-tone modifiers and base letters with combining marks are never split (*verified* with `Team 👩‍👩‍👧‍👦 lunch 🇯🇵🇺🇸 café`: every result is a cluster prefix of the source).
- Cost: the proportional first guess is usually within one cluster, so a truncated cell costs 2 to 3 extra calls plus the shared `…` measurement (*verified*: 4 to 5 calls per truncated string including the original measurement, down from 5 to 7 with plain bisection). Worst case is `2 * ceil(log2 n) + 2` probes.
- The probe images are discarded except the winner, which becomes the cell's `Run`.
- If even `…` alone does not fit (impossible at default sizes), the cell draws nothing.
- Right-aligned strings (number headers) truncate the same way with right alignment; the ellipsis ends up at the logical end, which for right-to-left text is the visual left. That is correct.

### 4.6 Vertical placement

All strings in a band share one baseline and are optically centred on cap height:

```ruby
Metrics = Data.define(:cap_top, :cap_height)   # per (family, size_px, weight); from rendering "H"
line_top = band_top + ((band_height - cap_height) / 2.0).round - cap_top
y        = line_top + run.yoffset
```

`yoffset` is the ink top relative to the line's top, so every run placed this way sits on the same baseline, including emoji, CJK and fallback-font runs (*verified*: at 26 px, `H`, `2026`, `AMZN` and `😀` all end on the same baseline, `H` has `cap_top = 6`, `cap_height = 20`). This reproduces the mockup's centring within 1 px. Header bands, rows and the footer each use their own style's metrics and full band height.

### 4.7 Caching

- **Per render:** a `Text::Renderer` object created by `Layout` caches `Run`s by `[string, style, align]`. Repeated values ("USD", the same date) cost one call. It also counts calls (`Layout#text_calls`, for tests, and the basis of REN-20's budget) and checks the `Deadline` at the first call at or after each multiple of 32 counted calls. The count is the number of `Vips::Image.text` calls made: a string that can contain a colour glyph (the `COLOR_GLYPH` character set of section 9) counts 2 on a subpixel host and 1 elsewhere, so the count can step over a multiple of 32 and the check is by threshold, not by modulo.
- **Per process:** `Metrics` per style, the `…` extents, and the warm-up results (section 5.4), each computed once under a `Mutex` and stored frozen. Nothing else is shared between renders, so threads never contend on Ruby state.
- libvips' own operation cache also returns identical `text` calls; the gem leaves the libvips cache settings alone because they are application-wide.

### 4.8 Emoji, CJK, right-to-left text, missing glyphs

- **Fallback.** Pango asks fontconfig for each character Inter lacks and uses the best installed font, per character. Inter 4.1 covers Latin (including Vietnamese), Cyrillic and Greek, U+2212, U+2026, U+00B7, U+2022 and every common currency sign; it has no Arabic, Hebrew, CJK or emoji (*verified* with fontTools). *Verified* on macOS: Japanese, Arabic and Hebrew render through system fonts and emoji render in colour (Apple Color Emoji through fontconfig and FreeType). Fallback fonts have different metrics (Arabic came out visibly smaller); that is acceptable.
- **Servers.** *Verified* in a `ruby:3.4-slim` container (Debian, the base image of Rails' generated Dockerfile) after `apt-get install --no-install-recommends libvips`: the only fonts present are DejaVu, so Arabic and Hebrew render, while emoji, Chinese, Japanese, Korean, Thai and Devanagari draw as hex boxes. Adding `fonts-noto-color-emoji` and `fonts-noto-cjk` fixes emoji and CJK; adding `fonts-noto-core` fixes Thai, Devanagari and most other scripts. Hex boxes are wider than the glyphs they replace, so columns can come out wider. Nothing fails either way, which is the requirement. The README lists the packages and their installed sizes.
- **Missing glyphs** render as Pango's hex box (*verified* for U+10FFFD). Nothing raises.
- **Right-to-left in a left-aligned cell.** Each cell is its own Pango layout, so bidi reordering is confined to the cell (the guarantee the Sanitizer section relies on), and the Sanitizer has already removed overrides, embeddings, isolates and directional marks. A right-to-left cell in a text column is drawn left-aligned (its ink starts at the cell's text edge) with its internal order right to left (*verified*: `عربي text mixed` displays as `text mixed عربي` at the cell's left). Truncation puts the ellipsis at the logical end, the visual left. Right-to-left strings in number columns are handled by the guard in 4.3.
- **Vertical overflow.** Stacked combining marks (the Sanitizer keeps up to 8) or tall fallback glyphs can extend beyond a row. The painter clips every run to its cell box (section 7.2), so nothing paints over a neighbouring row or rule.

## 5. Fonts

### 5.1 What to bundle

Inter **4.1** (release `v4.1`, 2024-11-16, font version string `Version 4.001;git-9221beed3`), files taken unmodified from the official release archive `Inter-4.1.zip`:

| Gem path | Source in `Inter-4.1.zip` | Bytes | SHA-256 |
|---|---|---|---|
| `fonts/Inter-Regular.ttf` | `extras/ttf/Inter-Regular.ttf` | 411,640 | `40d692fce188e4471e2b3cba937be967878f631ad3ebbbdcd587687c7ebe0c82` |
| `fonts/Inter-SemiBold.ttf` | `extras/ttf/Inter-SemiBold.ttf` | 419,744 | `78a843fade9d4612a5567302fb595b56976eb5fcebf4fea5a5912d638bafcde3` |
| `fonts/OFL.txt` | `LICENSE.txt` | 4,380 | `262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a` |

- **Licence.** SIL Open Font License 1.1, "Copyright (c) 2016 The Inter Project Authors", with **no Reserved Font Name**. Bundling in an MIT gem is allowed as long as `OFL.txt` ships beside the fonts and the fonts are not sold on their own. A test asserts the three checksums so the files cannot change silently.
- **Why static files.** Both are TrueType-hinted static instances of Inter's text optical size (2,937 glyphs, 2,852 code points, all the OpenType features used here: `tnum`, `case`, `zero`, `ss01` and more). Together they are 831 KB. The variable `InterVariable.ttf` is 880 KB, so it saves nothing, and picking weight 600 from it depends on FreeType variation support, cairo, and fontconfig named-instance matching; older stacks fall back to the default instance or synthesise bold. Static files behave the same everywhere.
- **Why not subset.** A Latin subset would save about 550 KB but would push Cyrillic, Greek and Vietnamese text onto fallback fonts with different metrics. The gem is small anyway; keep the full files.
- **Weights.** The SemiBold file names its typographic family "Inter", subfamily "SemiBold", `usWeightClass` 600 (legacy family "Inter SemiBold"). fontconfig therefore matches family `Inter` at weight 600 to it (*verified*: markup `weight="600"` renders 307 px wide, identical to `Inter SemiBold 26`, against 298 px for Regular).

### 5.2 Loading with libvips

```ruby
FONT_DIR = File.expand_path("../../fonts", __dir__)
REGULAR  = File.join(FONT_DIR, "Inter-Regular.ttf")
SEMIBOLD = File.join(FONT_DIR, "Inter-SemiBold.ttf")

Vips::Image.text(markup, font: "Inter, 26", fontfile: REGULAR, dpi: 72, rgba: true)
```

- `fontfile` makes libvips call `FcConfigAppFontAddFile` once per path (it keeps a set of added paths) and, from 8.13, clear Pango's font cache. The gem registers both files before it draws anything else (5.4). On libvips before 8.13 that is not enough: Pango keeps the font list it read at the first draw, so weight 600 would draw with Regular. 5.4 describes the refresh draw that fixes it. `fontfile` registers the file; it does not select it. Selection still happens by family name, size and weight.
- Each call passes the file that matches the style's weight (Regular for 400, SemiBold for 600). The weight itself is set in the markup span, not in the font string.
- The font string is `"#{family}, #{size_px}"`. The comma ends the family list, so a family whose name ends in a style word ("Foo Bold") is not misread as family "Foo" at weight bold (*verified*: `"Inter Bold, 26"` is looked up as a family called "Inter Bold"). `"Inter, 26"` and `"Inter 26"` render identically.

### 5.3 macOS: libvips ignores `fontfile` unless `PANGOCAIRO_BACKEND=fontconfig`

libvips creates its text font map with `pango_cairo_font_map_new()`, which picks the CoreText backend on macOS. CoreText does not see fonts added to fontconfig, so `fontfile` has no effect. *Verified* on libvips 8.18.7:

| Case | Width of a 32-character probe at 26 px |
|---|---|
| `font: "Inter 26", fontfile: Inter-Regular.ttf`, variable unset | 388 px, identical to `Helvetica 26`: Inter was silently replaced |
| Same, with `PANGOCAIRO_BACKEND=fontconfig` | 426 px: Inter |
| Variable set from Ruby (`ENV[...] = ...`) after `require "vips"` but before the first `text` call | 426 px: works |
| Variable set from Ruby after any earlier `text` call in the process | 388 px: too late |

libvips 8.18.7 prints no warning in this case. Pango reads the variable each time a font map is created, and libvips creates its font map once, at the first `text` call (libvips 8.11, 8.12 and 8.14.2 onward keep one private font map; 8.13.0 to 8.14.1 use Pango's per-thread default map, which is also created on first use).

What the gem does:

1. When `lib/csv_preview.rb` is loaded (before, and independent of, loading ruby-vips, which is loaded lazily; see the overview section 5), if `RUBY_PLATFORM` contains `darwin` and `ENV["PANGOCAIRO_BACKEND"]` is unset or empty, set it to `"fontconfig"`. Loading happens during `require "csv_preview"`, normally at boot under Bundler, before threads start, so the `setenv` call cannot race with `getenv` in another thread. The README says to require the gem at boot rather than lazily inside a request.
2. Never overwrite a value the application set, and never touch it on other platforms. On Linux the fontconfig backend is already the default. Windows is not supported.
3. Side effect to document: on macOS this also switches any other PangoCairo user in the process (another gem's `Vips::Image.text`, librsvg text in SVGs) from CoreText to fontconfig. fontconfig sees the macOS system fonts, so those callers still work, but font choice can differ. Applications that need CoreText can set the variable themselves, and then the bundled Inter will not load on macOS (the self-check below will say so).
4. If something used libvips `text` before the gem was loaded, the setting comes too late. The self-check in 5.4 detects that and warns once with the remedy (`PANGOCAIRO_BACKEND=fontconfig` in the environment, or require `csv_preview` earlier). Rendering continues with the fallback font rather than failing.

### 5.4 Registration is process-global; warm-up and self-check

- `FcConfigAppFontAddFile(NULL, ...)` adds the file to the process's current fontconfig configuration. It is **process-global and permanent**: every later fontconfig lookup in the process can see the family, including other libraries' (*verified*: after one call with `fontfile`, calls without it still get Inter). It is shared by Puma and Sidekiq threads and inherited by forked workers.
- **Thread safety inside libvips.** On libvips 8.11, 8.12 and 8.14.2 onward, one global mutex (`vips_text_lock`) covers adding font files, setting the font map resolution, layout and rasterising, so concurrent `text` calls are serialised and safe. On 8.13.0 to 8.14.1 the mutex covers only font-file registration and each thread renders with its own Pango default font map, which is also safe. *Verified*: 8 threads rendering 5 fixtures 10 times each produced bytes identical to serial renders. On the versions with the global mutex, text rendering does not run in parallel across threads; compositing and encoding always do.
- **Same-name fonts.** If the host also has a system font called "Inter" (for example a different version), fontconfig must still choose the bundled file. *Verified* on fontconfig 2.18.3 with a decoy font renamed "Inter" installed as a system font: the bundled file won regardless of the decoy's version number or registration order. *To confirm on Ubuntu's fontconfig 2.15 (24.04) and 2.13 (22.04) in CI*, with `fonts-inter` installed.
- **`Text.warm_up!`** runs once per process, under a `Mutex`, on the first render (and may be called at boot; see section 14):
  1. Check `Text.supported?`, else raise `RenderFailed` ("libvips was built without text (Pango) support"). `Text.supported?` is `Vips.at_least_libvips?(8, 12) && Vips.type_find("VipsOperation", "text") != 0`, memoised. It never renders anything, so it is cheap and safe to call from a web request; the Active Storage previewer's `accept?` uses it.
  2. Register both files by rendering one character with each `fontfile`. **Before libvips 8.13 only:** libvips adds a font file to fontconfig without telling Pango, and Pango keeps the font list it read at the first draw, when only the Regular file was registered, so weight 600 then draws with Regular (*verified* on libvips 8.12.1, Ubuntu 22.04). A refresh draw fixes it: one more `text` call at `dpi: 73` makes libvips set its font map's resolution, which drops Pango's cached list, and the next draw reads both files. Every other draw uses 72 dpi.
  3. Probe `font_features`: render `<span font_features="tnum">0</span>`. If libvips reports invalid markup (Pango older than 1.38), disable `tnum` process-wide and warn once. Rendering still works with proportional figures.
  4. **Antialiasing probe:** draw `Hamburgefonstiv` at 26 px in `#808080`, flatten it over white, and take the largest summed channel difference of any pixel. Above 24 means the host draws subpixel edges (section 9); the process then corrects every run. Greyscale hosts measure 0, subpixel hosts about 160.
  5. **Self-check** (two probes, both drawn at 100 px, right-aligned (4.3); `extent` is read from each). *Tabular:* `0000000000` with `tnum`: with the bundled Inter 4.1 about 644 px (10 figures of 1328/2048 em, minus the first bearing), accepted from 630 to 660 px; Helvetica gives 557 px. DejaVu Sans and Verdana also measure 634 px there, so that probe alone cannot tell them from Inter (*verified* on Ubuntu 22.04, where DejaVu Sans is the default sans). *Proportional:* `1111111111` without `tnum`: Inter's default figures are proportional (about 406 px, accepted from 380 to 440 px) while DejaVu Sans and Verdana have tabular figures (about 630 px). Both probes must pass. Otherwise set `bundled_font_active?` to false and `warn` once with the macOS remedy from 5.3. The self-check runs on the first render that uses the bundled font, so applications that always pass `font:` never see the warning.
  6. Compute and cache `Metrics` for the three Ledger styles.
- Every later call still passes `fontfile:` (a cheap set lookup inside libvips), so behaviour does not depend on warm-up order.

### 5.5 The `font:` option

`font: "DejaVu Sans"` replaces only the family. Effects:

- No `fontfile` is passed; fontconfig resolves the family among system fonts. An unknown family silently falls back to fontconfig's default sans (*verified*), which is acceptable for an explicit configuration choice.
- Weights still come from the theme through markup. A family without a 600 weight gets fontconfig's nearest (often bold 700) or a synthesised bold.
- `tnum` is still requested; fonts whose figures are tabular by default (DejaVu Sans, IBM Plex Sans) are unaffected, and fonts without the feature simply ignore it. Because measuring and drawing are one call, layout stays correct with any font.
- The value may be a comma-separated family list ("Helvetica Neue, Arial"). Configuration should reject strings longer than 200 characters or containing control characters. The value is a Pango font description, not markup, so it cannot inject markup.
- The self-check and the golden images apply only to the bundled Inter.

## 6. Layout algorithm (`layout.rb`)

### 6.1 Inputs

`Sample` (headers or `nil`, rows, `column_count`, `total_columns`, `total_rows` or `nil`, `rows_read`, `rows_truncated?`, `column_kinds`, `empty?`), the resolved options (`max_width_px`, `max_height_px`, `max_cell_chars`, `scale`, `theme`, `font`), and the `Deadline`. Let `s = scale`, `frame = max(1, px(frame_width))`, `rule = max(1, px(row_rule_width))`, `pad = px(cell_padding)`, `edge = px(edge_padding)`, `inset = edge - pad`, `fade = px(fade_width)`.

The **width cap** is `W_cap = min(px(theme.max_width), max_width_px)`. `max_width_px` remains the hard pixel cap from the overview; `theme.max_width` keeps the layout the same when `scale` changes (at `scale: 1` the image is at most 1024 px wide, not 2048).

### 6.2 Step 1: special cases

- `sample.empty?`: build the **empty-file layout** (6.9) and stop.
- `sample.headers` is `nil`: header labels are spreadsheet column letters `A`, `B`, ..., `Z`, `AA`, ... for each kept column, so every Ledger image keeps its header band (the band is what survives in thumbnails). Aligned like their columns.

### 6.3 Step 2: rows shown

```ruby
rows_fit   = (max_height_px - 2*frame - px(header_height) - px(footer_height)) / px(row_height)   # integer division
rows_shown = [sample.rows.size, rows_fit].min          # sample.rows.size is already <= max_rows
```

The footer is always reserved when counting. If all rows fit with the reservation, it cost nothing; if they do not, rows are hidden and a footer is needed anyway. At the defaults `rows_fit` is 34, so `max_rows` (20) decides. With `max_rows: 50` the image stops at 34 rows and 2,596 px. If `sample.rows` is empty (a header-only file) the **header-only layout** applies (6.9).

### 6.4 Step 3: natural column widths

Process kept columns left to right. For column `j`:

1. Build display strings (4.1 items 1 and 2) for the header and the `rows_shown` cells.
2. Render each with the column's style and alignment (`:number`: right, `tnum`; `:text`: left). Header style is `header_size`/`header_weight`/`header_text_color`; body style is `body_size`/`body_weight`/`text_color`.
3. Natural width:

```ruby
cells  = max extent of the column's cell runs (0 if all blank)
header = extent of the header run (0 if blank)
w_j = if kind == :number
        [[cells, [header, px(max_column_width) - 2*pad].min].max + 2*pad, px(min_column_width)].max
      else
        ([cells, header].max + 2*pad).clamp(px(min_column_width), px(max_column_width))
      end
```

So a number column is always wide enough for its widest number (numbers are never truncated by width), while a long header over a number column is capped like text and may be truncated. Text columns are clamped to the min and max widths.

4. Keep a running total `x = inset + w_0 + ... + w_j`. **Stop measuring** as soon as `x + inset > W_cap`: from then on not everything fits, and the visible columns and the peek column are all among the columns measured so far (any column that crosses `W_cap` also fails the stricter visibility test below). Columns after that are never drawn, so they are never rendered. Call `deadline.check!` between columns.

### 6.5 Step 4: visible columns, peek column, fade, width

**Case A: everything fits** (`inset + Σw + inset <= W_cap` after all kept columns). All columns are visible, there is no peek and no fade, and the width before 6.6 is `W = 2*inset + Σw`.

**Case B: not everything fits.** `W = W_cap`. Let `limit = W - frame - fade` (where the fade starts).

1. Column `j` is **fully visible** when its text area ends before the fade starts: `x_j + w_j - pad <= limit`. Its right padding may extend under the fade; its text never does. Walk columns in order and stop at the first that fails. Column 0 is always visible; if it fails the test (only possible with a very small `max_width_px`), clamp `w_0 = limit - x_0 + pad` and truncate its cells, numbers included. This is the only case where a number is truncated.
2. The first column that is not fully visible is the **peek column** (`k = visible_columns`). It shows the reader that the table continues. If the only kept column is column 0 (no peek exists), clamp it to `W - 2*inset` instead, and draw no fade.
3. **Cap the peek.** The peek starts at `x_k` and runs to the inner right edge. If that space, `(W - frame) - x_k`, exceeds `px(peek_width)`, distribute the excess evenly across the visible columns (remainder to the last), which moves the peek right until it has exactly `px(peek_width)`. Wider visible columns show more of their text. Without this cap a 260-wide text column could sit almost fully readable behind a 72-wide fade while the footer says it is hidden (*verified* on a 12-column fixture of long text: before the cap the fourth column was mostly legible; after it, the peek is a clear glimpse).
4. The peek column is drawn **left-aligned whatever its kind**: each run is placed at `x_k + pad + xoffset` and clipped at `W - frame`. Right-aligned numbers in a column wider than the remaining space would otherwise be clipped away entirely, leaving an empty band. Peek cells are not ellipsis-truncated (they are cut by the image edge under the fade), so they cost no extra calls.
5. The fade covers `[W - frame - fade, W - frame)` from the top of the header band to the bottom of the last row.

Columns hidden only by `max_columns` (all kept columns fit, but `total_columns > column_count`) produce no peek and no fade, because the Sample holds no data for them; the footer reports them.

### 6.6 Step 5: small tables fill the frame

The image is the table: no canvas margin, no centring in a larger white area. Width is the table's natural width, raised to a minimum so a tiny table still reads as a table rather than a sliver:

```ruby
footer_need = footer_run ? footer_run.extent + 2*edge : 0
W_target    = [W, px(theme.min_width), footer_need].max.clamp(..W_cap)   # never above W_cap
```

In case A, if `W_target > W`, distribute `W_target - W` evenly across the visible columns (remainder to the last), keeping each column's alignment. In case B, `W` is already `W_cap`. If `footer_need > W_cap` (only with a tiny `max_width_px`), the footer text is ellipsis-truncated to `W_cap - 2*edge`.

### 6.7 Step 6: truncation

For every visible column, `Text.fit` the header and each cell to `w_j - 2*pad` (4.5). Cells in number columns already fit by construction except in the degenerate case of 6.5. `deadline.check!` between columns.

### 6.8 Step 7: footer text

The footer exists only when something is hidden: `rows_hidden = rows_shown < sample.rows.size || sample.rows_truncated?`, `columns_hidden = visible_columns < sample.total_columns`. When nothing is hidden, `footer_text` is `nil` and no footer band is drawn, so small complete tables end at their last row. Wording, from `Layout::STRINGS`:

| Situation | Rows part | Columns part |
|---|---|---|
| All rows shown | `4 rows` (`1 row`) | |
| Some rows hidden, total known | `20 of 1,284 rows` | |
| Total unknown (file larger than `max_input_bytes`), `rows_read > rows_shown` | `20 of 18,402+ rows` | |
| Total unknown, `rows_read == rows_shown` | `20+ rows` | |
| All columns shown | | `6 columns` (`1 column`) |
| Some columns hidden (by width, by `max_columns`, or both) | | `11 of 31 columns` |

`footer_text = "#{rows_part} · #{columns_part}"` (U+00B7 between single spaces), for example `20 of 1,284 rows · 11 of 31 columns` or `20 rows · 7 of 23 columns`. Integers use ASCII digits with `,` every three digits, independent of locale (`n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse`). The column count shown is `visible_columns`; the peek column counts as hidden. The footer is drawn in `footer_size`, `footer_weight`, `muted_color`, with `tnum`, left-aligned at `edge`.

### 6.9 Special layouts

- **Empty file** (`sample.empty?`, including 0-byte and whitespace-only input): width `min(px(min_width), W_cap)`, height `2*frame + px(header_height) + empty_body_rows * px(row_height)` (640 by 292 px at the defaults; if `max_height_px` is smaller, use fewer body rows, down to one). An empty header band (fill and rule), no body rules, and a message in `body_size`, regular, `muted_color`, centred horizontally and centred on cap height in the body. The message is `STRINGS[:empty]` ("Empty file") when the whole file was read (`sample.total_rows` is not nil). When only the first `max_input_bytes` were read and they were blank (`total_rows` nil), the file may continue, so the message is `STRINGS[:nothing_read]` ("No data in the first 2 MB", with the size formatted from `max_input_bytes`: whole or one-decimal MB of 1,048,576 bytes, or KB below that). `visible_columns` 0, `columns` empty, `footer_text` nil.
- **Header only** (headers present, no data rows): the header band as usual, then one row band containing `STRINGS[:no_rows]` ("No rows") left-aligned at `edge` in the message style. Height `2*frame + header + row`. The footer follows 6.8 (it appears only if columns are hidden; its rows part is then `0 rows`). `message` is "No rows".
- **No header row**: letters, as in 6.2.

### 6.10 Output size

`width_px = W_target` from 6.6 and `height_px = 2*frame + px(header_height) + rows_shown * px(row_height) + (footer ? px(footer_height) : 0)`. By construction `width_px <= max_width_px` and `height_px <= max_height_px`; `Layout` asserts both and raises `RenderFailed` if a bug ever breaks them. At the defaults a full render is 2048 by 1588 px (20 rows plus footer), a 3-column, 4-row table of short names is 755 by 364 px, and the empty-file image is 640 by 292 px (*verified* with the prototype).

### 6.11 The `Layout` object

Pinned members, with their exact meaning here:

| Member | Meaning |
|---|---|
| `sample` | The `Sample`. |
| `visible_columns` | Number of fully visible columns (the peek is not counted). |
| `columns` | `visible_columns` entries of `Layout::Column` with `index`, `kind`, `align` (`:left`/`:right`), `width` (logical px, a Float equal to `width_px / scale`). |
| `cell_text(row, col)` | Display string of a drawn cell (after all of 4.1, so with `…` and U+2212 where applied); `""` for a blank cell; `nil` outside the drawn area. For the peek column, the untruncated display string. |
| `header_text(col)` | Same for the header (column letters when the file has no header row). |
| `footer_text` | String or `nil` (6.8). |
| `width_px`, `height_px` | Output size. |

Added members: `rows_shown`, `peek_column` (`Layout::Column` or `nil`, with `align` reported as `:left`), `message` (`"Empty file"`, `"No data in the first 2 MB"`, `"No rows"` or `nil`), `Column#width_px` and `Column#x_px` (device px), `scale`, `theme`, `text_calls` (instrumentation for tests). The rendered `Run`s are kept in private state for `Painter`, reachable through `@api private` members that may change at any time: `Layout#placements` (an `Array` of `Layout::Placement` in paint order: column by column (each visible column's header, then its cells), then the peek column's header and cells, then the message, then the footer), `Layout#geometry` (the device-px bands and rules of 2.3), the per-cell lookups `cell_placement(row, col)`, `header_placement(col)`, `footer_placement` and `message_placement` (each a `Placement` or `nil` when nothing is drawn), and `max_width_px` and `max_height_px` (the caps the layout was built under, which the Painter checks again). `Layout::Placement` is `Data.define(:run, :x, :y, :box)` with four members: the `Run`, the device-px position (`x`, `y`) of its image's top-left corner, and `box`, the cell's clip rectangle in device px (the cell box of 7.2, or the footer or message band, without rules). The Painter needs nothing else from `Text`.

## 7. Painter (`painter.rb`)

### 7.1 Canvas, fills, rules, frame

One image, built once, with no in-place drawing:

```ruby
res    = 72.0 * scale / 25.4                                  # pixels per mm, so PNG pHYs says 144 dpi at scale 2
rows   = Array.new(h, theme.rgb(:background).pack("C3"))      # one 3-byte pixel per output row
band   = ->(token, y, height) { rows.fill(theme.rgb(token).pack("C3"), (y.clamp(0, h))...((y + height).clamp(0, h))) }
band.(:header_fill, frame, header_px)
band.(:header_rule_color, frame + header_px - rule, rule)
(1...rows_shown).each { |i| band.(:row_rule_color, row_top(i), rule) }
band.(:footer_rule_color, footer_top, rule) if footer
band.(:frame_color, 0, frame)                                 # top and bottom frame
band.(:frame_color, h - frame, frame)
canvas = Vips::Image.new_from_memory_copy(rows.join, 1, h, 3, :uchar)
                    .embed(0, 0, w, h, extend: :copy)          # the 1 px column stretched to the width
if frame.positive?                                            # left and right frame, over everything else
  side   = Vips::Image.black(frame, h, bands: 3).new_from_image(theme.rgb(:frame_color))
  canvas = canvas.insert(side, 0, 0).insert(side, w - frame, 0)
end
canvas = canvas.copy(interpretation: :srgb, xres: res, yres: res)
```

Every band except the two side frames spans the full width, so the canvas is one column of row colours, written in drawing order so a later band overwrites an earlier one, then stretched to the width. The pixels are exactly those of drawing the same rectangles in that order.

**The gem never draws in place** (no `mutate`, `draw_rect!` or other `draw_*` operation, anywhere). Each libvips draw operation signals "invalidate" to every earlier draw operation on the same image, and libvips holds no reference to those operations. ruby-vips runs each operation without the GVL, so Ruby's GC on another thread can free an earlier draw while the signal reaches it, and the process crashes (a SIGSEGV seen in PS-30). This affects every supported ruby-vips and libvips, in any multi-threaded host. A painter test asserts that painting calls no `draw_*` operation.

The frame can be drawn in the base canvas because nothing composited later reaches it: text is clipped inside it and the fade stops at `W - frame`. The pHYs resolution is cosmetic (macOS Preview shows a scale-2 image at its logical size; browsers ignore it) and deterministic.

### 7.2 Text placement and clipping

For each `Run`, compute its position from 4.3 (horizontal) and 4.6 (vertical), then clip it to its **cell box**: horizontally the column box `[x_j, x_j + w_j)` (the peek's box ends at `W - frame`), vertically the band without its rule (`[row_top, row_top + row)` for the first row, `[row_top + rule, row_top + row)` for the others, `[header_top, header_top + header - rule)` for the header, `[footer_top + rule, footer_top + footer)` for the footer). Clip with `image.crop(...)` on the intersection; skip the run if the intersection is empty. Clipping keeps tall marks and fallback glyphs out of neighbouring cells and off the rules.

### 7.3 Fade

```ruby
ramp = ((Vips::Image.grey(fade, 1) ** theme.fade_exponent) * 255).cast(:uchar)   # 0 at left, about 255 at right
ramp = ramp.embed(0, 0, fade, band_h, extend: :copy)                             # band_h = header + rows_shown*row
fade_layer = Vips::Image.black(fade, band_h, bands: 3).new_from_image(theme.rgb(:background))
                        .bandjoin(ramp).copy(interpretation: :srgb)              # at (W - frame - fade, frame)
```

Only drawn when a peek column exists. It fades both the peek's text and the header band into the background, matching the mockup.

### 7.4 Compositing

Composite all clipped runs and then the fade layer in **one** n-ary call, then drop alpha:

```ruby
out = canvas.composite(layers, Array.new(layers.size, :over), x: xs, y: ys)
out = out.flatten(background: theme.rgb(:background)).cast(:uchar).copy(interpretation: :srgb)
```

One composite of a few hundred small positioned layers is fast (libvips 8.8 made positioned sub-images in `composite` much faster; *verified*: about 20 ms for 170 layers on a 2048 by 1588 canvas, against about 120 ms for flattening each run and drawing it with `draw_image`). The result is 8-bit, 3-band sRGB on white. Call `deadline.check!` before compositing and before encoding; libvips work in progress cannot be interrupted, so the checkpoints sit between steps.

### 7.5 Encoding

Metadata is always stripped: libvips otherwise writes an `eXIf` chunk into PNGs (*verified*). Use `keep: 0` (`VIPS_FOREIGN_KEEP_NONE`, passed as an Integer because ruby-vips before 2.2.5 cannot convert a Symbol for a flags argument) on libvips 8.15 or newer and `strip: true` before that (`Vips.at_least_libvips?(8, 15)`); on 8.18 both give identical bytes (*verified*).

| `format` | Call | Measured on `statement.csv` (2048 by 1588) |
|---|---|---|
| `:png` (default) | `write_to_buffer(".png", compression: 6, **strip)`. No interlace, no palette, 8-bit RGB. | 240 KB, about 50 ms. Level 9 saves 3% for 5 times the time; level 1 is 23% larger. Palette PNG is smaller but needs libimagequant, which is not always compiled in, so output would differ between builds. |
| `:webp` | `write_to_buffer(".webp", lossless: true, **strip)` | 57 KB, about 95 ms. Lossless: pixels identical to the PNG. Lossy at Q 90 is 208 KB and blurs text, so lossy is not used. |
| `:jpeg` | `write_to_buffer(".jpg", Q: 90, optimize_coding: true, subsample_mode: :off, interlace: false, **strip)` | 441 KB, about 30 ms. Q 90 with 4:4:4 chroma keeps text edges clean; JPEG is offered only for hosts that require it. |

The return value is the binary `String` from `write_to_buffer`. A missing saver (libvips built without WebP, for example) raises `Vips::Error`, which becomes `RenderFailed` naming the format.

### 7.6 Caps

`Painter` checks `canvas.width == layout.width_px`, `canvas.height == layout.height_px`, and that both are within `max_width_px` and `max_height_px` before encoding. Nothing in the painter can enlarge the canvas: composite output always has the base image's size, and layers outside it are clipped.

## 8. Thumbnail legibility

Active Storage stores one preview image per file and resizes it for each requested size, so the same image must read at about 1024 px (half of the 2048 px render, which is exactly the 1x design) and still look like a table at 300 px (about 15% of the render: 26 px text becomes about 4 px).

What carries the 300 px thumbnail, checked by downscaling the prototype's renders:

- **The header band.** It is the one area fill and the strongest "this is a table" cue. The mockup's `#F4F5F7` is only 1.09:1 against white and nearly disappears at 300 px. This spec uses `#EEF0F3` (1.14:1, about 50% more luminance difference), which the research found to be roughly the lightest fill that survives; at full size it still reads as quiet (side-by-side check at 1:1). Header text on it keeps 5.24:1 contrast. The header rule moves to `#DDE1E6` to stay one step darker than the fill.
- **Row rhythm.** Each row of text becomes a grey bar; 36-px rows with one line each give an even stripe pattern. Uneven rows would destroy this, which is why text never wraps.
- **Alignment edges.** Right-aligned number columns keep a ragged-left, straight-right edge that reads as money.
- **The fade and the frame.** The right-edge fade shows that the table continues; the frame (2 px in the render, 1 px at 1024 px) keeps the image's edge visible on white hosts; it is sub-pixel at 300 px, which is fine.
- **Filling the frame.** No outer margin, no centring on a large canvas; small tables get a small image (6.6), which a host's thumbnail box enlarges, so they are often legible even as thumbnails.

**Aspect ratio is not bounded.** Full renders are about 1.3:1 (2048 by 1588); short tables are wider (a 4-row table at full width is about 5:1) and narrow tables taller. Bounding it would mean padding (wasted pixels) or dropping rows. For a top-left `resize_to_fill` thumbnail (the Active Storage section's recipe) this works in the reader's favour: the shorter the table, the larger the scale, so a 4-row table cropped to 300 by 300 keeps text about 18 px high, while a full 20-row table becomes texture with a header band.

Not strengthened: row rules (they vanish at 300 px whatever their colour, and darker rules would make the 1024 px view look like a grid), and the footer (12 px muted text is illegible at 300 px at any weight; at 1024 px `#6B7280` regular is 4.83:1 and reads well). If a host needs a genuinely legible thumbnail, the right fix is a separate thumbnail layout (fewer columns, larger type), noted in open questions, not heavier tokens.

## 9. libvips and Pango requirements

| Feature used | Purpose | libvips version |
|---|---|---|
| `text` with Pango markup | all text | 7.x; cairo-based rendering since 8.11 |
| `text` `fontfile` | bundled Inter | 8.7.0 |
| `text` image `xoffset`/`yoffset` set to ink offsets | baseline and alignment | 8.8.0 |
| `text` `rgba` | colour text, colour emoji | 8.11.0 |
| `text` `width` + `align` | right-alignment trick | long-standing (8.0 era) |
| `text` using a private font map | immune to other Pango users changing resolution | 8.11 and 8.12 (own map), Pango's shared default map in 8.13.0 to 8.14.1, private again from 8.14.2 |
| `text` forcing greyscale antialiasing in `rgba` mode | no colour fringes if fontconfig enables subpixel rendering | 8.17.1 (not relied on: the gem corrects the output on every version, see "Greyscale antialiasing" below) |
| `composite` (n-ary, `x`/`y` positions) | compositing | 8.7.0 (fast positioning 8.8.0, many-small-layers fix 8.8.1) |
| `Image.new_from_memory_copy`, `embed` (`extend: :copy`), `insert` | fills, rules, frame | libvips 8.2 (`new_from_memory_copy`); ruby-vips 2.1 |
| `grey`, `embed`, `bandjoin`, `flatten`, `cast`, `crop` | fade, output | 8.0 |
| `pngsave` `compression`; `webpsave` `lossless`; `jpegsave` `Q`, `optimize_coding` | encoding | 8.0 |
| `jpegsave` `subsample_mode` | 4:4:4 JPEG | 8.10.0 |
| saver `keep` (else `strip`) | metadata removal | 8.15.0 |

**Minimum: libvips 8.12.** Everything above works there (with `strip` instead of `keep`), and 8.12.1 is what Ubuntu 22.04 LTS ships (Debian 12 ships 8.14.1, Ubuntu 24.04 ships 8.15.1). Recommended: 8.14.2 or newer. Known gaps below the recommendation: on 8.13.0 to 8.14.1 another in-process Pango user (for example SVG text through librsvg) can share libvips' font map; before 8.17.1, a host whose fontconfig enables subpixel antialiasing draws coloured text edges, which the gem corrects (see "Greyscale antialiasing" below). On first use (during warm-up) the gem raises `RenderFailed` if `Vips.at_least_libvips?(8, 12)` is false.

**Pango 1.44 or newer** (HarfBuzz shaping on every backend). `font_features` in markup needs 1.38; below that the warm-up probe disables `tnum` rather than failing every number cell. Ubuntu 22.04 ships Pango 1.50.6, Ubuntu 24.04 1.52.1, Debian 12 1.50.12. ruby-vips cannot report the Pango version, so the probe is the check.

**ruby-vips `>= 2.2.2, < 3`.** `new_from_memory_copy` needs 2.1, but the floor is 2.2.2 for two reasons. `Vips.block_untrusted` (used by REN-22 and by Active Storage's image processing) first appears in 2.2.1, and 2.2.1 cannot load on Ruby 4.0 unless the application's bundle happens to include `logger`; the gem would then report "libvips could not be loaded", which misleads. A floor that cannot load on a supported Ruby is not a floor, so 2.2.2 is the first version that works on every supported Ruby (3.3 to 4.0). CI has a job pinned to ruby-vips 2.2.2 (`gemfiles/ruby_vips_floor.gemfile`). Saver flags: before ruby-vips 2.2.5 a Symbol cannot be converted for a flags argument, which is why 7.5 passes `keep: 0`.

**Untrusted operations.** Rendering uses no operation libvips marks untrusted (only `text`, `black`, `new_from_image`, `new_from_memory_copy` (not an operation: it wraps a copy of the gem's own pixel bytes), `insert`, `grey`, `embed`, `bandjoin`, `crop`, `composite`, `flatten`, `cast`, `copy`, the greyscale correction's `linear`, `relational`, `bandand` and `ifthenelse`, and the buffer savers), so it works when Active Storage or image_processing has called `Vips.block_untrusted(true)` (*verified* on 8.18.7: identical bytes with and without the block).

**Greyscale antialiasing.** Text must be greyscale-antialiased on every host: previews are resized and viewed on any screen, and coloured fringes at glyph edges defeat "beautiful". Before libvips 8.17.1, `text` with `rgba: true` lets fontconfig choose the antialiasing, and many Linux configurations choose subpixel rendering. Ubuntu 24.04's default fontconfig does (including the GitHub `ubuntu-24.04` image), so the assumption that server images normally draw greyscale text is wrong. The alpha band is then the coverage of the middle subpixel and the colour bands carry red and blue fringes. The gem corrects this itself, per run, with no process-global state and no change to libvips or fontconfig settings:

1. **Detection** (warm-up step 4 of 5.4): the antialiasing probe measures whether mid-grey text over white has equal channels. The result is per process and is measured with the bundled Inter.
2. **Correction** (hosts where the probe says subpixel): after drawing a string, every pixel takes the style colour and keeps the alpha libvips drew (`linear` with a zero gain on the colour bands). Offsets and size are unchanged, and the image is 4-band, 8-bit sRGB as before.
3. **Colour glyphs.** Emoji must keep their own colours, which the recolour would erase. A string that can contain a colour glyph (the `COLOR_GLYPH` character set: pictographs, emoji-presentation characters, skin-tone modifiers, VS16, the keycap mark and emoji tag characters) is drawn a second time with the style colour replaced by a contrasting colour (at least 128 levels away in every channel), with the same layout. Pixels that come out identical in both drawings belong to colour glyphs and keep libvips' own values; every other pixel is recoloured. That second drawing is a real libvips call, so it is **counted** like any other: such a string costs two text calls on a subpixel host (4.7, 10). If the two drawings ever differed in size, the run keeps libvips' own pixels rather than lose its emoji.
4. **Greyscale hosts** (macOS, libvips 8.17.1 and newer, or fontconfig set to greyscale) are untouched: the run is libvips' own image, byte for byte.

*Measured:* the corrected output is within 15 levels of true greyscale rendering at glyph edges (the middle subpixel's coverage is slightly softer than greyscale coverage), with ink within 0.1%; the correction costs about 20 ms per full render and about 0.1 ms per run.

*Limits:* (a) detection is per process and uses the bundled Inter; a fontconfig configuration that enables subpixel rendering for only some families would leave those families uncorrected (or correct families that were already greyscale, which changes them by at most one level). (b) A character outside `COLOR_GLYPH` that falls back to a colour font would be drawn as a silhouette in the text colour on subpixel hosts only; none is known with Noto Color Emoji or Apple Color Emoji. (c) A pixel where text and a colour glyph overlap takes the style colour (about 1 px observed). (d) Characters such as (c), (r), TM and arrows match `COLOR_GLYPH` and pay the second drawing needlessly; the result is unchanged. (e) Exact greyscale coverage needs libvips 8.17.1 or a global fontconfig rule.

## 10. Performance budget

**Text calls per render.** One `text` call per distinct non-blank drawn string, plus truncation probes, plus the footer:

- Measured: about `(rows_shown + 1) * columns_measured` calls, minus repeated values, where `columns_measured` stops at the column that overflows (6.4).
- Truncation: 2 to 3 extra calls per truncated cell (4.5). Peek cells are never truncated.
- On a subpixel host (section 9), a string that can contain a colour glyph costs 2 calls instead of 1, and both are counted in `Layout#text_calls` and against the budget below. About 0.1 ms per run and about 20 ms per full render are added.
- Per process, once: 2 registration calls (plus 1 refresh draw on libvips before 8.13), 1 feature probe, 1 antialiasing probe, 2 self-check probes (`0000000000` and `1111111111`), 3 cap-height probes, 2 ellipsis measurements. `Text.warm_up!` itself makes 9 calls (10 on libvips before 8.13); the ellipsis measurements happen lazily at the first truncation.

Measured with the prototype (warm process, Apple M1 Pro, libvips 8.18.7):

| Fixture | Text calls | Text measuring | Build pipeline | Composite + PNG encode | Total |
|---|---|---|---|---|---|
| `statement.csv` (23 columns, 20 rows; 7 visible + peek) | 145 | about 30 ms | about 25 ms | about 55 ms | about 110 ms |
| `wide_long.csv` (20 rows by 12 kept; 11 visible + peek) | 256 | about 55 ms | about 30 ms | about 80 ms | about 165 ms |
| 12 columns of 70-character text (worst realistic truncation) | 438 * | about 120 ms | about 27 ms | about 52 ms | about 200 ms |

\* The prototype measured all 12 columns; with the early stop of 6.4 and no peek truncation this fixture needs about 280 calls.

A warm `text` call costs about 0.2 ms. The first render in a process adds font setup: about 60 to 90 ms for the first `text` call with a warm fontconfig cache (more if the cache must be built, which is why the README should tell container builds to run `fc-cache`). Budget for the spec: a 20 by 12 table renders in **under 250 ms warm on a current laptop core and under 1 s on CI**, and makes **at most 400 text calls**. CSV parsing is not included (it is bounded separately).

How it stays low: one call per string that both measures and draws; per-render caching of repeated values; stopping measurement at the first overflowing column; a proportional first guess for truncation; no truncation of the peek; one n-ary composite instead of per-cell compositing; PNG compression 6 rather than 9.

Memory: text images are small (a 26-px cell is a few tens of KB as RGBA; about 250 of them is under 10 MB), plus the 9.8 MB canvas and libvips tile buffers while encoding. Well under the 200 MB bound.

## 11. Determinism

**Byte-identical** for the same input bytes, options, gem version (and so fonts), and the same builds of libvips, Pango, HarfBuzz, FreeType, cairo, fontconfig, zlib or the PNG library, libwebp and libjpeg-turbo, with the same fontconfig configuration (hinting and antialiasing settings) and the same installed fallback fonts. *Verified*: repeated renders in one process, renders in two separate processes, and renders from 8 concurrent threads all give identical PNG bytes; repeated WebP and JPEG encodes are identical. The gem itself adds no time, randomness, hash ordering or metadata: metadata is stripped and the pHYs resolution is fixed.

**Not identical** across: libvips versions (the PNG writer moved from libpng to libspng in 8.13 and back to libpng in 8.18, so identical pixels can still produce different bytes); Pango, HarfBuzz or FreeType versions (glyph positions and rasterisation, so text widths and column widths can differ by a pixel); different fontconfig hinting configurations; different fallback fonts for CJK and emoji; and possibly CPU architectures (libvips vector paths may round compositing differently by one level).

**Golden-image tests:**

- Goldens are generated on one **pinned CI image** (GitHub `ubuntu-24.04`, packaged libvips 8.15.1, with `fonts-noto-color-emoji` and `fonts-noto-cjk` installed) by a rake task that only runs there. On that job (`CSV_PREVIEW_GOLDEN=exact`), compare **bytes exactly**.
- Everywhere else (macOS, other distributions, developer machines), compare **perceptually**: both dimensions within 2%; then resize both images to 512 px wide and require a mean absolute difference under 3 levels (0 to 255 scale) and a 99th-percentile per-pixel difference under 64 levels. Also assert the structural facts from `CsvPreview.layout` (visible columns within one of the golden's, same `rows_shown`, same footer pattern), which is what actually catches regressions across platforms.

## 12. Acceptance tests

Fixtures live in `test/fixtures/`. New fixtures introduced by this section:

| Fixture | Content |
|---|---|
| `statement.csv` | Copy of [`../design/mockups/statement.csv`](../design/mockups/statement.csv): 23 columns, 20 rows. The reference for the Ledger look. |
| `minus.csv` | Column `Amount` with `-12.00`, `-$0.99`, `$-12.00`, `12.00-`, `(45.00)`, `1.234,56 €`, `-`; column `Note` with `-2+3`, `x < y & z`, `<b>bold</b>`. |
| `rtl.csv` | A text column of Arabic and Hebrew strings, mixed `عربي text`, and a number column of amounts with one cell `غير متوفر`. |
| `long_text.csv` | Generated: 12 columns by 20 rows, every header and cell 60 to 70 characters of words. |
| `invisible.csv` | Cells containing only U+200B, only U+2800, only spaces, plus normal cells. |

Fixtures defined in [`parsing-and-safety.md`](./parsing-and-safety.md) and used here: `simple.csv`, `wide_long.csv`, `numbers.csv`, `emoji_cjk.csv`, `markup.csv`, `long_cell.csv`, `header_only.csv`, `whitespace_only.csv`, `single_column.csv`, `empty.csv` (0 bytes).

| # | Test | Pass condition |
|---|---|---|
| REN-1 | `simple.csv` renders | Valid PNG; 8-bit, 3-band sRGB; decoded size equals `layout.width_px` by `layout.height_px`; `width_px > height_px`; pixel standard deviation above 10; `layout.header_text(0)` equals the first header; `footer_text` nil. |
| REN-2 | Alignment (`numbers.csv`) | For every visible column, `align` is `:right` exactly when `sample.column_kinds[index]` is `:number`, and every column of number forms is `:right`; text columns are `:left`. In the rendered image, for each `:number` column, the right ink edge of the header label is within 3 px of the right ink edges of its cells (ink edges differ from the logical edges by the glyphs' side bearings, so ink edges of different strings can differ by a few px at scale 2; what Pango aligns exactly are the logical right edges, which the Layout tests assert as `placement.x + run.extent` equal to the text edge for every right-aligned cell). |
| REN-3 | True minus (`minus.csv`) | `Amount` cells display as `−12.00`, `−$0.99`, `$−12.00`, `12.00−`, `(45.00)`, `1.234,56 €`, `-` (the placeholder is unchanged); `Note` cells are unchanged, including `-2+3`. |
| REN-4 | Markup is literal | `markup.csv` and `minus.csv` render without raising; every drawn cell whose display string was not width-truncated equals its `Sample` string exactly (`<b>bold</b>`, `x < y & z`); `Text.escape` unit tests for `& < > " '`. |
| REN-5 | Emoji, CJK (`emoji_cjk.csv`) | Renders without raising; the plain-figures cell's box has no pixel with HSV saturation of 0.45 or more on any host (the dark text colour is slightly blue, saturation 0.23, and its antialiased edges are greyscale everywhere because of the correction in section 9); where a colour emoji font is installed (macOS, and the pinned CI image, with `CSV_PREVIEW_GOLDEN=exact`) the emoji cell's box contains pixels with saturation above 0.45. The threshold is 0.45 rather than 0.3 because Linux antialiasing of the blue-tinted text colour produced edge pixels above 0.3 before the correction was added; 0.45 stays far below a colour emoji. |
| REN-6 | Right-to-left (`rtl.csv`) | Renders; the number column's `width_px` is under 600 at defaults (without the guard in 4.3 the Arabic cell would report an extent near 32,768 px); the Arabic text column is `:left`. |
| REN-7 | Truncation | In `long_text.csv` every visible text cell's `cell_text` ends with `…`, its prefix (without `…`) is a grapheme-cluster prefix of the source, and its run extent is at most `column.width_px - 2*pad`. A 100,000-character cell (`long_cell.csv`) renders in under 1 s. |
| REN-8 | Numbers never truncate | A number column containing `-$1,234,567,890.12` shows `−$1,234,567,890.12` in full and its column is wider than `max_column_width` if needed. |
| REN-9 | Footer wording | `simple.csv`: nil. `statement.csv`: matches `/\A20 rows · (\d+) of 23 columns\z/` with the captured number equal to `visible_columns`. `wide_long.csv`: matches `/\A20 of 1,284 rows · (\d+) of 31 columns\z/`. `simple.csv` with `max_columns: 2`: `4 rows · 2 of 3 columns`. A generated 5 MB file: matches `/\A20 of [\d,]+\+ rows · /`. A 1-row, 3-column file with `max_columns: 1`: `1 row · 1 of 3 columns`. |
| REN-10 | Peek and fade | `wide_long.csv`: `peek_column.index == visible_columns`; the last 4 px before the right frame in data rows are within 2 levels of white for this fixture (the test asserts a minimum of 253; in general the 7.3 ramp can leave pixels up to 8 levels from the background there when peek text runs to the edge, which is invisible and accepted, so a fixture whose peek text runs to the edge must assert within 8 levels); the 4 px at the start of the fade zone contain ink in at least one row. `simple.csv`: `peek_column` nil. |
| REN-11 | Empty file | `empty.csv` (0 bytes) and `whitespace_only.csv`: no error; `message == "Empty file"`; size 640 by 292 at defaults; `sample.empty?`. A generated file of 2 MiB + 1 newlines followed by data: `message == "No data in the first 2 MB"`. |
| REN-12 | Header only | `header_only.csv`: `message == "No rows"`; height 148 px at defaults. |
| REN-13 | No header row | `simple.csv` with `header_row: false`: `header_text(0..2) == ["A", "B", "C"]`, 5 data rows. |
| REN-14 | Dimension caps | For every fixture and each of `max_width_px` in [320, 777, 2048] and `max_height_px` in [220, 999, 2600] (scale 2): decoded size equals `layout.width_px` by `layout.height_px` and is within the caps. `wide_long.csv` with `max_rows: 50` at defaults: `rows_shown == 34`, height 2,596. |
| REN-15 | Small tables fill the frame | `single_column.csv`: `width_px` equals `px(min_width)` (640 at defaults) and the header band spans the full inner width. |
| REN-16 | Invisible cells | `invisible.csv` renders; those cells have `cell_text` equal to the stripped source and draw nothing; no error. |
| REN-17 | Determinism | Each fixture rendered twice in one process gives identical bytes; rendered in a child Ruby process gives the same bytes; 8 threads by 10 iterations give the same bytes as serial runs. |
| REN-18 | Formats | `format: :webp` decodes to pixels identical to the PNG; `format: :jpeg` decodes to the same size; all three have no EXIF, XMP or ICC metadata. PNG chunks are exactly `IHDR`, `pHYs`, `IDAT`..., `IEND`, with pHYs 5,669 px/m at scale 2. |
| REN-19 | Bundled font active | `Text.warm_up!`, then `Text.bundled_font_active?` is true on the Ubuntu and macOS CI jobs; the bundled files' SHA-256 values match section 5.1. Both self-check probes (5.4) pass for the bundled Inter, and `DejaVu Sans`, `Verdana`, `Liberation Sans`, `Noto Sans`, `Helvetica` and `Arial` each fail at least one. |
| REN-20 | Budget | Warm render of `wide_long.csv`: `layout.text_calls <= 400` and under 1 s on CI; `long_text.csv`: `text_calls <= 700`. |
| REN-21 | Golden images | Goldens for `simple`, `wide_long`, `numbers`, `emoji_cjk` and `statement` pass section 11's comparison. `emoji_cjk` uses looser perceptual limits off the pinned image (mean difference under 8, not 3; its 99th-percentile limit is 255, which effectively disables that check), because its emoji and CJK glyphs come from different fallback fonts on macOS (Apple Color Emoji and Hiragino against Noto): measured 5.3 and 195 on macOS. Its dimensions (2%) and structural facts still apply, and the exact byte comparison on the pinned image is unchanged. The first four are also the source renders for the README images, which `bin/brand-images` composites in the same CI environment ([`branding-and-discoverability.md`](./branding-and-discoverability.md) 2.4). |
| REN-22 | Untrusted operations blocked | With `Vips.block_untrusted(true)` (libvips 8.13 or newer), every fixture renders in all three formats with bytes identical to an unblocked run (*verified* on 8.18.7 for `statement.csv`). |
| REN-23 | Manual visual review before 1.0 | A person checks each golden at 1024 px wide (readable header and first rows) and at 300 px wide (recognisably a table: header band, row rhythm, fade), on a white and a light grey background. |
| REN-24 | Greyscale text | With subpixel rendering forced (Linux: a fontconfig file with `rgba rgb`, in a child process, because the mode is read once per process), every Ledger style's run (body, number, header, footer, message) has colour spread at most its tint plus 2; a full `statement.csv` render has no pixel with channel spread above 60; text beside an emoji is neutral and the emoji keeps saturation above 0.45; and the render matches the same render under `rgba none` (mean difference under 0.5, maximum at most 24, ink within 1%). On greyscale hosts a run's pixels equal libvips' own image. A string with an emoji in every cell of a 20-row table counts exactly the libvips calls made (`layout.text_calls`), and the deadline is checked at each multiple of 32 reached (4.7). |

## 13. Open questions

1. **Header fill.** This spec darkens the header band from the mockup's `#F4F5F7` to `#EEF0F3` (and the rule to `#DDE1E6`) for thumbnails. Confirm, or keep the mockup values.
2. **Files without a header row.** Spreadsheet letters keep the band and make thumbnails consistent, but they are content that is not in the file. The alternative is no band at all.
3. **Minimum width and text size across previews.** Small tables produce small images (640 px for a one-column file). A host that shows images at their pixel size (for example `resize_to_limit: [1024, 1024]` without CSS sizing) then shows small tables with text twice as large as wide tables. Options: keep 320 logical px, raise the minimum (480 or 640), or always render at full width (looks sparse). The Active Storage section could recommend sizing the `<img>` at `width_px / scale`.
4. **Footer when nothing is hidden.** This spec omits it so small tables stay tight. The alternative is always showing counts (`4 rows · 3 columns`).
5. **Runs of spaces.** The Sanitizer keeps internal runs of spaces, so space-padded exports show their gaps (`LYFT   *RIDE`). Collapsing them for display would look tidier but less literal. Current choice: keep them.
6. **Font self-check failure.** It warns once and continues with the fallback font. Should it raise `RenderFailed` instead (strict mode), at least in test environments?
7. **System Inter on Ubuntu.** If a host installs `fonts-inter` (a different Inter version), does fontconfig 2.13 or 2.15 still prefer the bundled file, as 2.18 did? If not, the fix is to rename the bundled family (allowed: Inter has no Reserved Font Name) at the cost of shipping modified files.
8. **Minimum libvips.** 8.12 (covers Ubuntu 22.04) needs a CI job on 22.04 to be honest; otherwise raise the minimum to 8.15 to match what CI tests.
9. **Number detection threshold.** 80% of non-blank cells. Columns that mix amounts with many text notes fall back to left alignment.
10. **A dedicated thumbnail layout** (3 to 5 columns, larger type) would make 300 px thumbnails readable rather than merely recognisable. Out of scope for the MVP; worth a roadmap entry.

## 14. Proposed changes to the overview

> **Status: applied** to the overview on 2026-11-15 (items 1 to 6; the minimum stays libvips 8.12 with an Ubuntu 22.04 CI job; item 7's notes are in the overview's section 13). Kept below for the reasoning.

1. **Option validation (section 9.2).** State the accepted ranges and that bad values raise `ArgumentError` when options are resolved: `scale` an Integer from 1 to 4; `max_width_px >= 160 * scale` (room for the edge padding, one minimum-width column and the fade); `max_height_px >= 110 * scale` (frame, header, one row, footer). Without floors, `Layout` cannot guarantee a sensible image.
2. **`max_width_px` is a cap, not a target.** Add one line to 9.2: the layout width is `min(1024 * scale, max_width_px)` and smaller tables produce narrower images. Otherwise readers may expect every preview to be 2048 px wide.
3. **Layout members (section 9.4).** List the additions from 6.11 (`rows_shown`, `peek_column`, `message`, `Column#width_px`, `Column#x_px`, `text_calls`) and note that `Column#width` may be fractional.
4. **CI (section 5 and 11).** Either add an Ubuntu 22.04 job (libvips 8.12.1, Pango 1.50.6, fontconfig 2.13.1) so the stated minimum is tested, or raise the minimum to 8.15. Also install `fonts-noto-color-emoji`, `fonts-noto-cjk` and (in one job) `fonts-inter` on the pinned Ubuntu image.
5. **Golden images (section 12).** Add `statement` as a fifth golden test image (not necessarily a README image): it is the mockup's own data and the best regression check for the look.
6. **Section 8.** Add: "Where `rendering.md` and `ledger.tokens.json` differ, `rendering.md` wins" (the header fill and header rule changed).
7. **Notes for the other sections** (not overview changes; recorded in the overview's section 13):
   - `parsing-and-safety.md`: this section relies on its `CellKind`, Sanitizer and `Sample` exactly as written there and adds no classification of its own. Its tests already read display strings through `CsvPreview.layout`; note that `cell_text` is the width-truncated string and uses U+2212 in `:number` cells, so comparisons with raw input should use short text cells or `CsvPreview.sample`. Its open question about the empty-state wording when `total_rows` is nil is answered in 6.9.
   - `active-storage.md`: the capability check is `CsvPreview::Text.supported?` (5.4). The Railtie can call `CsvPreview::Text.warm_up!` after boot so font setup is not paid inside the first preview job, and the README should say to `require "csv_preview"` at boot on macOS (5.3). Rendering works with `Vips.block_untrusted(true)` (section 9). Its open question about bounding the aspect ratio is answered in section 8 (no). It may also recommend displaying previews at `width_px / scale` (open question 3).
