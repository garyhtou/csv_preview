"""Mock CSV-preview renderer: pango-view for text (same Pango/HarfBuzz stack libvips uses), Pillow for fills/rules.
Usage: mock.py tokens.json in.csv out.png"""
import csv, json, os, re, subprocess, sys, hashlib
from PIL import Image, ImageDraw, ImageFilter

TOK = json.load(open(sys.argv[1])); CSV = sys.argv[2]; OUT = sys.argv[3]
S = TOK.get('scale', 2)
CACHE = os.path.join(os.path.dirname(OUT), '.textcache'); os.makedirs(CACHE, exist_ok=True)

def esc(t): return t.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
def text_img(t, size, weight, color, feats='', width=None, family=None, tracking=0):
    family = family or TOK['font']
    markup = f'<span font_family="{family}" weight="{weight}" foreground="{color}"'
    if feats: markup += f' font_features="{feats}"'
    if tracking: markup += f' letter_spacing="{int(tracking*S*1024)}"'
    markup += f'>{esc(t)}</span>'
    key = hashlib.md5(f'{markup}|{size}|{width}|{S}'.encode()).hexdigest()
    p = os.path.join(CACHE, key + '.png')
    if not os.path.exists(p):
        args = ['pango-view','-q','--pixels','--markup','--margin=0','--background=transparent','--hinting=none',
                '--antialias=gray','--subpixel-positions',f'--font={family} {size*S}','-o',p]
        if width: args += ['-w', str(int(width*S)), '--ellipsize=end']
        args.append('--text='+markup)
        subprocess.run(args, check=True)
    return Image.open(p).convert('RGBA')

NUM = re.compile(r'^[\-−(]?[$£€¥]?[\-]?[\d,]+(\.\d+)?\)?%?$')
DATE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
rows = list(csv.reader(open(CSV, encoding='utf-8')))
head, body = rows[0], rows[1:]
ncol = len(head)
def is_num(c):
    vals = [r[c] for r in body if c < len(r) and r[c].strip()]
    return bool(vals) and sum(bool(NUM.match(v.replace(' ',''))) for v in vals) / len(vals) > 0.8
def is_ident(c):
    vals = [r[c] for r in body if c < len(r) and r[c].strip()]
    return bool(vals) and all(v.isdigit() for v in vals) and len({len(v) for v in vals}) == 1
numeric = [is_num(c) and not is_ident(c) for c in range(ncol)]

W = TOK['width']; pad_x = TOK['pad_x']; edge = TOK['edge_pad']
fs, hfs = TOK['font_size'], TOK['header_size']
row_h, head_h = TOK['row_h'], TOK['header_h']
gutter = TOK.get('row_numbers_w', 0)
frame = TOK.get('frame', {})
fpad = frame.get('padding', 0)
title_h = TOK.get('title_h', 0)
footer_h = TOK.get('footer_h', 0)
max_rows = TOK.get('max_rows', 14)
inner_w = W - 2*fpad

def fmt(v, c):
    if numeric[c] and TOK.get('true_minus') and v.startswith('-'): return '−' + v[1:]
    return v

def colw(c):
    feats = 'tnum' if numeric[c] else ''
    ws = [text_img(head[c], hfs, TOK['header_weight'], TOK['header_text'], tracking=TOK.get('header_tracking',0)).width / S]
    for r in body[:max_rows]:
        v = r[c] if c < len(r) else ''
        if v: ws.append(text_img(fmt(v,c), fs, TOK.get('amount_weight',400) if (numeric[c] and '$' in v) else 400, TOK['text'], 'tnum' if (numeric[c] or (DATE.match(v) and TOK.get('date_tnum',True))) else '').width / S)
    w = max(ws) + 2*pad_x
    return max(TOK['min_col_w'], w if numeric[c] else min(w, TOK['max_col_w']))
widths = []; x = gutter + edge - pad_x; shown = 0
avail = inner_w - edge + pad_x
for c in range(ncol):
    w = colw(c)
    if x + w > avail and shown > 0: break
    widths.append(w); x += w; shown += 1
