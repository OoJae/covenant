# Covenant brand: "Sealed by a die"

Phase 0 of the brand system: the marks, the tokens, the type and these guidelines. The site does not use them yet; Phase 1 moves `web/src/style.css` onto `web/src/styles/tokens.css` and `fonts.css`.

- Brand sheet: [`sheet.html`](sheet.html) (open it from a local server at the repo root, so that the relative font and token paths resolve), captured as [`brand-sheet.png`](brand-sheet.png) (1440 wide) and [`brand-sheet-375.png`](brand-sheet-375.png) (375 wide).
- Tokens: [`web/src/styles/tokens.css`](../../web/src/styles/tokens.css). Faces: [`web/src/styles/fonts.css`](../../web/src/styles/fonts.css).
- Generators: [`tools/build_fonts.py`](tools/build_fonts.py) (font subsets) and [`tools/make_marks.py`](tools/make_marks.py) (every SVG in this folder, and the symbol sprite inside `sheet.html`).

## Concept

"Die" means two things: a block of silicon that carries a circuit, and the engraved stamp that presses a seal. A covenant is a sealed vow, and Covenant's seal is pressed by a silicon die.

The layout follows from that: **a deed with a window**. A strict clause grid is printed on paper and cut open wherever the chip itself is shown.

- **Silicon** is everything the chip computes: the die, state words, routes, verdicts read from the chain.
- **Paper** is everything people wrote: clauses, explanations, the envelope's terms.

There is no theme toggle and `prefers-color-scheme` is not followed. A surface chooses its material with `class="silicon"` or `class="paper"`.

## The Bond (logomark)

One Manhattan wire bent into a C, closed by two pads. Rectangles only, square corners, on a 32-unit grid.

| Part | Rectangle (32 grid) | Fill |
|---|---|---|
| Spine | `x5 y6 w3 h20` | text colour (`--fg`) |
| Top arm | `x5 y6 w17 h3` | text colour |
| Bottom arm | `x5 y23 w17 h3` | text colour |
| Top pad | `x20 y3 w9 h9` | text colour |
| Bottom pad | `x20 y20 w9 h9` | Bond Gold (`--bond`, `#E6B450`) |

- **16 px cut** (`mark-16.svg`), fitted by hand to whole pixels: spine `x2 y3 w2 h10`, arms `x2 y3 w9 h2` and `x2 y11 w9 h2`, pads `x10 y1 w5 h5` and `x10 y10 w5 h5`. With 2 px arms and 5 px pads, each arm sits half a pixel off its pad's centre; the two offsets mirror each other, so the C stays symmetric.
- **Clear space:** one pad (9 units) on every side of the ink.
- **Minimum size:** 16 px. Use `mark-16.svg` from 16 to 23 px and `mark.svg` from 24 px up.
- **Mono** (`mark-mono.svg`): everything in the text colour, for one-colour printing and stamping.
- The SVGs fill from `var(--fg)` and `var(--bond)` when inlined, falling back to ink and gold when used as an image.

## Wordmark

"Covenant" in Bodoni Moda Italic, weight 500, sentence case, tracking −0.01em, with the font's own pair kerning (it moves v–e by −16 units in the text cut). It is outlined with fontTools pens, so no font is needed to draw it.

| Cut | File | Optical size | Use |
|---|---|---|---|
| Display | `wordmark-display.svg` | opsz 96 | 48 px cap height and up |
| Text | `wordmark-text.svg` | opsz 18 | below 48 px: header, footer, tabs |

Never set the wordmark in capitals, letter-space it, or retype it in a live font.

### Lockups

- **Horizontal** (`lockup-horizontal.svg`): the text cut's cap height spans the Bond's arms (y6 to y26); the baseline sits on the bottom edge of the lower arm; one pad (9 units) between the mark and the word.
- **Stacked** (`lockup-stacked.svg`): the Bond is centred over the word, the word is 3.2 times the mark's width, and one pad separates them.

## The Seal (signature element)

The chip's 64 latches drawn as an 8 × 8 impression. **Always real state bits, never decoration.**

