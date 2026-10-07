// The landing page's clauses §02 to §05 (#/), loaded on demand by Landing.tsx once the hero is up: what no chip can
// do, what is live on X Layer, where to check it, and the circuit reader. Their styles come with them
// (styles/landing-paper.ts). Every address comes from deployments/xlayer.json and every token and count from the
// chain; none is typed in.

import { Fragment, type ComponentChildren } from 'preact';
import { useRef, useState } from 'preact/hooks';
import { Address } from '../components/common.tsx';
import { Mark, Pin } from '../components/kit.tsx';
import { RevealLines } from '../components/RevealLines.tsx';
import { CHAIN, COVENANT, EXAMPLES, SIMULATION } from '../config.ts';
import { fmtInt, parseTarget, targetHash } from '../format.ts';
import { FG_SIZE } from '../kernel/demo.ts';
import { motionAllowed } from '../motion/prefs.ts';
import { useReveal } from '../motion/reveal.ts';
import type { Async } from '../router.ts';
import { paperStyles } from '../styles/landing-paper.ts';
import { flagships, settles, WireIcon, type Bound } from './Landing.tsx';

paperStyles();

/** §02 to §05. */
export function Clauses({ bound }: { bound: Async<Bound[]> }) {
  return (
    <>
      <NoChip />
      <LiveRegister q={bound} />
      <CheckTiles bound={bound.data} />
      <OpenBox />
    </>
  );
}

// ------------------------------------------------------------------------------------------------- paper: §02

function NoChip() {
  const body = useReveal<HTMLDivElement>();
  return (
    <section class="l-sec nochip" aria-labelledby="s02-t">
      <div class="l-wrap">
        <Pin id="02">
          <RevealLines as="span" id="s02-t">
            What no chip <em>can do.</em>
          </RevealLines>
        </Pin>
        <div class="l-body reveal" ref={body}>
          <p class="l-lede" data-stagger style={{ '--i': 0 }}>
            A chip is a pure function of a few hundred bits. Whatever it answers, the kernel decides what that answer may move.
          </p>
          <ul class="deeds">
            <li data-stagger style={{ '--i': 1 }}>
              <h3>It cannot reach outside itself.</h3>
              <p>A chip cannot call another contract, write storage or use more gas than its gate count allows.</p>
            </li>
            <li data-stagger style={{ '--i': 2 }}>
              <h3>It cannot take more than the envelope allows.</h3>
              <p>
                Each route is clipped to bounds fixed when the kernel was created. The kernel limits how much a chip can take and how long it can
                hold funds.
              </p>
            </li>
            <li data-stagger style={{ '--i': 3 }}>
              <h3>It cannot stop a settle.</h3>
              <p>
                No output can make <span class="mono">settle()</span> revert. Shares that do not add up are treated as 100% reserve.
              </p>
            </li>
          </ul>
          <p data-stagger style={{ '--i': 4 }}>
            <a class="btn btn--secondary" href="#/hostile">
              Watch a hostile chip try <WireIcon dir="right" />
            </a>
          </p>
        </div>
      </div>
    </section>
  );
}

// ------------------------------------------------------------------------------------------------- paper: §03

