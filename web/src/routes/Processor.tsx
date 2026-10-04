// #/p/:processor
// A processor: its ERC-1155 transistor terms and the circuits taped out on it.

import { useEffect, useState } from 'preact/hooks';
import { Address } from '../components/common.tsx';
import { ADDR, CHAIN, rpc } from '../config.ts';
import { loadCircuits, loadProcessor, type CircuitRow, type ProcessorData } from '../data/processor.ts';
import { fmtInt, fmtUnits } from '../format.ts';
import { useAsync } from '../router.ts';
import { Failure, Loading } from './shared.tsx';

const PAGE = 100;

export function Processor({ address }: { address: string }) {
  const q = useAsync(() => loadProcessor(rpc, ADDR.factory, address), [address]);
  if (q.loading) return <Loading what={`processor ${address.slice(0, 10)}… from ${CHAIN.name}`} />;
  if (q.error || !q.data) return <Failure error={q.error} retry={q.reload} />;
  return <View key={q.data.address} p={q.data} />;
}

function View({ p }: { p: ProcessorData }) {
  const [rows, setRows] = useState<CircuitRow[]>([]);
  const [next, setNext] = useState(1); // first id not yet requested
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | undefined>();

  const more = (from: number): void => {
    if (from > p.circuits) return;
    const to = Math.min(p.circuits, from + PAGE - 1);
    setBusy(true);
    setError(undefined);
    loadCircuits(rpc, p.address, from, to).then(
      (got) => {
        setRows((have) => [...have, ...got]);
        setNext(to + 1);
        setBusy(false);
      },
      (e: unknown) => {
        setError(e instanceof Error ? e : new Error(String(e)));
        setBusy(false);
      },
    );
  };
  useEffect(() => more(1), []);

  const left = p.supplyCap !== null && p.minted !== null ? p.supplyCap - p.minted : null;
  return (
    <article>
      <p class="crumbs">
        <a href="#/">Covenant</a> / processor
      </p>
      <h1>
        {p.name || 'Unnamed processor'} <span class="muted">{p.symbol}</span>
      </h1>
      <p class="lede">
        A TapeOut processor on {CHAIN.name}: an ERC-721 contract that stores circuits, and an ERC-1155 contract whose transistors are
        burned, one per gate, to tape a circuit out.
      </p>

      <section>
        <h2>Terms</h2>
        <dl class="facts">
          <dt>Processor</dt>
          <dd>
            <Address value={p.address} full />{' '}
            {p.registered === true && <span class="tag ok">registered with the TapeOut factory</span>}
            {p.registered === false && <span class="tag bad">not registered with the TapeOut factory</span>}
          </dd>
          <dt>Transistors</dt>
          <dd>{p.transistors ? <Address value={p.transistors} full /> : 'unknown'}</dd>
          <dt>Creator</dt>
          <dd>{p.creator ? <Address value={p.creator} full /> : 'unknown'}</dd>
          <dt>Supply cap</dt>
          <dd>{p.supplyCap === null ? 'unknown' : `${fmtInt(p.supplyCap)} transistors`}</dd>
          <dt>Price</dt>
          <dd>{p.mintPrice === null ? 'unknown' : `${fmtUnits(p.mintPrice)} OKB per transistor`}</dd>
          <dt>Minted</dt>
          <dd>
            {p.minted === null ? 'unknown' : fmtInt(p.minted)}
            {left !== null && <span class="muted"> ({fmtInt(left)} left)</span>}
          </dd>
          <dt>Circuits</dt>
          <dd>{fmtInt(p.circuits)}</dd>
          {p.block !== null && (
            <>
              <dt>Read at block</dt>
              <dd>{fmtInt(p.block)}</dd>
            </>
          )}
        </dl>
        <h3>Story</h3>
        {p.story ? <blockquote class="story">{p.story}</blockquote> : <p class="muted">No story string.</p>}
        <p class="muted">
          The story is free text written by the creator at deployment. It is shown exactly as stored; nothing on chain checks it.
        </p>
      </section>

      <section>
        <h2>Circuits</h2>
        {p.circuits === 0 && <p>No circuit has been taped out on this processor.</p>}
        {rows.length > 0 && (
          <div class="scroll">
            <table>
              <thead>
                <tr>
                  <th>id</th>
                  <th class="num">gates</th>
                  <th class="num">in</th>
                  <th class="num">out</th>
                  <th class="num">state bits</th>
                  <th>owner</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.id}>
                    <td>
                      <a href={`#/c/${p.address}/${r.id}`}>#{r.id}</a>
                    </td>
                    <td class="num">{r.info ? fmtInt(r.info.gateCount) : '?'}</td>
                    <td class="num">{r.info ? fmtInt(r.info.nIn) : '?'}</td>
                    <td class="num">{r.info ? fmtInt(r.info.nOut) : '?'}</td>
                    <td class="num">{r.info ? fmtInt(r.info.nState) : '?'}</td>
                    <td>{r.owner ? <Address value={r.owner} /> : 'unknown'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {busy && <Loading what="circuits" />}
        {error && <Failure error={error} retry={() => more(next)} />}
        {!busy && !error && next <= p.circuits && (
          <button type="button" onClick={() => more(next)}>
            Show circuits {next} to {Math.min(p.circuits, next + PAGE - 1)}
          </button>
        )}
        <p class="muted">
          Read with batched <span class="mono">circuitInfo</span> and <span class="mono">ownerOf</span> calls, {PAGE} circuits per request.
          No event logs are used: the public nodes answer log queries for 100 blocks at most.
        </p>
      </section>
    </article>
  );
}
