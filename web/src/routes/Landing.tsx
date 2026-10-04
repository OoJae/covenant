// #/
// The one sentence, a short honest explanation, and a box that opens any TapeOut processor or
// circuit on X Layer.

import { useState } from 'preact/hooks';
import { Address } from '../components/common.tsx';
import { ADDR, CHAIN, EXAMPLES } from '../config.ts';
import { parseTarget, targetHash } from '../format.ts';

export function Landing() {
  const [text, setText] = useState('');
  const [bad, setBad] = useState(false);
  const own = ADDR.processor;

  const open = (e: Event): void => {
    e.preventDefault();
    const t = parseTarget(text);
    if (!t) return setBad(true);
    location.hash = targetHash(t);
  };

  return (
    <article>
      <h1 class="pitch">Your token's tax, routed by a chip anyone can read and nobody can change.</h1>
      <p class="lede">
        Covenant is a prototype of vault mechanics for tokens launched on IGNIX, built on TapeOut circuits on {CHAIN.name}.
      </p>

      <section>
        <h2>The idea</h2>
        <ol class="steps">
          <li>A token's trading tax goes to a small contract, the kernel, instead of to a wallet.</li>
          <li>
            The kernel holds one TapeOut circuit, a vault chip: a list of NAND gates and latches stored on chain. Once per epoch anyone
            may call <span class="mono">settle()</span>. The kernel hands the chip its inputs and carries out the split the chip
            returns, inside limits fixed when the kernel was created.
          </li>
          <li>
            A chip is not a program. It cannot call another contract, write storage, or run longer than its gate count. Every step it
            takes can be replayed by anyone with a free read call and no wallet. That replay is what this site does.
          </li>
        </ol>
      </section>

      <section>
        <h2>Where this stands</h2>
        {own ? (
          <p>
            Covenant's processor is <Address value={own} full />.{' '}
            <a href={`#/p/${own}`}>Open the processor</a>
            {ADDR.probeCircuitId !== null && (
              <>
                {' '}or go straight to <a href={`#/c/${own}/${ADDR.probeCircuitId}`}>circuit {String(ADDR.probeCircuitId)}</a>
              </>
            )}
            . The pages for a token's vault and its settle history are still to come.
          </p>
        ) : (
          <p>
            Covenant's own processor and kernel are not connected to this page yet, so no token's tax is routed by a chip today. What
            works now is the part you can check without trusting us: read any TapeOut circuit from {CHAIN.name}, see it drawn from its
            bytes, run one beat in your browser, and compare the result with the chain's own evaluator.
          </p>
        )}
        <p class="muted">
          Unaudited. "Nobody can change" is about the stored netlist, which has no setter. It rests on TapeOut's contracts, which their
          owners can still upgrade; the <a href="#/trust">trust page</a> lists what you rely on.
        </p>
      </section>

      <section>
        <h2>Open a processor or a circuit</h2>
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
          <p class="muted">
            Examples of what works: <span class="mono">0x933F…Db5a</span> opens the processor; <span class="mono">0x933F…Db5a 1</span> or{' '}
            <span class="mono">0x933F…Db5a/1</span> opens its circuit 1. A pasted explorer link works too.
          </p>
        </form>

        {!own && (
          <>
            <h3>Live circuits to try</h3>
            <p class="muted">Taped out by other people on TapeOut ({CHAIN.name}). They are here to show the reader on real chain data.</p>
            <ul class="examples">
              {EXAMPLES.map((x) => (
                <li key={`${x.processor}/${x.id}`}>
                  <a href={`#/c/${x.processor}/${x.id}`}>{x.label}</a>
                  <span class="muted"> {x.note}. </span>
                  <a href={`#/p/${x.processor}`}>processor</a>
                </li>
              ))}
            </ul>
          </>
        )}
      </section>

      <section>
        <h2>For judges</h2>
        <p>
          The <a href="#/judge">judge guide</a> lists the checks and which of them already run. No wallet is needed for any page here.
        </p>
      </section>
    </article>
  );
}
