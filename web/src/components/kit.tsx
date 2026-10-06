// Small display pieces shared by the kernel pages: route bars, check marks, stat tiles, the simulation banner.

import type { ComponentChildren } from 'preact';
import { SIMULATION } from '../config.ts';
import { pct256, type RouteView } from '../kernel/chip.ts';

/** How one settle's tax is split, as a bar of 256ths, plus the release from the reserve. */
export function RouteBar({ view, compact }: { view: RouteView; compact?: boolean }) {
  if (!view.wellFormed) {
    return (
      <div class="routebar bad-shape">
        <div class="bar">
          <span class="seg res" style={{ flex: 1 }} />
        </div>
        <p class="muted">
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

/** A check mark: true, false, or null for "could not be checked". */
export function Mark({ ok }: { ok: boolean | null | undefined }) {
  if (ok === true) return <span class="mark ok" aria-label="yes">✓</span>;
  if (ok === false) return <span class="mark bad" aria-label="no">✗</span>;
  return (
    <span class="mark wait" aria-label="not checked">
      ?
    </span>
  );
}

/** One line of a checklist. */
export function CheckRow({ ok, children, note }: { ok: boolean | null | undefined; children: ComponentChildren; note?: ComponentChildren }) {
  return (
    <li class="checkrow">
      <Mark ok={ok} />
      <div>
        {children}
        {note && <div class="muted">{note}</div>}
      </div>
    </li>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ComponentChildren; sub?: ComponentChildren }) {
  return (
    <div class="stat">
      <div class="label">{label}</div>
      <div class="value">{value}</div>
      {sub && <div class="sub">{sub}</div>}
    </div>
  );
}

/** Shown on every page when the site reads the local fork fixture instead of X Layer. */
export function SimBanner() {
  if (!SIMULATION) return null;
  return (
    <div class="simbanner" role="note">
      <strong>SIMULATION</strong> This build reads a local anvil fork of X Layer (block {SIMULATION.block}) made by{' '}
      <span class="mono">web/scripts/fork-fixture.sh</span>. Nothing shown here happened on X Layer.
    </div>
  );
}

/** A section heading with a small silicon-style label. */
export function Pin({ id, children }: { id: string; children: ComponentChildren }) {
  return (
    <h2 class="pin">
      <span class="pinid">{id}</span>
      {children}
    </h2>
  );
}