function LiveRegister({ q }: { q: Async<Bound[]> }) {
  const body = useReveal<HTMLDivElement>();
  const P = COVENANT.processor;
  const rows: { label: string; addr: string | null; href?: string; note?: string }[] = [
    { label: 'Processor Covenant (CVNT)', addr: P, href: P ? `#/p/${P}` : undefined, note: 'TapeOut processor: transistors and circuits' },
    { label: `Probe circuit #${COVENANT.probeCircuitId ?? '?'}`, addr: COVENANT.probeCircuitId !== null ? P : null, href: P && COVENANT.probeCircuitId !== null ? `#/c/${P}/${COVENANT.probeCircuitId}` : undefined, note: 'a 118-gate test chip' },
    { label: 'SealedVM and Fab', addr: COVENANT.fab, note: 'fallback evaluator; chip tape-out and netlist snapshots' },
    { label: 'KernelFactory and Lens', addr: COVENANT.kernelFactory, note: 'creates kernels; free audit views' },
    {
      label: `Flow Governor chip${COVENANT.chipId !== null ? ` #${COVENANT.chipId}` : ''}`,
      addr: COVENANT.chipId !== null ? P : null,
      href: P && COVENANT.chipId !== null ? `#/c/${P}/${COVENANT.chipId}` : undefined,
      note: `${fmtInt(FG_SIZE.nand)} NAND + ${FG_SIZE.latch} latches`,
    },
    { label: 'Its kernel', addr: COVENANT.kernel, href: COVENANT.kernel ? `#/k/${COVENANT.kernel}` : undefined, note: 'holds the chip; no owner' },
  ];
  // Kernel v2 (USD₮0 quote): listed once deployments/xlayer.json records it, not before.
  if (COVENANT.kernelFactoryV2) rows.push({ label: 'KernelFactoryV2 and LensV2', addr: COVENANT.kernelFactoryV2, note: 'kernels for tokens quoted in USD₮0; the same chip through a fixed code shift' });
  if (COVENANT.kernelV2) rows.push({ label: `Kernel v2 (USD₮0 quote)${COVENANT.chipIdV2 !== null ? `, chip #${COVENANT.chipIdV2}` : ''}`, addr: COVENANT.kernelV2, href: `#/k/${COVENANT.kernelV2}`, note: 'routes tax and revenue paid to it, as tax' });
  const tokens = q.data ?? [];
  const versions = flagships().map((k) => k.version);
  const syms = tokens.filter((b) => b.symbol).map((b) => b.symbol!);

  return (
    <section class="l-sec register-sec" aria-labelledby="s03-t">
      <div class="l-wrap">
        <Pin id="03">
          <RevealLines as="span" id="s03-t">
            {SIMULATION ? 'On the local fork' : <>On {CHAIN.name} <em>today.</em></>}
          </RevealLines>
        </Pin>
        <div class="l-body reveal" ref={body}>
          <ul class="register live-reg">
            {rows.map((r, i) => (
              <li key={r.label} data-stagger style={{ '--i': i }}>
                <Mark ok={r.addr ? true : null} />
                <span class="live-reg__what">{r.href ? <a href={r.href}>{r.label}</a> : r.label}</span>
                <span class="live-reg__addr">{r.addr ? <Address value={r.addr} /> : <span class="tag wait">not deployed yet</span>}</span>
                <span class="live-reg__note">{r.note}</span>
              </li>
            ))}
            {versions.map((v, i) => {
              const b = tokens.find((t) => t.version === v);
              return (
                <li key={`tok${v}`} data-stagger style={{ '--i': rows.length + i }}>
                  <Mark ok={b?.token ? true : null} />
                  <span class="live-reg__what">
                    Token bound to kernel v{v} {b?.symbol && <span class="mono">{b.symbol}</span>}
                  </span>
                  <span class="live-reg__addr">
                    {b?.token ? <Address value={b.token} /> : <span class="tag wait">{q.loading ? 'reading…' : q.error ? 'could not read' : 'not bound yet'}</span>}
                  </span>
                  <span class="live-reg__note">
                    {b?.token ? <a href={`#/k/${b.kernel}`}>vault page, {settles(b.count)}</a> : 'the vault page fills in once a token is bound'}
                  </span>
                </li>
              );
            })}
          </ul>
          <p class="register-sec__note" data-stagger style={{ '--i': rows.length + 2 }}>
            Every address comes from <span class="mono">deployments/xlayer.json</span>, which the deploy scripts write only after reading each contract
            back from the chain. Adoption by other projects is zero today: the{' '}
            {syms.length > 0
              ? syms.map((sym, i) => (
                  <Fragment key={sym}>
                    {i > 0 && ' and '}
                    <span class="mono">{sym}</span>
                  </Fragment>
                ))
              : 'bound'}{' '}
            token{syms.length === 1 ? ' is' : 's are'} the team's own, launched with first buy 0 and never traded by a team wallet. Unaudited.
          </p>
        </div>
      </div>
    </section>
  );
}

// ------------------------------------------------------------------------------------------------- paper: §04

function CheckTiles({ bound }: { bound: Bound[] | undefined }) {
  const body = useReveal<HTMLUListElement>();
  const sym = (v: 1 | 2): string | null => bound?.find((b) => b.version === v)?.symbol ?? null;
  const tiles: { href: string | null; kind: string; title: ComponentChildren; text: ComponentChildren }[] = [
    { href: '#/judge', kind: 'Start here', title: 'Judge guide', text: 'Eight checks, each runnable here and from a terminal.' },
    {
      href: COVENANT.kernel ? `#/k/${COVENANT.kernel}` : null,
      kind: `${sym(1) ?? 'Kernel v1'} · OKB quote`,
      title: 'Vault v1',
      text: COVENANT.kernel ? 'Envelope, chip state on the die, settle history, chip vs a fixed split.' : 'Opens when the flagship kernel is deployed.',
    },
  ];
  if (COVENANT.kernelV2) {
    tiles.push({
      href: `#/k/${COVENANT.kernelV2}`,
      kind: `${sym(2) ?? 'Kernel v2'} · USD₮0 quote`,
      title: 'Vault v2',
      text: 'The same chip on a token quoted in USD₮0. It routes tax, and revenue paid to the kernel, as tax.',
    });
  }
  tiles.push(
    { href: '#/hostile', kind: 'Glutton chip', title: 'A hostile chip', text: 'A chip that asks for everything, and what the envelope lets through.' },
    { href: '#/trust', kind: 'Owners and upgrades', title: 'Trust model', text: 'Who can change what, read from the code.' },
  );
  return (
    <section class="l-sec check-sec" aria-labelledby="s04-t">
      <div class="l-wrap">
        <Pin id="04">
          <RevealLines as="span" id="s04-t">
            Check it <em>yourself.</em>
          </RevealLines>
        </Pin>
        <ul class="l-body l-tiles reveal" ref={body}>
          {tiles.map((t, i) => (
            <li key={String(t.title)} data-stagger style={{ '--i': i }}>
              {t.href ? (
                <a class="l-tile" href={t.href}>
                  <span class="label">{t.kind}</span>
                  <b class="l-tile__title">{t.title}</b>
                  <span class="l-tile__text">{t.text}</span>
                  <WireIcon dir="right" />
                </a>
              ) : (
                <span class="l-tile is-off">
                  <span class="label">{t.kind}</span>
                  <b class="l-tile__title">{t.title}</b>
                  <span class="l-tile__text">{t.text}</span>
                </span>
              )}
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}

// ------------------------------------------------------------------------------------------------- paper: §05

function OpenBox() {
  const [text, setText] = useState('');
  const [bad, setBad] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const body = useReveal<HTMLDivElement>();
  const open = (e: Event): void => {
    e.preventDefault();
    const t = parseTarget(text);
    if (t) {
      location.hash = targetHash(t);
      return;
    }
    setBad(true);
    // Shake: three cycles over 300 ms, sideways only.
    if (motionAllowed() && input.current && typeof input.current.animate === 'function') {
      input.current.animate([0, -6, 6, -5, 5, -3, 3, 0].map((px) => ({ transform: `translateX(${px}px)` })), { duration: 300, easing: 'linear' });
    }
    input.current?.focus();
  };
  return (
    <section class="l-sec openbox" aria-labelledby="s05-t">
      <div class="l-wrap">
        <Pin id="05">
          <RevealLines as="span" id="s05-t">
            Read any <em>TapeOut circuit.</em>
          </RevealLines>
        </Pin>
        <div class="l-body reveal" ref={body}>
          <p class="l-lede" data-stagger style={{ '--i': 0 }}>
            The site's circuit reader works on every processor on {CHAIN.name}: it draws the die from the netlist bytes, runs a beat in your browser and
            compares it with the chain's own evaluator.
          </p>
          <form class="l-open" onSubmit={open} data-stagger style={{ '--i': 1 }} noValidate>
            <label for="target" class="label">
              Processor address, optionally followed by a circuit id
            </label>
            <div class="l-open__row">
              <input
                ref={input}
                id="target"
                class={`mono${bad ? ' bad' : ''}`}
                placeholder="0x… 1"
                value={text}
                spellcheck={false}
                autocomplete="off"
                autocapitalize="off"
                aria-invalid={bad}
                aria-describedby={bad ? 'target-err' : undefined}
                onInput={(e) => {
                  setText((e.target as HTMLInputElement).value);
                  setBad(false);
                }}
              />
              <button type="submit" class="btn btn--primary">
                Open <WireIcon dir="right" />
              </button>
            </div>
            {bad && (
              <p class="l-open__err" id="target-err" role="alert">
                That does not contain an address (0x followed by 40 hex digits).
              </p>
            )}
          </form>
          <p class="l-open__examples" data-stagger style={{ '--i': 2 }}>
            <span class="label">Circuits other people taped out</span>
            {EXAMPLES.map((x) => (
              <a key={`${x.processor}/${x.id}`} href={`#/c/${x.processor}/${x.id}`} title={x.note}>
                {x.label}
              </a>
            ))}
          </p>
        </div>
      </div>
    </section>
  );
}
