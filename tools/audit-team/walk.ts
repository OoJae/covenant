// The nonce walk: find every transaction an address has ever sent, using nothing but
// eth_getTransactionCount at historical blocks (an archive node) and the blocks themselves.
//
// eth_getTransactionCount(address, B) is the number of nonces the address has used up to and including
// block B. So the transaction with nonce n sits in the first block whose count exceeds n. The search below
// is a bisection over block ranges: a range whose count does not change holds no transaction of the address
// and is dropped; a range that narrows to one block holds the nonces from the count before it to the count
// after it (several, if the address sent several transactions in that block).
//
// With one probe per range and round this is the plain binary search. JSON-RPC batches carry up to ten
// calls per HTTP request, so while few ranges are open each one gets several evenly spaced probes per round
// (up to ten in total), which cuts the number of round trips from about 27 to about 8 for one transaction.

/** Counts after each of the given blocks, in the same order. */
export type CountProbe = (blocks: readonly number[]) => Promise<number[]>;

/** A block in which the address used the nonces `firstNonce .. lastNonce` (inclusive). */
export interface NonceBlock {
  block: number;
  firstNonce: number;
  lastNonce: number;
}

export interface WalkResult {
  /** Count at `head`: the number of nonces to explain. */
  total: number;
  /** Nonces already used at `floor` (0 unless the address has a nonce at the genesis block). */
  atFloor: number;
  /** One entry per block in which the count rose, ascending. Together they cover atFloor .. total - 1. */
  blocks: NonceBlock[];
  /** Number of probe rounds (each round is one call of `probe`). */
  rounds: number;
  /** Number of block counts asked for. */
  probes: number;
}

export interface WalkOptions {
  /** Lowest block to consider. Default 0. */
  floor?: number;
  /** Probes per round while few ranges are open. Default 10 (one JSON-RPC batch). */
  probesPerRound?: number;
}

interface Range {
  lo: number; // count at the END of block lo is `cLo`
  hi: number;
  cLo: number;
  cHi: number;
}

/** Up to `k` distinct blocks strictly between lo and hi, evenly spaced. */
function pointsBetween(lo: number, hi: number, k: number): number[] {
  const gap = hi - lo;
  const n = Math.min(k, gap - 1);
  const out: number[] = [];
  for (let i = 1; i <= n; i++) {
    const p = lo + Math.floor((gap * i) / (n + 1));
    if (p > lo && p < hi && out[out.length - 1] !== p) out.push(p);
  }
  return out;
}

export async function walkNonces(probe: CountProbe, head: number, opts: WalkOptions = {}): Promise<WalkResult> {
  const floor = opts.floor ?? 0;
  const perRound = Math.max(1, opts.probesPerRound ?? 10);
  if (!Number.isInteger(head) || head < floor) throw new Error('walkNonces: head is below the floor');

  let rounds = 1;
  let probes = 2;
  const [atFloor, total] = await probe([floor, head]);
  if (total < atFloor) throw new Error(`walkNonces: the count fell from ${atFloor} at block ${floor} to ${total} at block ${head}`);

  const done: NonceBlock[] = [];
  let open: Range[] = total > atFloor ? [{ lo: floor, hi: head, cLo: atFloor, cHi: total }] : [];

  while (open.length) {
    // ranges that are one block wide are finished
    const next: Range[] = [];
    for (const r of open) {
      if (r.hi - r.lo === 1) done.push({ block: r.hi, firstNonce: r.cLo, lastNonce: r.cHi - 1 });
      else next.push(r);
    }
    open = next;
    if (!open.length) break;

    const k = Math.max(1, Math.floor(perRound / open.length));
    const asked = open.map((r) => pointsBetween(r.lo, r.hi, k));
    const flat = asked.flat();
    const counts = await probe(flat);
    if (counts.length !== flat.length) throw new Error('walkNonces: the probe returned a different number of counts');
    rounds++;
    probes += flat.length;

    const refined: Range[] = [];
    let at = 0;
    open.forEach((r, i) => {
      let lo = r.lo;
      let cLo = r.cLo;
      for (const p of asked[i]) {
        const c = counts[at++];
        if (!Number.isInteger(c) || c < cLo || c > r.cHi) {
          throw new Error(`walkNonces: the count at block ${p} is ${c}, outside ${cLo}..${r.cHi}; the node is not serving consistent archive state`);
        }
        if (c > cLo) refined.push({ lo, hi: p, cLo, cHi: c });
        lo = p;
        cLo = c;
      }
      if (r.cHi > cLo) refined.push({ lo, hi: r.hi, cLo, cHi: r.cHi });
    });
    open = refined;
  }

  done.sort((a, b) => a.block - b.block);
  // the blocks must account for every nonce exactly once
  let expect = atFloor;
  for (const b of done) {
    if (b.firstNonce !== expect) throw new Error(`walkNonces: nonce ${expect} is not covered (next block starts at ${b.firstNonce})`);
    expect = b.lastNonce + 1;
  }
  if (expect !== total) throw new Error(`walkNonces: nonces ${expect}..${total - 1} are not covered`);
  return { total, atFloor, blocks: done, rounds, probes };
}