- **Bit order.** Bit *i* of a state word is bit *(i mod 8)* of byte *⌊i/8⌋*, least significant bit first. This is TAP-20 section 5, and it is exactly `packBits` and `unpackBits` in `packages/tap20/src/bits.ts`. The Seal draws bit *i* at row ⌊i/8⌋, column *i mod 8*, so byte *k* of the hex word is row *k*, read with its least significant bit on the left. Bit 0 (pin 1) is the top-left cell.
- **Checked:** before drawing, `make_marks.py` decodes every field of both witness states with the field map in `chips/out/fg.fields.json` and asserts that each matches `stateFields` in the witness (for example A = 280 in bits 0–11 and CLOCK = 4 in bits 54–63 of state A). The script stops if the order is wrong.
- **Plate:** 100 units square. Each cell is 8 units at a 10-unit pitch, starting at 11. The top-left corner is cut away (a 14-unit chamfer), and a gold pin-1 square (7 units) sits in the cut. The plate has a 1-unit edge in the "0" colour, so the chamfer still reads where the plate meets a background of nearly the same colour.
- **Colours:** plate `--seal-plate`, a latch holding 1 `--bit-on`, a latch holding 0 `--bit`, pin 1 `--bond`.

| File | State word | Source | What it does with the word x |
|---|---|---|---|
| `seal-state-a.svg` | `0x18e1040906000001` | `reachA.state` in `chips/out/fg.witness.json` | buy 160, allowance 32, reserve 64 of 256, release 2; answers in CRUISE |
| `seal-state-b.svg` | `0x00e1840904008001` | `reachB.state` | buy 256 of 256, release 34; answers in DEFEND |
| `seal-cold.svg` | `0x0000000000000000` | every latch 0 | a kernel before its first settle; the 404 page |

Planned uses on the site: the hero climax (the latches fly into the Seal, which flips from A to B), the A/B cards, the vault (live `state()`), the audit (before and after), loading (it fills in level order), the 404 page (cold), the footer and the OG image.

## Colour

Near-monochrome with one accent. Route colours are for data only. Every value below is measured with the WCAG 2 relative-luminance formula; the brand sheet measures the same pairs live from the computed tokens.

### Raw palette

| Token | Hex | Role |
|---|---|---|
| `--wafer` / `--wafer-2` | `#0B0D10` / `#12161B` | Silicon surfaces |
| `--deed` / `--deed-2` | `#ECE7DB` / `#E3DDCF` | Paper surfaces |
| `--ink` / `--ink-2` | `#17150F` / `#5B564B` | Text on paper |
| `--quartz` / `--quartz-2` | `#E8E4DA` / `#8E949C` | Text on silicon; memory (latches, the Seal) |
| `--bond` | `#E6B450` | The one accent: activity, CTAs, pin 1, link underlines |
| `--bond-ink` | `#7D5710` | The accent as text or focus ring on paper |
| Routes | buy `#E6B450` / `#A87A12`; allowance `#7AA7FF` / `#2E5BC0`; reserve and release `#3FD3C0` / `#0F7A6E` | Data only (silicon / paper) |
| Verdicts, silicon | ok `#86D49B` on `#10261A`; bad `#F28B7D` on `#2A1513`; warn `#EE9455` on `#2A1A0E` | MATCH, DIFFERENT, STALE |
| Verdicts, paper | ok `#22663A` on `#D8E3CF`; bad `#9E2B20` on `#F0D6CF`; warn `#8A440A` on `#EFDCC3` | MATCH, DIFFERENT, STALE |

### Semantic tokens

Components read only these. `:root` and `.paper` set them for paper and `.silicon` re-points them, so each material can sit inside the other:

`--bg`, `--bg-2`, `--fg`, `--fg-2`, `--rule`, `--rule-strong`, `--accent` (a fill), `--accent-ink` (the accent as text), `--on-accent`, `--focus`, `--link`, `--c-buy`, `--c-allow`, `--c-res`, `--c-rel`, `--ok`, `--ok-bg`, `--bad`, `--bad-bg`, `--warn`, `--warn-bg`, `--wait`, `--wait-bg`, `--seal-plate`, `--bit-on`, `--bit`, `--grain`.

### Contrast

