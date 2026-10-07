// Small display pieces shared by the kernel pages: route bars, check marks, stat instruments, the simulation
// banner and clause heads. Styles: src/styles/components.css.

import type { ComponentChildren } from 'preact';
import { pct256, type RouteView } from '../kernel/chip.ts';

// The simulation banner lives in its own module so the landing can show it without bringing kit (and kernel/chip.ts)
// into the entry script; kit re-exports it for the other pages.
export { SimBanner } from './SimBanner.tsx';

/** How one settle's tax is split, as a bar of 256ths, plus the release from the reserve. */
export function RouteBar({ view, compact }: { view: RouteView; compact?: boolean }) {
  if (!view.wellFormed) {
    return (
      <div class="routebar bad-shape">
        <div class="bar">
          <span class="seg res" style={{ flex: 1 }} />
        </div>
        <p class="muted small">
          Malformed shares (buy {view.buy}, hold {view.hold}, allowance {view.allow}, reserve {view.res}; they must sum to 256). The
          kernel treats this as 100% reserve.
        </p>
      </div>
    );
  }
  const segs = [
    { k: 'buy', v: view.buy, label: 'buy & lock' },
    { k: 'allow', v: view.allow, label: 'allowance' },
    { k: 'res', v: view.res + view.hold, label: 'reserve' },
  ];
  return (
    <div class={`routebar${compact ? ' compact' : ''}`}>
      <div class="bar" role="img" aria-label={segs.map((s) => `${s.label} ${pct256(s.v)}`).join(', ')}>
        {segs.map((s) => (s.v > 0 ? <span key={s.k} class={`seg ${s.k}`} style={{ flex: s.v }} title={`${s.label}: ${s.v}/256`} /> : null))}
      </div>
      <ul class="keys">
        {segs.map((s) => (
          <li key={s.k} class={s.v === 0 ? 'zero' : ''}>
            <i class={`dot ${s.k}`} />
            {s.label} <b>{pct256(s.v)}</b>
          </li>
        ))}
        <li class={view.rel === 0 ? 'zero' : ''}>
          <i class="dot rel" />
          release <b>{pct256(view.rel)}</b> of the reserve
        </li>
      </ul>
    </div>
  );
}

/** A check mark in a square cell: true, false, or null for "could not be checked". */
export function Mark({ ok }: { ok: boolean | null | undefined }) {
  if (ok === true)
    return (
      <span class="mark ok" role="img" aria-label="yes">
        ✓
      </span>
    );
  if (ok === false)
    return (
      <span class="mark bad" role="img" aria-label="no">
        ✗
      </span>
    );
  return (
    <span class="mark wait" role="img" aria-label="not checked">
      ?
    </span>
  );
}

/** One line of a checklist: a ledger row. */
export function CheckRow({ ok, children, note }: { ok: boolean | null | undefined; children: ComponentChildren; note?: ComponentChildren }) {
  return (
    <li class="checkrow">
      <Mark ok={ok} />
      <div>
        <div class="checkrow__claim">{children}</div>
        {note && <div class="checkrow__note">{note}</div>}
      </div>
    </li>
  );
}

/** One instrument of a stat band: a label, a reading, a line of context. */
export function Stat({ label, value, sub }: { label: string; value: ComponentChildren; sub?: ComponentChildren }) {
  return (
    <div class="stat">
      <div class="label">{label}</div>
      <div class="value">{value}</div>
      {sub && <div class="sub">{sub}</div>}
    </div>
  );
}

/** Shown on every page when the site reads the local fork fixture instead of X Layer: a warn plate. */
/**
 * A clause head: the section number hangs in the gutter (§01), the title is set in the display face. Put it first
 * in a `<section class="clause">`; both parts are grid items of the clause.
 */
export function Pin({ id, children }: { id: string; children: ComponentChildren }) {
  return (
    <>
      <span class="clause__no" aria-hidden="true">
        §{id}
      </span>
      <h2 class="clause__title">{children}</h2>
    </>
  );
}
