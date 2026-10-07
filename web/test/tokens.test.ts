// The brand tokens (src/styles/tokens.css), checked for contrast per material with the WCAG 2 relative-luminance
// formula: every text pair at 4.5:1 or more, every graphic (route fills, component edges, focus, latch cells) at
// 3:1 or more. The pairs are the ones the stylesheets actually use (docs/brand/README.md, "Contrast"). No browser,
// no network: the file is parsed and every var() is resolved here.

import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import { siliconDieTheme } from '../src/components/Die.tsx';

const css = readFileSync(new URL('../src/styles/tokens.css', import.meta.url), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

/** Top-level rule blocks (not inside an at-rule) as [selector, declarations]. */
function topLevelRules(text: string): [string, Map<string, string>][] {
  const out: [string, Map<string, string>][] = [];
  let depth = 0;
  let start = 0;
  let head = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '{') {
      if (depth === 0) {
        head = text.slice(start, i).trim();
        start = i + 1;
      }
      depth++;
    } else if (c === '}') {
      depth--;
      if (depth === 0) {
        if (!head.startsWith('@')) {
          const decls = new Map<string, string>();
          for (const m of text.slice(start, i).matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) decls.set(m[1], m[2].trim());
          out.push([head.replace(/\s+/g, ' '), decls]);
        }
        start = i + 1;
      }
    }
  }
  return out;
}

const rules = topLevelRules(css);
const block = (selector: string): Map<string, string> => {
  const r = rules.find(([s]) => s === selector);
  if (!r) throw new Error(`tokens.css has no top-level rule ${selector}`);
  return r[1];
};
const raw = block(':root');
const MATERIALS = { paper: new Map([...raw, ...block(':root, .paper')]), silicon: new Map([...raw, ...block('.silicon')]) };
type Material = keyof typeof MATERIALS;