| Material | Pair | Colours | Ratio |
|---|---|---|---|
| silicon | quartz (body) | `#E8E4DA` on `#0B0D10` | 15.33:1 |
| silicon | quartz on wafer-2 | `#E8E4DA` on `#12161B` | 14.30:1 |
| silicon | quartz-2 (secondary) | `#8E949C` on `#0B0D10` | 6.36:1 |
| silicon | quartz-2 on wafer-2 | `#8E949C` on `#12161B` | 5.94:1 |
| silicon | bond as text | `#E6B450` on `#0B0D10` | 10.20:1 |
| silicon | ok / bad / warn text | on `#0B0D10` | 11.03 / 8.12 / 8.34:1 |
| silicon | MATCH / DIFFERENT / STALE plates | on their own backgrounds | 9.06 / 7.21 / 7.19:1 |
| silicon | route buy / allowance / reserve | on `#0B0D10` | 10.20 / 8.15 / 10.46:1 |
| silicon | latch 1 vs latch 0 | `#E8E4DA` on `#262D36` | 10.95:1 |
| silicon | rule (decorative) | `#262D36` on `#0B0D10` | 1.40:1 |
| paper | ink (body) | `#17150F` on `#ECE7DB` | 14.79:1 |
| paper | ink on deed-2 | `#17150F` on `#E3DDCF` | 13.48:1 |
| paper | ink-2 (secondary) | `#5B564B` on `#ECE7DB` | 5.91:1 |
| paper | ink-2 on deed-2 | `#5B564B` on `#E3DDCF` | 5.39:1 |
| paper | bond-ink as text | `#7D5710` on `#ECE7DB` | 5.25:1 |
| paper | ink on a gold CTA | `#17150F` on `#E6B450` | 9.57:1 |
| paper | bond fill vs deed | `#E6B450` on `#ECE7DB` | 1.55:1 (never text) |
| paper | ok / bad / warn text | on `#ECE7DB` | 5.62 / 6.03 / 5.84:1 |
| paper | MATCH / DIFFERENT / STALE plates | on their own backgrounds | 5.22 / 5.40 / 5.39:1 |
| paper | route buy / allowance / reserve | on `#ECE7DB` | 3.12 / 5.04 / 4.22:1 |
| paper | route buy on deed-2 | `#A87A12` on `#E3DDCF` | 2.84:1 (avoid) |
| paper | latch 1 vs latch 0 | `#17150F` on `#CFC7B5` | 10.85:1 |
| paper | rule (decorative) | `#CFC7B5` on `#ECE7DB` | 1.36:1 |

Rules:
- Text needs 4.5:1. Every text pair passes.
- Route fills and component edges need 3:1 against `--bg`. Paper route fills sit on `--deed`, not `--deed-2`.
- Gold is never text on paper: use `--accent-ink`.
- `--rule` is decorative only. An edge that must be seen uses `--rule-strong`.

Phase 1 adds `web/test/tokens.test.ts`, which checks these pairs automatically.

## Type

All three families are under the SIL Open Font License 1.1, are self-hosted as subset woff2 files, and declare no Reserved Font Name (checked in each `OFL.txt`), so the subsets keep their names. Licences: `web/src/fonts/OFL-*.txt`.

| Role | Family | File | Axes kept | Size |
|---|---|---|---|---|
| Display (1.75rem and up only) | Bodoni Moda, roman | `bodoni-moda-roman.woff2` | opsz 28–96, wght 400–600 | 30,068 B |
| Display italic (one clause per heading) | Bodoni Moda, italic | `bodoni-moda-italic.woff2` | opsz pinned at 72; wght 400–500; letters and sentence punctuation | 17,212 B |
| Body and UI | Instrument Sans | `instrument-sans.woff2` | wdth 85–100, wght 400–600 | 33,668 B |
| Data, labels, die markings | Fragment Mono Regular | `fragment-mono.woff2` | static | 8,728 B |
| | | | **Total** | **89,676 B** |

- Sources: `github.com/google/fonts`, `ofl/bodonimoda`, `ofl/instrumentsans` and `ofl/fragmentmono` (main branch, 2026-10-07).
- Subset: Basic Latin, Latin-1, Œ œ ı, typographic quotes and dashes, … • ′ ″ ‹ › ⁄ € ™ − ≈ ≠ ≤ ≥, plus ← ↑ → ↓ in the sans and mono, and ₮ ✓ ✗ ○ ● in the mono. Each family keeps only the glyphs its source has. ₮ is missing from Bodoni and Instrument Sans and falls back (in the site it sits in mono anyway).
- `fonts.css` uses `font-display: optional` and a `unicode-range` that lists exactly the code points each file carries.
- Instrument Sans keeps both axes, but uses the kerning of its default instance (wdth 100, wght 400): the variable kerning alone was 53 KB and pushed the file to 54 KB.

### Scale

