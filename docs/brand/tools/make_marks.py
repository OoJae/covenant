"""Draw the Covenant marks as SVG: the Bond, the wordmark (outlined, no font needed), the lockups, the Seal and
the icon set. Also refreshes the symbol sprite inside docs/brand/sheet.html.

    python3 docs/brand/tools/make_marks.py <dir with BodoniModa-Italic-VF.ttf>

The wordmark is "Covenant" in Bodoni Moda Italic, weight 500, tracking -0.01em, kerned from the font's own GPOS
pair kerning and outlined with fontTools pens. Two optical cuts: text (opsz 18) and display (opsz 96).

The Seal draws real state words of the Flow Governor from chips/out/fg.witness.json. Bit i of a state word is bit
(i mod 8) of byte floor(i / 8), least significant bit first (packages/tap20/src/bits.ts, TAP-20 section 5); it is
drawn at row floor(i / 8), column i mod 8. The script checks that order against the field map in
chips/out/fg.fields.json before drawing: A must read 280 and CLOCK 4 from reachA.state.
"""
import json, os, re, sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.boundsPen import BoundsPen

HERE = os.path.dirname(os.path.abspath(__file__))
BRAND = os.path.normpath(os.path.join(HERE, '..'))
ROOT = os.path.normpath(os.path.join(BRAND, '..', '..'))
SRC = sys.argv[1] if len(sys.argv) > 1 else None

INK, BOND, QUARTZ = '#17150F', '#E6B450', '#E8E4DA'
# The fills read the page's tokens when the SVG is inlined (var(--fg) follows .silicon / .paper) and fall back to
# the paper colours when the file is used as an image.
STYLE_MARK = '<style>.w{fill:var(--fg,%s)}.p{fill:var(--bond,%s)}</style>' % (INK, BOND)


def num(v):
    s = ('%.2f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


# ---------------------------------------------------------------- the Bond
# 32-unit grid. One Manhattan wire bent into a C (spine plus two arms), closed by two pads; the bottom pad is gold.
BOND_32 = {
    'wire': [(5, 6, 3, 20), (5, 6, 17, 3), (5, 23, 17, 3)],
    'pad': (20, 3, 9, 9),
    'gold': (20, 20, 9, 9),
}
# 16-unit grid, fitted by hand to whole pixels: spine and arms 2 px, pads 5 px, the 8-unit gap between the pads
# kept at a quarter of the height (4 px).
BOND_16 = {
    'wire': [(2, 3, 2, 10), (2, 3, 9, 2), (2, 11, 9, 2)],
    'pad': (10, 1, 5, 5),
    'gold': (10, 10, 5, 5),
}


def rect(r, cls=None, dx=0, dy=0, k=1):
    x, y, w, h = r
    c = f' class="{cls}"' if cls else ''
    return f'<rect{c} x="{num(x * k + dx)}" y="{num(y * k + dy)}" width="{num(w * k)}" height="{num(h * k)}"/>'


def bond_body(b, dx=0, dy=0, k=1, mono=False):
    w = ''.join(rect(r, dx=dx, dy=dy, k=k) for r in b['wire'] + [b['pad']])
    if mono:
        return f'<g class="w">{w}{rect(b["gold"], dx=dx, dy=dy, k=k)}</g>'
    return f'<g class="w">{w}</g>' + rect(b['gold'], 'p', dx, dy, k)


def svg(view, body, title, w=None, h=None, extra=''):
    vw, vh = view[2], view[3]
    size = f' width="{num(w if w is not None else vw)}" height="{num(h if h is not None else vh)}"'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(num(v) for v in view)}"{size} role="img"'
            f' aria-label="{title}"{extra}>{body}</svg>\n')


# ---------------------------------------------------------------- wordmark
def kern_table(f):
    """(left, right) -> x advance adjustment from the GPOS 'kern' feature (pair lookups, formats 1 and 2)."""
    gpos = f['GPOS'].table
    idx = sorted({i for fr in gpos.FeatureList.FeatureRecord if fr.FeatureTag == 'kern' for i in fr.Feature.LookupListIndex})
    subs = []
    for i in idx:
        lk = gpos.LookupList.Lookup[i]
        for st in lk.SubTable:
            if lk.LookupType == 9:
                st = st.ExtSubTable
            if getattr(st, 'LookupType', 2) == 2 or st.__class__.__name__ == 'PairPos':
                subs.append(st)

    def pair(l, r):
        for st in subs:
            cov = st.Coverage.glyphs
            if l not in cov:
                continue
            if st.Format == 1:
                for pvr in st.PairSet[cov.index(l)].PairValueRecord:
                    if pvr.SecondGlyph == r:
                        return getattr(pvr.Value1, 'XAdvance', 0) or 0
            elif st.Format == 2:
                c1 = st.ClassDef1.classDefs.get(l, 0)
                c2 = st.ClassDef2.classDefs.get(r, 0)
                v = st.Class1Record[c1].Class2Record[c2].Value1
                adv = getattr(v, 'XAdvance', 0) or 0 if v is not None else 0
                if adv:
                    return adv
        return 0

    return pair