/** A token's colour in a material, with every var() followed. */
function colour(material: Material, name: string, seen: string[] = []): string {
  const v = MATERIALS[material].get(name);
  if (v === undefined) throw new Error(`${name} is not defined for ${material}`);
  if (seen.includes(name)) throw new Error(`var() cycle at ${name}`);
  const ref = v.match(/^var\((--[\w-]+)\)$/);
  if (ref) return colour(material, ref[1], [...seen, name]);
  if (!/^#[0-9a-f]{6}$/i.test(v)) throw new Error(`${name} in ${material} is ${v}, not a #rrggbb colour`);
  return v.toLowerCase();
}

const channels = (hex: string): number[] => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
function luminance(hex: string): number {
  const [r, g, b] = channels(hex).map((c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}
/** `fg` at `alpha` over `bg`, as the browser composites it (in sRGB). */
const over = (fg: string, alpha: number, bg: string): string =>
  '#' +
  channels(fg)
    .map((c, i) => Math.round(c * alpha + channels(bg)[i] * (1 - alpha)))
    .map((c) => c.toString(16).padStart(2, '0'))
    .join('');

// Text: 4.5:1. [foreground, background, where it is used]
const TEXT: [string, string, string][] = [
  ['--fg', '--bg', 'body text'],
  ['--fg', '--bg-2', 'text on a plate, a table head, the Seal plate'],
  ['--fg-2', '--bg', 'secondary text, labels, notes'],
  ['--fg-2', '--bg-2', 'secondary text on a plate'],
  ['--accent-ink', '--bg', 'clause numbers, the accent as text'],
  ['--link', '--bg', 'links'],
  ['--on-accent', '--accent', 'a gold call to action'],
  ['--bg', '--fg', 'the chosen option of a switch'],
  ['--ok', '--bg', 'MATCH as text'],
  ['--bad', '--bg', 'DIFFERENT as text'],
  ['--warn', '--bg', 'STALE and warnings as text'],
  ['--wait', '--bg', 'WAITING as text'],
  ['--ok', '--ok-bg', 'the MATCH plate and mark'],
  ['--bad', '--bad-bg', 'the MISMATCH plate and mark'],
  ['--warn', '--warn-bg', 'the warn plate (SIMULATION)'],
  ['--wait', '--wait-bg', 'the waiting mark and tag'],
  ['--fg', '--ok-bg', 'text on a MATCH plate'],
  ['--fg', '--bad-bg', 'text on a MISMATCH plate'],
  ['--fg', '--warn-bg', 'text on a warn plate'],
  ['--fg-2', '--ok-bg', 'evidence lines on a MATCH plate'],
  ['--fg-2', '--bad-bg', 'evidence lines on a MISMATCH plate'],
  ['--fg-2', '--warn-bg', 'notes on a warn plate'],
];

// Graphics: 3:1 against the surface they sit on.
const GRAPHICS: [string, string, string][] = [
  ['--c-buy', '--bg', 'buy-and-lock bars'],
  ['--c-allow', '--bg', 'allowance bars'],
  ['--c-res', '--bg', 'reserve bars'],
  ['--c-rel', '--bg', 'the release key'],
  ['--rule-strong', '--bg', 'component edges: buttons, inputs, cards'],
  ['--rule-strong', '--bg-2', 'component edges on a plate'],
  ['--focus', '--bg', 'the focus outline'],
  ['--focus', '--bg-2', 'the focus outline on a plate'],
  ['--bit-on', '--bit', 'a latch holding 1 against one holding 0'],
  ['--bit-on', '--seal-plate', 'a latch holding 1 on the Seal plate'],
];

describe('tokens.css', () => {
  test('both materials define every semantic token, and each resolves to a colour', () => {
    const semantic = [...new Set([...block(':root, .paper').keys(), ...block('.silicon').keys()])].filter((k) => k !== '--grain');
    expect(semantic.length).toBeGreaterThan(25);
    for (const m of Object.keys(MATERIALS) as Material[]) for (const k of semantic) expect(() => colour(m, k), `${k} in ${m}`).not.toThrow();
  });

  for (const m of Object.keys(MATERIALS) as Material[]) {
    describe(m, () => {
      test.each(TEXT)('text %s on %s (%s) is at least 4.5:1', (fg, bg) => {
        expect(contrast(colour(m, fg), colour(m, bg))).toBeGreaterThanOrEqual(4.5);
      });
      test.each(GRAPHICS)('graphic %s on %s (%s) is at least 3:1', (fg, bg) => {
        expect(contrast(colour(m, fg), colour(m, bg))).toBeGreaterThanOrEqual(3);
      });
      test('a cell holding 1 against a cell holding 0 (the text colour at 8%, as the Seal and the bit editors draw it) is at least 3:1', () => {
        for (const bg of ['--bg', '--bg-2']) {
          const ground = colour(m, bg);
          expect(contrast(colour(m, '--fg'), over(colour(m, '--fg'), 0.08, ground))).toBeGreaterThanOrEqual(3);
        }
      });
    });
  }

  test('the measured ratios in docs/brand/README.md still hold', () => {
    const r = (a: string, b: string): number => Math.round(contrast(a, b) * 100) / 100;
    expect(r('#e8e4da', '#0b0d10')).toBe(15.33);
    expect(r('#17150f', '#ece7db')).toBe(14.79);
    expect(r('#7d5710', '#ece7db')).toBe(5.25);
    expect(r('#17150f', '#e6b450')).toBe(9.57);
    // gold on deed is a fill only, never text or a needed edge
    expect(r('#e6b450', '#ece7db')).toBe(1.55);
  });
});

describe('the die on silicon (src/components/Die.tsx)', () => {
  // Outside a browser the theme falls back to the values it copies from tokens.css: they must be the same.
  const t = siliconDieTheme();
  test('its fallback palette is the one in tokens.css', () => {
    expect(t.bg).toBe(colour('silicon', '--wafer'));
    expect(t.core).toBe(colour('silicon', '--wafer-2'));
    expect(t.on).toBe(colour('silicon', '--bond'));
    expect(t.latchOn).toBe(colour('silicon', '--quartz'));
    expect(t.padOn).toBe(colour('silicon', '--route-res-si'));
    expect(t.select).toBe(colour('silicon', '--route-allow-si'));
  });
  test('lit logic, lit latches and lit pads read at 3:1 or more on the die', () => {
    for (const lit of [t.on, t.latchOn, t.padOn]) {
      expect(contrast(lit, t.core)).toBeGreaterThanOrEqual(3);
      expect(contrast(lit, t.bg)).toBeGreaterThanOrEqual(3);
    }
  });
});