| Step | Token | Value | Face |
|---|---|---|---|
| Hero | `--step-hero` | `clamp(2.75rem, 7vw, 8rem)`, line-height .92, tracking −0.025em | Bodoni |
| Display | `--step-display` | `clamp(2.25rem, 1.35rem + 3.8vw, 5rem)` | Bodoni |
| Chapter | `--step-chapter` | `clamp(1.75rem, 1.05rem + 3vw, 3.5rem)` | Bodoni |
| H2 | `--step-h2` | `clamp(1.75rem, 1.45rem + 1.3vw, 2.5rem)` | Bodoni |
| H3 | `--step-h3` | `1.25rem` | Instrument Sans 600 |
| Lede | `--step-lede` | `clamp(1.125rem, 1rem + .55vw, 1.4375rem)` | Instrument Sans |
| Body | `--step-body` | `1.0625rem`, line-height 1.6, measure 64ch | Instrument Sans |
| Small | `--step-small` | `.875rem` | Instrument Sans |
| Label | `--step-label` | `.75rem`, uppercase, tracking .08em | Fragment Mono |
| Micro | `--step-micro` | `.6875rem`, tracking .06em | Fragment Mono |

In a heading, at most one clause goes in italic, at weight 500. UI text (buttons, nav, table heads) uses `--stretch-ui` (88%), set through Instrument Sans's width axis.

## Grid, space and form

- **Grid:** 4 columns below 640 px (16 px side gutter), 8 from 640 px, 12 from 1024 px; max content width 90rem. From 1024 px the clause number hangs in the first two columns and the text starts at column 3.
- **Deliberate breaks:** the hero h1 runs over the canvas, clause numbers hang in the gutter, and silicon inserts bleed to the edge.
- **Space:** a 4 px pitch (`--sp-1` .25rem to `--sp-10` 8rem) and `--sp-section`, `clamp(4rem, 2.5rem + 7vw, 10rem)`.
- **Form:** `--radius: 0` and `--shadow: none`. Depth comes from the two materials, the grain and the order things arrive in. Hairlines are 1 px; the wire (active link underline) is 2 px; focus is a 2 px square outline in `--focus`.
- **Targets:** CTAs are at least `--tap` (48 px) tall, and stack at 375 px.

## Grain

An SVG `feTurbulence` noise tile (200 px, fractal noise, `baseFrequency` .85, 3 octaves) is inlined as a data URI per material:

- `--grain-si`: light noise at 5% on silicon;
- `--grain-pa`: ink-coloured noise at 3% on paper.

`--grain` points at the right one for the current material. Use it as `background-image` on a material surface, never on text.

## Icons

Nine icons on a 24 grid, with a 1.5 stroke, square caps, mitred joins and right angles only. Arrows are wires that end in a filled pad. The source is `icons.svg`, a `<symbol>` sprite; the brand sheet shows each icon at 72, 24 and 16 px.

| Id | Meaning |
|---|---|
| `i-arrow-right` | go, open, next |
| `i-arrow-down` | scroll on |
| `i-external` | leaves the site: explorer, source |
| `i-match` | the chain agrees |
| `i-differ` | the routes are not the same |
| `i-chip` | circuit, processor |
| `i-clock` | the epoch clock: settle, history |
| `i-lock` | the envelope: limits fixed at creation |
| `i-menu` | the menu |

## Motion

| Token | Value | Use |
|---|---|---|
| `--ease-reveal` | `cubic-bezier(.16, 1, .3, 1)` | things arriving: lines, plates, pages |
| `--ease-toggle` | `cubic-bezier(.65, 0, .35, 1)` | things changing state: A to B, a switch |
| `--dur-press` | 120 ms | press down |
| `--dur-micro` | 240 ms | hover, small changes |
| `--dur-toggle` | 320 ms | toggles |
| `--dur-release` / `--dur-exit` | 350 ms | release after a press; a page leaving |
| `--dur-reveal` | 900 ms | reveals; a page arriving |
| `--dur-page` | 1100 ms | the whole page transition |
| `--stagger` | 60 ms | per level, in level order, like the wavefront |
| `--press-scale` / `--press-y` | .97 / 1 px | the CTA press |

Principles:
- Motion follows the chip's order: things light up in level order, the way a beat runs through the netlist.
- A press is physical. It sinks 1 px and scales to .97 over 120 ms, then releases over 350 ms on the reveal ease, leaving a square gold impression.
- Nothing loops for decoration. The die animates only while it is computing something real.
- Under `prefers-reduced-motion: reduce`, every duration and the stagger become 0 and the press does not move.