def wordmark(text, opsz, wght=500, tracking=-0.01):
    f = instantiateVariableFont(TTFont(os.path.join(SRC, 'BodoniModa-Italic-VF.ttf'), lazy=False), {'opsz': opsz, 'wght': wght})
    upm = f['head'].unitsPerEm
    cmap, gs = f.getBestCmap(), f.getGlyphSet()
    names = [cmap[ord(c)] for c in text]
    pair = kern_table(f)
    x, parts, kerns = 0.0, [], []
    bp = BoundsPen(gs)
    for i, n in enumerate(names):
        pen = SVGPathPen(gs, ntos=num)
        gs[n].draw(TransformPen(pen, (1, 0, 0, -1, x, 0)))
        parts.append(pen.getCommands())
        gs[n].draw(TransformPen(bp, (1, 0, 0, -1, x, 0)))
        adv = gs[n].width
        if i < len(names) - 1:
            k = pair(n, names[i + 1])
            kerns.append(k)
            adv += k + tracking * upm
        x += adv
    xmin, ymin, xmax, ymax = bp.bounds
    cap = f['OS/2'].sCapHeight
    return {'d': ''.join(parts), 'bounds': (xmin, ymin, xmax, ymax), 'cap': cap, 'upm': upm, 'kerns': kerns, 'opsz': opsz}


def wordmark_svg(wm, name):
    xmin, ymin, xmax, ymax = wm['bounds']
    view = (xmin, ymin, xmax - xmin, ymax - ymin)
    h = 64
    w = h * view[2] / view[3]
    body = f'<style>.w{{fill:var(--fg,{INK})}}</style><path class="w" d="{wm["d"]}"/>'
    return svg(view, body, 'Covenant', w, h, f' data-cut="{name} opsz {wm["opsz"]}"')


def lockups(wm):
    """Horizontal: the wordmark's cap height spans the Bond's arms (y6 to y26 on the 32 grid), one pad (9 units) of
    space between. Stacked: the Bond centred over the wordmark, one pad of space between."""
    xmin, ymin, xmax, ymax = wm['bounds']
    out = {}
    # horizontal
    k = 20 / wm['cap']  # cap height = 20 units
    mark_ink = (5, 3, 24, 26)  # x, y, w, h of the Bond's ink on the 32 grid
    gap = 9
    tx = mark_ink[0] + mark_ink[2] + gap - xmin * k
    ty = 26  # baseline on the bottom edge of the lower arm
    right = tx + xmax * k
    top = min(mark_ink[1], ty + ymin * k)
    bottom = max(mark_ink[1] + mark_ink[3], ty + ymax * k)
    view = (mark_ink[0], top, right - mark_ink[0], bottom - top)
    body = (STYLE_MARK + bond_body(BOND_32) +
            f'<path class="w" transform="translate({num(tx)} {num(ty)}) scale({k:.6g})" d="{wm["d"]}"/>')
    out['horizontal'] = svg(view, body, 'Covenant', 64 * view[2] / view[3], 64)
    # stacked: word set so the mark is a third of its width
    word_w = (xmax - xmin)
    k2 = (mark_ink[2] * 3.2) / word_w
    mark_cx = mark_ink[0] + mark_ink[2] / 2
    ww = word_w * k2
    tx2 = mark_cx - ww / 2 - xmin * k2
    ty2 = mark_ink[1] + mark_ink[3] + gap - ymin * k2
    left = min(mark_ink[0], tx2 + xmin * k2)
    right2 = max(mark_ink[0] + mark_ink[2], tx2 + xmax * k2)
    bottom2 = ty2 + ymax * k2
    view2 = (left, mark_ink[1], right2 - left, bottom2 - mark_ink[1])
    body2 = (STYLE_MARK + bond_body(BOND_32) +
             f'<path class="w" transform="translate({num(tx2)} {num(ty2)}) scale({k2:.6g})" d="{wm["d"]}"/>')
    out['stacked'] = svg(view2, body2, 'Covenant', 128 * view2[2] / view2[3], 128)
    return out


