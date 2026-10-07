"""Instance and subset the three OFL families for the Covenant site.

Sources: github.com/google/fonts (ofl/bodonimoda, ofl/instrumentsans, ofl/fragmentmono), main branch, 2026-10-07.
None of the three OFL.txt files declares a Reserved Font Name, so the subsets keep their family names.

    python3 docs/brand/tools/build_fonts.py <dir with the source .ttf files> [out dir, default web/src/fonts]

The source files, saved under these names:
    BodoniModa-VF.ttf          ofl/bodonimoda/BodoniModa[opsz,wght].ttf
    BodoniModa-Italic-VF.ttf   ofl/bodonimoda/BodoniModa-Italic[opsz,wght].ttf
    InstrumentSans-VF.ttf      ofl/instrumentsans/InstrumentSans[wdth,wght].ttf
    FragmentMono-Regular.ttf   ofl/fragmentmono/FragmentMono-Regular.ttf
Needs fontTools (4.60 used) and brotli.
"""
import io, os, sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, '..', '..', '..', 'web', 'src', 'fonts')
os.makedirs(OUT, exist_ok=True)


def r(a, b):
    return list(range(a, b + 1))


# Basic Latin, Latin-1 Supplement, Latin Extended-A letters used in names (ı, Œ œ), and the punctuation the site
# and the brand sheet use. Glyphs a font lacks are simply absent; the browser falls back for them (₮ in the sans).
LATIN = (
    r(0x20, 0x7E) + r(0xA0, 0xFF) + [0x131, 0x152, 0x153, 0x2C6, 0x2DA, 0x2DC]
    + r(0x2013, 0x2014) + r(0x2018, 0x201A) + r(0x201C, 0x201E) + [0x2022, 0x2026, 0x2032, 0x2033, 0x2039, 0x203A, 0x2044]
    + [0x20AC, 0x2122, 0x2212, 0x2248, 0x2260, 0x2264, 0x2265]
)
ARROWS = r(0x2190, 0x2193)
DATA = [0x20AE, 0x2713, 0x2717, 0x25CB, 0x25CF, 0x25D0, 0x2715]  # ₮ and the status marks (mono only)
# The italic is used for one emphasised clause per heading and for the wordmark: letters, digits and the
# punctuation a sentence needs.
ITALIC = r(0x20, 0x7E) + [0x2019, 0x2018, 0x201C, 0x201D, 0x2013, 0x2014, 0x2026, 0xA0, 0xE9, 0xE8, 0xEF, 0xF6, 0xFC]

JOBS = [
    # (source, output, axis limits, unicodes, layout features)
    ('BodoniModa-VF.ttf', 'bodoni-moda-roman.woff2', {'opsz': (28, 96), 'wght': (400, 600)}, LATIN,
     ['kern', 'mark', 'ccmp', 'locl', 'liga', 'lnum', 'onum', 'pnum', 'tnum', 'case']),
    ('BodoniModa-Italic-VF.ttf', 'bodoni-moda-italic.woff2', {'opsz': 72, 'wght': (400, 500)}, ITALIC,
     ['kern', 'mark', 'ccmp', 'locl', 'liga', 'lnum']),
    ('InstrumentSans-VF.ttf', 'instrument-sans.woff2', {'wdth': (85, 100), 'wght': (400, 600)}, LATIN + ARROWS,
     ['kern', 'mark', 'mkmk', 'ccmp', 'locl', 'liga', 'pnum', 'tnum', 'case']),
    ('FragmentMono-Regular.ttf', 'fragment-mono.woff2', None, LATIN + ARROWS + DATA,
     ['mark', 'mkmk', 'ccmp', 'locl', 'zero', 'case']),
]

total = 0
for src, out, limits, unicodes, feats in JOBS:
    f = TTFont(os.path.join(SRC, src), lazy=False)
    if limits:
        f = instancer.instantiateVariableFont(f, limits, updateFontNames=False)
        if out == 'instrument-sans.woff2':
            # Variable kerning across wdth x wght is 53 KB of GPOS on its own. Keep the axes, but use the kerning and
            # mark positions of the default instance (wdth 100, wght 400): the glyph order is unchanged by instancing.
            st = instancer.instantiateVariableFont(TTFont(os.path.join(SRC, src), lazy=False), {'wdth': 100, 'wght': 400})
            f['GPOS'] = st['GPOS']
            f['GDEF'] = st['GDEF']
        buf = io.BytesIO(); f.save(buf); buf.seek(0); f = TTFont(buf, lazy=False)
    opts = subset.Options()
    opts.flavor = 'woff2'
    opts.layout_features = feats
    opts.hinting = False
    opts.desubroutinize = True
    opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]  # keep copyright, names, licence and licence URL
    opts.name_languages = [0x409]
    opts.notdef_outline = True
    opts.drop_tables += ['DSIG', 'STAT'] if not limits else ['DSIG']
    s = subset.Subsetter(opts)
    s.populate(unicodes=unicodes)
    s.subset(f)
    p = os.path.join(OUT, out)
    f.flavor = 'woff2'
    f.save(p)
    n = os.path.getsize(p)
    total += n
    axes = [(a.axisTag, a.minValue, a.defaultValue, a.maxValue) for a in f['fvar'].axes] if 'fvar' in f else 'static'
    print(f'{out:28s} {n:7d} B  glyphs {len(f.getGlyphOrder()):4d}  axes {axes}')
print(f'{"total":28s} {total:7d} B')
