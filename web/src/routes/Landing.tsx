// #/
// The one sentence, the demonstration that the chip decides, what is live today, and where to check it.

import { useState } from 'preact/hooks';
import { readAll } from '@covenant/chain';
import { erc20, kernel } from '@covenant/chain/kernel';
import { Address } from '../components/common.tsx';
import { Mark, SimBanner } from '../components/kit.tsx';
import { TwoStates } from '../components/TwoStates.tsx';
import { CHAIN, COVENANT, EXAMPLES, rpc, SIMULATION } from '../config.ts';
import { parseTarget, targetHash } from '../format.ts';
import { useAsync } from '../router.ts';

const ZERO = '0x0000000000000000000000000000000000000000';

/** Bound token and settle count of the flagship kernel, if there is one. */
async function kernelStatus(): Promise<{ token: string | null; symbol: string | null; count: number | null } | null> {
  if (!COVENANT.kernel) return null;
  const k = kernel(COVENANT.kernel);
  const [token, count] = await readAll(rpc, [k.token(), k.count()] as const);
  const t = token instanceof Error || token.toLowerCase() === ZERO ? null : token;
  let symbol: string | null = null;
  if (t) {
    const [s] = await readAll(rpc, [erc20(t).symbol()] as const);
    symbol = s instanceof Error ? null : s;
  }
  return { token: t, symbol, count: count instanceof Error ? null : count };
}

