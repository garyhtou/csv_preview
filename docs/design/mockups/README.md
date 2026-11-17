# Mockups

Rendered with real Pango text (the text stack libvips uses) at 2x, from [`statement.csv`](./statement.csv), a fictional 23-column card statement export.

| Look | Image | Tokens |
|---|---|---|
| Ledger (default) | [`mock-ledger-default.jpg`](./mock-ledger-default.jpg) | [`ledger.tokens.json`](./ledger.tokens.json) |
| Grid (future) | [`mock-grid-spreadsheet.jpg`](./mock-grid-spreadsheet.jpg) | [`grid.tokens.json`](./grid.tokens.json) |
| Card (future) | [`mock-report-card.jpg`](./mock-report-card.jpg) | [`report.tokens.json`](./report.tokens.json) |

- [`mock-thumbnails-300px.jpg`](./mock-thumbnails-300px.jpg): all three scaled to 300px wide, to judge thumbnails.
- [`font-specimens-13px-1x.jpg`](./font-specimens-13px-1x.jpg): the same small table at 13px in six candidate fonts.

`mock.py` is the throwaway prototype that produced these (Python, `pango-view` plus Pillow). It is kept for reference only. It is not part of the gem, which renders with libvips from Ruby. Usage: `python3 mock.py ledger.tokens.json statement.csv out.png`, with Pillow, `pango-view`, and the fonts named in the tokens available to fontconfig. On macOS, set `PANGOCAIRO_BACKEND=fontconfig` (and a `FONTCONFIG_FILE` that lists the font directory), or Pango silently falls back to Helvetica.

All merchant names, people and card numbers in `statement.csv` are fictional.
