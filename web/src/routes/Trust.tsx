// #/trust
// PLACEHOLDER PAGE: the final text is not written yet. The three statements quoted first are the
// ones chips/INTERFACE.md (section 13) says the code must not contradict.

import { ADDR } from '../config.ts';

const SECTIONS: { title: string; body: string }[] = [
  { title: 'TapeOut', body: 'The processor factory is not sealed, so its owners can upgrade the logic that stores and evaluates circuits. Final text to come.' },
  { title: 'IGNIX', body: 'The launchpad contracts the tax flows through. Final text to come.' },
  { title: 'The keeper', body: 'Calls settle() each epoch. Liveness only: anyone else can call it too. Final text to come.' },
  { title: 'How this site reaches you', body: 'Static files, later also stored on chain and served through a gateway. Final text to come.' },
  { title: 'Our services', body: 'None is on the settlement path. Final text to come.' },
];

export function Trust() {
  const hosts = ADDR.rpc.map((u) => new URL(u).host);
  return (
    <article>
      <p class="crumbs">
        <a href="#/">Covenant</a> / trust model
      </p>
      <h1>Trust model</h1>
      <p class="plate warn">
        <strong>Placeholder.</strong> Final text to come. The statements below are the ones already fixed in the project's interface
        document.
      </p>

      <section>
        <h2>Fixed statements</h2>
        <ul>
          <li>Nothing on the tax path has an owner, an upgrade path or a pause.</li>
          <li>
            TapeOut's factory is unsealed (a 3-of-5 Safe can upgrade processor logic). IgnixManager is upgradeable by its owner. The
            keeper is liveness only.
          </li>
          <li>Unaudited.</li>
        </ul>
      </section>

      <section>
        <h2>What this page itself asks you to trust</h2>
        <ul>
          <li>
            It is static files with no wallet, no cookies and no analytics. It sends read calls to {hosts.join(' and ')} and nothing
            else.
          </li>
          <li>
            A MATCH plate compares your browser's result with the answer of one node operator. Both endpoints above are run by OKX. A
            node that lied could fake a MATCH, which is why every check prints a command you can run against a node you choose.
          </li>
          <li>
            The beat is computed by this site's own implementation of TAP-20, TapeOut's published netlist standard. It was written
            from that text and passes the standard's test vectors. It is not the code the chain runs, which is the point of comparing
            the two.
          </li>
        </ul>
      </section>

      {SECTIONS.map((s) => (
        <section key={s.title}>
          <h2>{s.title}</h2>
          <p>{s.body}</p>
        </section>
      ))}
    </article>
  );
}