export function Landing() {
  const status = useAsync(kernelStatus, []);
  const ks = status.data;
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
      note: '1,888 NAND + 64 latches',
    },
    { label: 'Its kernel', addr: COVENANT.kernel, href: COVENANT.kernel ? `#/k/${COVENANT.kernel}` : undefined, note: 'holds the chip; no owner' },
  ];
  // Kernel v2 (USD₮0 quote): listed once deployments/xlayer.json records it, not before.
  if (COVENANT.kernelFactoryV2) rows.push({ label: 'KernelFactoryV2 and LensV2', addr: COVENANT.kernelFactoryV2, note: 'kernels for tokens quoted in USD₮0; the same chip through a fixed code shift' });
  if (COVENANT.kernelV2) rows.push({ label: `Kernel v2 (USD₮0 quote)${COVENANT.chipIdV2 !== null ? `, chip #${COVENANT.chipIdV2}` : ''}`, addr: COVENANT.kernelV2, href: `#/k/${COVENANT.kernelV2}`, note: 'routes tax and revenue paid to it, as tax' });

  return (
    <article class="landing">
      <SimBanner />
      <header class="hero">
        <h1 class="pitch">A token's trading tax, routed by a chip anyone can read and nobody can change.</h1>
        <p class="lede">
          An IGNIX token's tax goes to a Covenant <b>kernel</b> instead of a wallet. Once per epoch anyone may call{' '}
          <span class="mono">settle()</span>: the kernel asks one TapeOut circuit, the <b>chip</b>, how to split it, and carries out that
          split inside an <b>envelope</b> of limits fixed when the kernel was created.
        </p>
        <div class="flow" aria-label="tax flows to the kernel, which asks the chip, then routes to buy and lock, allowance or reserve">
          <span class="node">trading tax</span>
          <span class="arrow">→</span>
          <span class="node strong">kernel</span>
          <span class="arrow">⇄</span>
          <span class="node chip">chip · 1,952 gates</span>
          <span class="arrow">→</span>
          <span class="dests">
            <span class="node buy">buy &amp; lock</span>
            <span class="node allow">allowance, capped</span>
            <span class="node res">reserve, released later</span>
          </span>
        </div>
      </header>

      <TwoStates />

      <section>
        <h2>{SIMULATION ? 'On the local fork' : `On ${CHAIN.name} today`}</h2>
        <ul class="live">
          {rows.map((r) => (
            <li key={r.label}>
              <Mark ok={r.addr ? true : null} />
              <span>
                {r.href ? <a href={r.href}>{r.label}</a> : r.label}
                {r.addr ? (
                  <>
                    {' '}
                    <Address value={r.addr} />
                  </>
                ) : (
                  <span class="tag wait">not deployed yet</span>
                )}
                <span class="muted"> {r.note}</span>
              </span>
            </li>
          ))}
          <li>
            <Mark ok={ks?.token ? true : null} />
            <span>
              Reference token bound to the kernel{' '}
              {ks?.token ? (
                <>
                  <Address value={ks.token} /> {ks.symbol && <span class="mono">{ks.symbol}</span>}{' '}
                  <a href={`#/k/${COVENANT.kernel}`}>
                    vault page, {ks.count ?? '?'} settle{ks.count === 1 ? '' : 's'}
                  </a>
                </>
              ) : (
                <span class="tag wait">{status.loading && COVENANT.kernel ? 'reading…' : 'not launched yet'}</span>
              )}
            </span>
          </li>
        </ul>
        <p class="muted">
          Every address comes from <span class="mono">deployments/xlayer.json</span>, which the deploy scripts write only after reading
          each contract back from the chain. Adoption is zero today: the only tokens planned for a Covenant kernel are the two the team launches itself (first buy 0,
          never traded by a team wallet); none is bound yet. Unaudited.
        </p>
      </section>

      <section>
        <h2>Check it yourself</h2>
        <div class="tiles">
          <a class="tile" href="#/judge">
            <b>Judge guide</b>
            <span>Eight checks, each runnable here and from a terminal.</span>
          </a>
          {COVENANT.kernel ? (
            <a class="tile" href={`#/k/${COVENANT.kernel}`}>
              <b>The vault</b>
              <span>Envelope, chip state on the die, settle history, chip vs a fixed split.</span>
            </a>
          ) : (
            <span class="tile off">
              <b>The vault</b>
              <span>Opens when the flagship kernel is deployed.</span>
            </span>
          )}
          <a class="tile" href="#/hostile">
            <b>A hostile chip</b>
            <span>A chip that asks for everything, and what the envelope lets through.</span>
          </a>
          <a class="tile" href="#/trust">
            <b>Trust model</b>
            <span>Who can change what, read from the code.</span>
          </a>
        </div>
      </section>

      <OpenBox />
    </article>
  );
}

function OpenBox() {
  const [text, setText] = useState('');
  const [bad, setBad] = useState(false);
  const open = (e: Event): void => {
    e.preventDefault();
    const t = parseTarget(text);
    if (!t) return setBad(true);
    location.hash = targetHash(t);
  };
  return (
    <section>
      <h2>Read any TapeOut circuit</h2>
      <p class="muted">
        The site's circuit reader works on every processor on {CHAIN.name}: it draws the die from the netlist bytes, runs a beat in your
        browser and compares it with the chain's own evaluator.
      </p>
      <form class="open" onSubmit={open}>
        <label for="target">Processor address, optionally followed by a circuit id</label>
        <div class="row">
          <input
            id="target"
            class={`mono${bad ? ' bad' : ''}`}
            placeholder="0x… 1"
            value={text}
            spellcheck={false}
            autocomplete="off"
            autocapitalize="off"
            aria-invalid={bad}
            onInput={(e) => {
              setText((e.target as HTMLInputElement).value);
              setBad(false);
            }}
          />
          <button type="submit" class="primary">
            Open
          </button>
        </div>
        {bad && <div class="warn">That does not contain an address (0x followed by 40 hex digits).</div>}
      </form>
      <p class="muted small">
        Circuits other people taped out:{' '}
        {EXAMPLES.map((x, i) => (
          <span key={`${x.processor}/${x.id}`}>
            {i > 0 && ' · '}
            <a href={`#/c/${x.processor}/${x.id}`}>{x.label}</a>
          </span>
        ))}
      </p>
    </section>
  );
}