# ---------------------------------------------------------------- the Seal
def bits_of(hexword, n=64):
    h = hexword[2:] if hexword.startswith('0x') else hexword
    b = bytes.fromhex(h)
    return [(b[i >> 3] >> (i & 7)) & 1 if (i >> 3) < len(b) else 0 for i in range(n)]


def field(bits, off, width):
    return sum(bits[off + j] << j for j in range(width))


SEAL_STYLE = ('<style>.pl{fill:var(--seal-plate,#12161B)}.ed{fill:none;stroke:var(--bit,#262D36);stroke-width:1}.on{fill:var(--bit-on,#E8E4DA)}.off{fill:var(--bit,#262D36)}'
              '.p1{fill:var(--bond,#E6B450)}</style>')


def seal_body(bits):
    # 100-unit plate; the pin-1 corner is cut away and the gold pin-1 square sits in the cut.
    out = [SEAL_STYLE, '<path class="pl" d="M14 0H100V100H0V14Z"/>', '<path class="ed" d="M14.2 .5H99.5V99.5H.5V14.2Z"/>', '<rect class="p1" x="0" y="0" width="7" height="7"/>']
    on, off = [], []
    for i, v in enumerate(bits):
        r, c = i >> 3, i & 7
        (on if v else off).append(f'M{11 + 10 * c} {11 + 10 * r}h8v8h-8z')
    if off:
        out.append(f'<path class="off" d="{"".join(off)}"/>')
    if on:
        out.append(f'<path class="on" d="{"".join(on)}"/>')
    return ''.join(out)


def seal_svg(hexword, title):
    bits = bits_of(hexword)
    desc = (f'<desc>State word {hexword}. Bit i is drawn at row floor(i/8), column i mod 8: byte k of the word is row k, '
            f'least significant bit on the left. Pin 1 (bit 0) is the top-left cell, by the gold square.</desc>')
    return svg((0, 0, 100, 100), f'<title>{title}</title>{desc}' + seal_body(bits), title, 192, 192)


# ---------------------------------------------------------------- icons (24 grid, 1.5 stroke, right angles)
ICONS = {
    'arrow-right': ('Wire to a pad: go, open, next', '<path d="M3 12H16"/><rect class="pad" x="16" y="9.5" width="5" height="5"/>'),
    'arrow-down': ('Wire down to a pad: scroll on', '<path d="M12 3V16"/><rect class="pad" x="9.5" y="16" width="5" height="5"/>'),
    'external': ('Leaves the site: explorer, source', '<path d="M11 5H5V19H19V13"/><path d="M10 14H16.5V8"/><rect class="pad" x="14" y="3" width="5" height="5"/>'),
    'match': ('Match: the chain agrees', '<path d="M4 4H20V20H4Z"/><path d="M8 10H16M8 14H16"/>'),
    'differ': ('Differ: the routes are not the same', '<path d="M4 4H20V20H4Z"/><path d="M8 10H16M11 14H16"/><rect class="pad" x="7" y="12.5" width="3" height="3"/>'),
    'chip': ('A chip: circuit, processor', '<path d="M7 7H17V17H7Z"/><path d="M10 7V3M14 7V3M10 21V17M14 21V17M3 10H7M3 14H7M17 10H21M17 14H21"/><rect class="pad" x="9" y="9" width="3" height="3"/>'),
    'clock': ('The epoch clock: settle, history', '<path d="M4 4H20V20H4Z"/><path d="M12 7V12H16"/>'),
    'lock': ('The envelope: limits fixed at creation', '<path d="M5 11H19V20H5Z"/><path d="M8 11V5H16V11"/><path d="M12 14.5V16.5"/>'),
    'menu': ('Menu', '<path d="M4 6H20M4 12H14M4 18H20"/><rect class="pad" x="15.5" y="9.5" width="5" height="5"/>'),
}
ICON_STYLE = 'fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="square" stroke-linejoin="miter"'


def icons_sprite():
    syms = []
    for name, (title, body) in ICONS.items():
        b = body.replace('class="pad"', 'class="pad" fill="currentColor" stroke="none"')
        syms.append(f'<symbol id="i-{name}" viewBox="0 0 24 24"><title>{title}</title><g {ICON_STYLE}>{b}</g></symbol>')
    return syms


