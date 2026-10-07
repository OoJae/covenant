// A heading whose lines rise from masks the first time it scrolls into view (its top crosses 85% of the viewport),
// then turns back into plain text.
//
// The text Preact renders stays in place the whole time (transparent while the lines run, so the layout never
// moves and screen readers read it as usual). Once the fonts have loaded, the line breaks are measured with Ranges
// on that text, and a copy of each line is drawn over it in an overflow-hidden mask, its inline wrappers (em,
// strong, a) cloned along. Each copy rises from translateY(100%) with the reveal ease, 70 ms apart. When the last
// one lands the copies are removed and the real text is shown again. Under prefers-reduced-motion, or without
// IntersectionObserver or the Web Animations API, the text is simply there.

import type { ComponentChildren } from 'preact';
import { useEffect, useRef, useState } from 'preact/hooks';
import { DUR, EASE_REVEAL, motionAllowed } from '../motion/prefs.ts';

type Tag = 'h1' | 'h2' | 'h3' | 'h4' | 'p' | 'div';

export interface RevealLinesProps {
  as?: Tag;
  children: ComponentChildren;
  class?: string;
  id?: string;
  /** Wait this long after entering the view before the first line moves, in ms. */
  delay?: number;
  /** Between one line and the next, in ms (default 70). */
  stagger?: number;
  /** Called once the text is plain again (immediately when there is nothing to animate). */
  onDone?: () => void;
}

const canAnimate = (): boolean =>
  motionAllowed() && typeof IntersectionObserver === 'function' && typeof Element !== 'undefined' && typeof Element.prototype.animate === 'function';

export function RevealLines({ as: T = 'h2', children, class: cls, id, delay = 0, stagger = 70, onDone }: RevealLinesProps) {
  const host = useRef<HTMLElement>(null);
  const src = useRef<HTMLSpanElement>(null);
  const layer = useRef<HTMLSpanElement>(null);
  // Decided once: a heading that starts plain stays plain.
  const [waiting, setWaiting] = useState(canAnimate);

  useEffect(() => {
    if (!waiting) {
      onDone?.();
      return;
    }
    const el = host.current!;
    let live = true;
    let anims: Animation[] = [];
    const finish = (): void => {
      if (!live) return;
      live = false;
      layer.current?.replaceChildren();
      if (el.style.position === 'relative' && el.dataset.rlPos === '1') {
        el.style.position = '';
        delete el.dataset.rlPos;
      }
      setWaiting(false);
      onDone?.();
    };
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries.some((e) => e.isIntersecting)) return;
        io.disconnect();
        void (document.fonts?.ready ?? Promise.resolve()).then(() => {
          if (!live || !src.current || !layer.current) return;
          if (getComputedStyle(el).position === 'static') {
            el.style.position = 'relative';
            el.dataset.rlPos = '1';
          }
          const inners = drawLines(src.current, layer.current);
          if (inners.length === 0) return finish();
          anims = inners.map((inner, i) =>
            inner.animate([{ transform: 'translateY(100%)' }, { transform: 'translateY(0)' }], {
              duration: DUR.reveal,
              delay: delay + i * stagger,
              easing: EASE_REVEAL,
              fill: 'backwards',
            }),
          );
          void Promise.all(anims.map((a) => a.finished)).then(finish, finish);
        });
      },
      { rootMargin: '0px 0px -15% 0px', threshold: 0 },
    );
    io.observe(el);
    return () => {
      io.disconnect();
      for (const a of anims) a.cancel();
      live = false;
    };
  }, []);

  return (
    <T ref={host as never} class={cls} id={id}>
      <span ref={src} style={waiting ? { opacity: 0 } : undefined}>
        {children}
      </span>
      <span ref={layer} aria-hidden="true" style={waiting ? LAYER : HIDDEN} />
    </T>
  );
}

const LAYER = { position: 'absolute', inset: 0, pointerEvents: 'none' } as const;
const HIDDEN = { display: 'none' } as const;

interface Word {
  /** The text to copy: the word with the spaces around it. */
  text: string;
  /** Inline elements between the measured text and the word, outermost first. */
  chain: Element[];
  rect: DOMRect;
}

/** Measures the lines of `text` and draws a masked copy of each into `layer`; returns the elements to move. */
function drawLines(text: HTMLElement, layer: HTMLElement): HTMLElement[] {
  const words: Word[] = [];
  const range = document.createRange();
  const walk = document.createTreeWalker(text, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode() as Text | null; n; n = walk.nextNode() as Text | null) {
    const chain: Element[] = [];
    for (let p = n.parentElement; p && p !== text; p = p.parentElement) chain.unshift(p);
    for (const m of n.data.matchAll(/\s*(\S+)\s*/g)) {
      const start = m.index + m[0].indexOf(m[1]);
      range.setStart(n, start);
      range.setEnd(n, start + m[1].length);
      const rect = range.getClientRects()[0] ?? range.getBoundingClientRect();
      words.push({ text: m[0], chain, rect });
    }
  }
  if (words.length === 0) return [];

  // Group into lines by vertical position.
  const lines: Word[][] = [];
  for (const w of words) {
    const last = lines[lines.length - 1];
    if (last && Math.abs(w.rect.top - last[0].rect.top) < w.rect.height / 2) last.push(w);
    else lines.push([w]);
  }

  const origin = layer.getBoundingClientRect();
  const inners: HTMLElement[] = [];
  (layer as HTMLElement & { inert: boolean }).inert = true;
  for (const line of lines) {
    const top = Math.min(...line.map((w) => w.rect.top));
    const bottom = Math.max(...line.map((w) => w.rect.bottom));
    const left = Math.min(...line.map((w) => w.rect.left));
    const mask = document.createElement('span');
    // The copy's line box is the font's content area, so its glyphs sit exactly where the real ones do. The mask is
    // that plus .15em below for descenders that reach past the content area, and the copy carries the same padding,
    // so translateY(100%) starts every glyph below the mask. The sideways padding keeps italic overhangs whole.
    mask.style.cssText = `position:absolute;display:block;overflow:hidden;white-space:nowrap;top:${top - origin.top}px;left:calc(${left - origin.left}px - .25em);padding:0 .25em`;
    const inner = document.createElement('span');
    inner.style.cssText = `display:block;line-height:${bottom - top}px;padding-bottom:.15em;will-change:transform`;
    mask.append(inner);
    // Rebuild the inline wrappers word by word, sharing a clone while consecutive words share the original.
    let open: { orig: Element; copy: Element }[] = [];
    line.forEach((w, k) => {
      let same = 0;
      while (same < open.length && same < w.chain.length && open[same].orig === w.chain[same]) same++;
      open = open.slice(0, same);
      for (const orig of w.chain.slice(same)) {
        const copy = orig.cloneNode(false) as Element;
        copy.removeAttribute('id');
        (open.length > 0 ? open[open.length - 1].copy : inner).append(copy);
        open.push({ orig, copy });
      }
      const t = k === 0 ? w.text.trimStart() : k === line.length - 1 ? w.text.trimEnd() : w.text;
      (open.length > 0 ? open[open.length - 1].copy : inner).append(t);
    });
    layer.append(mask);
    inners.push(inner);
  }
  return inners;
}