hidden = ncol - shown
nrows = min(len(body), max_rows)
H_table = head_h + nrows*row_h
H = fpad*2 + title_h + H_table + footer_h
img = Image.new('RGBA', (int(W*S), int(H*S)), TOK['canvas'])
d = ImageDraw.Draw(img)
def R(x0,y0,x1,y1,fill): d.rectangle([int(x0*S),int(y0*S),int(x1*S)-1,int(y1*S)-1], fill=fill)
def hline(x0,x1,y,col,wt=1):
    if wt <= 0: return
    R(x0, y, x1, y + wt, col)
def vline(x,y0,y1,col,wt=1): R(x, y0, x+wt, y1, col)

# card
cx0, cy0, cx1, cy1 = fpad, fpad, W - fpad, H - fpad
if frame.get('shadow'):
    sh = Image.new('RGBA', img.size, (0,0,0,0)); sd = ImageDraw.Draw(sh)
    for (dy, blur, alpha) in frame['shadow']:
        layer = Image.new('RGBA', img.size, (0,0,0,0)); ld = ImageDraw.Draw(layer)
        ld.rounded_rectangle([cx0*S, (cy0+dy)*S, cx1*S, (cy1+dy)*S], radius=frame.get('radius',0)*S, fill=(16,24,40,alpha))
        layer = layer.filter(ImageFilter.GaussianBlur(blur*S/2))
        sh = Image.alpha_composite(sh, layer)
    img = Image.alpha_composite(img, sh); d = ImageDraw.Draw(img)
card = Image.new('RGBA', img.size, (0,0,0,0)); cd = ImageDraw.Draw(card)
cd.rounded_rectangle([cx0*S, cy0*S, cx1*S-1, cy1*S-1], radius=frame.get('radius',0)*S, fill=TOK['bg'],
                     outline=frame.get('border'), width=int(frame.get('border_w',1)*S) if frame.get('border') else 0)
img = Image.alpha_composite(img, card); d = ImageDraw.Draw(img)
mask = Image.new('L', img.size, 0); ImageDraw.Draw(mask).rounded_rectangle([cx0*S, cy0*S, cx1*S-1, cy1*S-1], radius=frame.get('radius',0)*S, fill=255)

ty = cy0
if title_h:
    t = text_img(TOK['title'], TOK['title_size'], 600, TOK['text'])
    m = text_img(TOK['title_meta'], TOK['meta_size'], 400, TOK['muted'], 'tnum')
    tx = cx0 + edge
    img.alpha_composite(t, (int(tx*S), int((ty + title_h/2)*S - t.height/2 - (m.height/2 if TOK.get('title_stack') else 0))))
    if TOK.get('title_stack'):
        img.alpha_composite(m, (int(tx*S), int((ty + title_h/2)*S + 2*S)))
    else:
        img.alpha_composite(m, (int((cx1 - edge)*S - m.width), int((ty + title_h/2)*S - m.height/2)))
    if TOK.get('title_rule'): hline(cx0, cx1, ty + title_h - TOK['title_rule'], TOK['title_rule_color'], TOK['title_rule'])
    ty += title_h

# header band
hy = ty
if TOK.get('header_fill'): R(cx0, hy, cx1, hy + head_h, TOK['header_fill'])
if TOK.get('top_rule'): hline(cx0 + TOK.get('rule_inset',0), cx1 - TOK.get('rule_inset',0), hy, TOK['top_rule_color'], TOK['top_rule'])
# zebra / rules
for i in range(nrows):
    y = hy + head_h + i*row_h
    if TOK.get('zebra') and i % 2 == 1: R(cx0, y, cx1, y + row_h, TOK['zebra'])
    if TOK.get('row_rule') and i > 0: hline(cx0 + TOK.get('rule_inset',0), cx1 - TOK.get('rule_inset',0), y, TOK['row_rule_color'], TOK['row_rule'])
hline(cx0 + TOK.get('rule_inset',0), cx1 - TOK.get('rule_inset',0), hy + head_h - TOK.get('header_rule',1), TOK['header_rule_color'], TOK.get('header_rule',1))
if TOK.get('bottom_rule'): hline(cx0 + TOK.get('rule_inset',0), cx1 - TOK.get('rule_inset',0), hy + head_h + nrows*row_h - TOK['bottom_rule'], TOK['bottom_rule_color'], TOK['bottom_rule'])
# gutter
if gutter:
    R(cx0, hy, cx0 + gutter, hy + head_h + nrows*row_h, TOK['gutter_fill'])
    vline(cx0 + gutter - 1, hy, hy + head_h + nrows*row_h, TOK['grid_color'])
    for i in range(nrows):
        t = text_img(str(i+1), fs - 1, 400, TOK['muted'], 'tnum')
        y = hy + head_h + i*row_h
        img.alpha_composite(t, (int((cx0 + gutter - 8)*S - t.width), int((y + row_h/2)*S - t.height/2)))