def main():
    if not SRC:
        sys.exit('usage: make_marks.py <dir with BodoniModa-Italic-VF.ttf>')
    w = lambda name, text: open(os.path.join(BRAND, name), 'w').write(text)

    # The Bond
    w('mark.svg', svg((0, 0, 32, 32), STYLE_MARK + bond_body(BOND_32), 'Covenant', 256, 256))
    w('mark-mono.svg', svg((0, 0, 32, 32), f'<style>.w{{fill:var(--fg,{INK})}}</style>' + bond_body(BOND_32, mono=True), 'Covenant', 256, 256))
    w('mark-16.svg', svg((0, 0, 16, 16), STYLE_MARK + bond_body(BOND_16), 'Covenant', 16, 16, ' shape-rendering="crispEdges"'))

    # Wordmark and lockups
    text_cut = wordmark('Covenant', 18)
    display_cut = wordmark('Covenant', 96)
    w('wordmark-text.svg', wordmark_svg(text_cut, 'text'))
    w('wordmark-display.svg', wordmark_svg(display_cut, 'display'))
    lk = lockups(text_cut)
    w('lockup-horizontal.svg', lk['horizontal'])
    w('lockup-stacked.svg', lk['stacked'])

    # The Seal, from the real witness states, after checking the bit order against the field map.
    wit = json.load(open(os.path.join(ROOT, 'chips/out/fg.witness.json')))
    fields = {f['name']: f for f in json.load(open(os.path.join(ROOT, 'chips/out/fg.fields.json')))['state']}
    for key in ('reachA', 'reachB'):
        bits = bits_of(wit[key]['state'])
        for name, want in wit[key]['stateFields'].items():
            got = field(bits, fields[name]['offset'], fields[name]['width'])
            assert got == want, f'{key}.{name}: bit order reads {got}, witness says {want}'
    a, b = wit['reachA']['state'], wit['reachB']['state']
    w('seal-state-a.svg', seal_svg(a, f'State A, {a}'))
    w('seal-state-b.svg', seal_svg(b, f'State B, {b}'))
    w('seal-cold.svg', seal_svg('0x' + '00' * 8, 'Cold seal, 0x0000000000000000'))

    # Icons
    w('icons.svg', '<svg xmlns="http://www.w3.org/2000/svg" style="display:none">' + ''.join(icons_sprite()) + '</svg>\n')

    # Sprite for the brand sheet: every mark as a <symbol> that inherits the page's tokens.
    def sym(id_, view, body):
        return f'<symbol id="{id_}" viewBox="{" ".join(num(v) for v in view)}">{body}</symbol>'

    def from_file(name, id_):
        s = open(os.path.join(BRAND, name)).read()
        view = re.search(r'viewBox="([^"]+)"', s).group(1)
        inner = re.sub(r'^<svg[^>]*>|</svg>\s*$', '', s.strip())
        inner = re.sub(r'<style>.*?</style>|<title>.*?</title>|<desc>.*?</desc>', '', inner)
        return f'<symbol id="{id_}" viewBox="{view}">{inner}</symbol>'

    parts = [from_file(n, i) for n, i in [('mark.svg', 'bond'), ('mark-16.svg', 'bond-16'), ('wordmark-text.svg', 'wm-text'),
                                            ('wordmark-display.svg', 'wm-display'), ('lockup-horizontal.svg', 'lockup-h'),
                                            ('lockup-stacked.svg', 'lockup-s'), ('seal-state-a.svg', 'seal-a'),
                                            ('seal-state-b.svg', 'seal-b'), ('seal-cold.svg', 'seal-cold')]]
    parts += icons_sprite()
    sprite = ('<svg class="sprite" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" style="position:absolute;width:0;height:0;overflow:hidden">'
              + ''.join(parts) + '</svg>')
    sheet = os.path.join(BRAND, 'sheet.html')
    if os.path.exists(sheet):
        html = open(sheet).read()
        html2 = re.sub(r'<!-- sprite:start -->.*?<!-- sprite:end -->', lambda m: '<!-- sprite:start -->' + sprite + '<!-- sprite:end -->', html, flags=re.S)
        open(sheet, 'w').write(html2)

    print('wordmark kerning (text cut):', text_cut['kerns'], 'cap', text_cut['cap'], 'upm', text_cut['upm'])
    print('wordmark kerning (display cut):', display_cut['kerns'])
    print('A bits:', ''.join(map(str, bits_of(a))))
    print('B bits:', ''.join(map(str, bits_of(b))))


if __name__ == '__main__':
    main()