## Imagery and voice

- **Imagery:** only real artefacts: the netlist die, real state words, computed numbers. No stock photos and no AI images. If it looks like state, it must be state.
- **Voice:** plain verbs, sentence case, written from the reader's side ("Check it yourself", "Run the eight checks"). No superlatives and no "first ever". Every sentence is checked against the claims audit. Keep "Unaudited" and "Adoption is zero" wherever the claims are made.
- **Verdicts:** a colour always comes with its word: MATCH, DIFFERENT, STALE, WAITING.

## Decisions (critique pass)

For each token we asked: *would I produce this for any brief?* Where the answer was yes, we either tied the token to Covenant or wrote down why it stays.

1. **Gold split into fill and ink.** Gold on deed is 1.55:1, so `--bond` is a fill only on paper and `--bond-ink` (`#7D5710`, 5.25:1) carries gold as text and focus. The semantic pair `--accent` / `--accent-ink` makes this automatic.
2. **No link blue.** The current site has a blue `--link`, which would be a second accent. Links are now the text colour with a gold wire underline (`--wire`, 2 px), as the plan says.
3. **Verdict colours warmed and paired with words.** Plain traffic-light green and red fit any brief. They are pulled toward the materials (forest ink, sealing-wax red, burnt amber on paper; soft tints on silicon) and are never used without the word. We considered dropping green for ink: kept, because MATCH must read at a glance on the audit page.
4. **Paper route fills only on `--deed`.** Buy on `--deed-2` is 2.84:1 and fails the 3:1 rule for graphics.
5. **The Seal plate has an edge.** `--wafer-2` on `--wafer` is 1.07:1, so the pin-1 chamfer vanished on silicon. A 1-unit edge in the "0" colour makes it read without a shadow.
6. **`--stretch-ui` (88%).** A narrowed Instrument Sans for buttons, nav and table heads uses the width axis we already pay for, instead of a generic letter-spaced capitals style.
7. **Instrument Sans kerning flattened.** We kept both axes and the default instance's kerning to stay under 40 KB (33.7 KB, against 54.4 KB with variable kerning). Kerning drift across wdth 85–100 is small at body sizes.
8. **The 4 px spacing pitch is generic,** and is kept because it is practical. What ties the layout to Covenant is the clause gutter and the material change, not the spacing scale.
9. **The grain is the most generic token.** It is kept at the plan's 5% / 3%, because it is what separates the two materials from flat UI colours. It is the first candidate to cut if it costs paint time on the scene.
10. **`--c-rel` uses the reserve hue.** A release is money leaving the reserve, so it is not given a fourth route colour.

## Asset index

| File | What |
|---|---|
| `mark.svg` | The Bond, 32 grid, two colours |
| `mark-mono.svg` | The Bond, one colour |
| `mark-16.svg` | The Bond, hand-fitted 16 px cut |
| `wordmark-display.svg` | "Covenant", outlined, opsz 96 |
| `wordmark-text.svg` | "Covenant", outlined, opsz 18 |
| `lockup-horizontal.svg` | Bond + text-cut wordmark, side by side |
| `lockup-stacked.svg` | Bond over the text-cut wordmark |
| `seal-state-a.svg` | Seal of `reachA.state` `0x18e1040906000001` |
| `seal-state-b.svg` | Seal of `reachB.state` `0x00e1840904008001` |
| `seal-cold.svg` | Seal of the all-zero state |
| `icons.svg` | Icon sprite, 24 grid |
| `sheet.html` | The brand sheet |
| `brand-sheet.png`, `brand-sheet-375.png` | Brand-sheet captures at 1440 and 375 px (quantised to 128 colours) |
| `tools/build_fonts.py` | Rebuilds `web/src/fonts/*.woff2` from the Google Fonts sources |
| `tools/make_marks.py` | Redraws every SVG here and the sprite in `sheet.html`; checks the Seal's bit order |
| `../../web/src/styles/tokens.css` | Tokens (standalone; not yet imported by the app) |
| `../../web/src/styles/fonts.css` | `@font-face` rules |
| `../../web/src/fonts/` | The four woff2 subsets and the three `OFL.txt` licences |

Still to come, from the plan: `x-header-1500x500.jpg` and `x-avatar-400.png`, captured from the finished site. Done: `og-1200x630.jpg`, the link card (the same bytes as `web/public/og.jpg`), captured from the landing hero by `tools/og_card.mjs`.