# columns
x = cx0 + gutter + edge - pad_x
for c, w in enumerate(widths):
    if TOK.get('vgrid') and c > 0: vline(x, hy, hy + head_h + nrows*row_h, TOK['grid_color'])
    al_right = numeric[c]
    ht = text_img(head[c], hfs, TOK['header_weight'], TOK['header_text'], tracking=TOK.get('header_tracking',0), width=w - 2*pad_x)
    hx = x + w - pad_x - ht.width/S if al_right else x + pad_x
    img.alpha_composite(ht, (int(hx*S), int((hy + head_h/2)*S - ht.height/2)))
    for i, r in enumerate(body[:nrows]):
        v = fmt(r[c] if c < len(r) else '', c)
        if not v: continue
        col = TOK['text']
        if numeric[c] and TOK.get('negative') and (v.startswith('-') or v.startswith('−')): col = TOK['negative']
        if numeric[c] and TOK.get('positive') and not (v.startswith('-') or v.startswith('−')) and '$' in v: col = TOK['positive']
        if DATE.match(v) and TOK.get('date_color'): col = TOK['date_color']
        t = text_img(v, fs, TOK.get('amount_weight',400) if (numeric[c] and '$' in v) else 400, col, 'tnum' if numeric[c] or (DATE.match(v) and TOK.get('date_tnum',True)) else '', width=None if numeric[c] else w - 2*pad_x)
        y = hy + head_h + i*row_h
        tx = x + w - pad_x - t.width/S if al_right else x + pad_x
        img.alpha_composite(t, (int(tx*S), int((y + row_h/2)*S - t.height/2)))
    x += w
if TOK.get('vgrid'): vline(x, hy, hy + head_h + nrows*row_h, TOK['grid_color'])
# right fade + pill for hidden columns
if hidden and TOK.get('fade_w'):
    fw = TOK['fade_w']; bgc = Image.new('RGBA', (1,1), TOK['bg']).getpixel((0,0))
    grad = Image.new('RGBA', (int(fw*S), int(H_table*S)))
    for gx in range(grad.width):
        a = int(255 * (gx / grad.width) ** 1.5)
        ImageDraw.Draw(grad).line([(gx,0),(gx,grad.height)], fill=bgc[:3] + (a,))
    img.alpha_composite(grad, (int((cx1 - fw)*S), int(hy*S)))
# bottom fade for hidden rows
if len(body) > nrows and TOK.get('fade_h'):
    fh = TOK['fade_h']; bgc = Image.new('RGBA', (1,1), TOK['bg']).getpixel((0,0))
    grad = Image.new('RGBA', (int((cx1-cx0)*S), int(fh*S)))
    for gy in range(grad.height):
        a = int(255 * (gy / grad.height) ** 1.3)
        ImageDraw.Draw(grad).line([(0,gy),(grad.width,gy)], fill=bgc[:3] + (a,))
    img.alpha_composite(grad, (int(cx0*S), int((hy + H_table - fh)*S)))
if footer_h:
    fy = hy + H_table
    if TOK.get('footer_rule'): hline(cx0, cx1, fy, TOK['footer_rule_color'], TOK['footer_rule'])
    msg = TOK['footer'].format(rows=f"{len(body):,}", shown=nrows, cols=ncol, hidden=hidden)
    t = text_img(msg, TOK['meta_size'], 400, TOK['muted'], 'tnum')
    img.alpha_composite(t, (int((cx0 + edge)*S), int((fy + footer_h/2)*S - t.height/2)))
# clip to card
outside = Image.new('RGBA', img.size, TOK['canvas'])
final = Image.composite(img, outside, mask) if frame.get('radius') and not fpad else img
final.convert('RGB').save(OUT)
print(OUT, final.size, 'shown cols', shown, 'hidden', hidden)
