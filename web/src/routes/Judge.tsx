// #/judge
// PLACEHOLDER PAGE: the final text is not written yet; the kernel-specific checks arrive
// once the kernel pages exist. Edit the CHECKS array to change the page.

import { Command } from '../components/common.tsx';
import { ADDR, EXAMPLES } from '../config.ts';

interface Check {
  title: string;
  /** What the judge does and sees. */
  body: string;
  /** Whether the site can already run it. */
  ready: boolean;
}

const CHECKS: Check[] = [
  { title: 'Processor registered', body: 'isCPU(processor) on the TapeOut factory returns true. Every processor and circuit page here shows the answer.', ready: true },
  { title: 'Chip facts', body: 'circuitInfo(id) gives pins, state bits and gate count. The circuit page shows them next to what this site decodes from the netlist bytes.', ready: true },
  { title: 'Vault recipient', body: 'vaultOf(token), then RECIPIENT() on the vault, equals the kernel. Placeholder: needs the kernel.', ready: false },
  { title: 'Latest record', body: 'The kernel stores each settle as a record readable by eth_call. Placeholder: needs the kernel.', ready: false },
  { title: 'Replay', body: 'step(id, state, inputs) with a record\'s state and inputs returns the recorded outputs. The general form already runs: open any circuit and press Clock.', ready: true },
  { title: 'Counterfactual totals', body: 'What a fixed split would have done with the same inflow. Placeholder: needs the kernel.', ready: false },
  { title: 'Implementation pin', body: 'implementation() on TapeOut\'s beacon equals the value pinned at kernel creation. Placeholder: needs the kernel.', ready: false },
  { title: 'Hostile chip', body: 'A chip that demands everything, shown clipped by the kernel\'s limits. Placeholder: needs the kernel.', ready: false },
];

export function Judge() {
  const rpcUrl = ADDR.rpc[0];
  // Covenant's own probe circuit once it exists; until then a public circuit.
  const sample =
    ADDR.processor && ADDR.probeCircuitId !== null
      ? { processor: ADDR.processor, id: ADDR.probeCircuitId, label: `Covenant circuit ${ADDR.probeCircuitId}` }
      : EXAMPLES[0];
  return (
    <article>
      <p class="crumbs">
        <a href="#/">Covenant</a> / judge guide
      </p>
      <h1>Judge guide</h1>
      <p class="plate warn">
        <strong>Placeholder.</strong> Final text to come. Checks marked "runs today" work now; the others need Covenant's kernel, which
        is not connected to this page yet.
      </p>

      <section>
        <h2>The checks</h2>
        <ol class="checks">
          {CHECKS.map((c) => (
            <li key={c.title}>
              <strong>{c.title}</strong> <span class={`tag ${c.ready ? 'ok' : 'wait'}`}>{c.ready ? 'runs today' : 'placeholder'}</span>
              <div>{c.body}</div>
            </li>
          ))}
        </ol>
      </section>

      <section>
        <h2>The check that needs no trust in this site</h2>
        <p>
          Open <a href={`#/c/${sample.processor}/${sample.id}`}>{sample.label}</a>, set any inputs and press Clock. The page computes
          the beat from the netlist bytes and shows MATCH only if the chain returns the same outputs and the same new state. The page
          prints the exact command it corresponds to, so the same question can be put to any node from a terminal:
        </p>
        <Command line={`cast call ${sample.processor} "step(uint256,bytes,bytes)(bytes,bytes)" ${sample.id} 0x 0x --rpc-url ${rpcUrl}`} />
        <Command label="Number of processors the factory has created:" line={`cast call ${ADDR.factory} "cpuCount()(uint256)" --rpc-url ${rpcUrl}`} />
        {ADDR.processor && (
          <Command label="Covenant's processor is registered:" line={`cast call ${ADDR.factory} "isCPU(address)(bool)" ${ADDR.processor} --rpc-url ${rpcUrl}`} />
        )}
      </section>
    </article>
  );
}
