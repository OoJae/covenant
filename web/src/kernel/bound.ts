// The landing's live reads: the token bound to each flagship kernel, its symbol, the kernel's settle count and
// whether any tax has arrived.
// Loaded on demand by routes/Landing.tsx, so the chain's kernel ABI (packages/chain/src/kernel.ts) stays out of the
// page's entry script; the hero's ledger shows its rows from deployments/xlayer.json until these answer.

import { readAll } from '@covenant/chain';
import { erc20, kernel } from '@covenant/chain/kernel';
import { rpc } from '../config.ts';

const ZERO = '0x0000000000000000000000000000000000000000';

/** A kernel and the token bound to it, read from the chain. */
export interface Bound {
  version: 1 | 2;
  kernel: string;
  token: string | null;
  symbol: string | null;
  count: number | null;
  /** On the curve with cumulative inflow 0: every settle so far carried no tax. False when either read fails. */
  idle: boolean;
}

/** Bound token, its symbol, the settle count and the idle flag of each kernel given. */
export async function boundTokens(kernels: { version: 1 | 2; kernel: string }[]): Promise<Bound[]> {
  const ks: Bound[] = kernels.map((k) => ({ ...k, token: null, symbol: null, count: null, idle: false }));
  if (ks.length === 0) return ks;
  const r = await readAll(rpc, ks.flatMap((k) => [kernel(k.kernel).token(), kernel(k.kernel).count(), kernel(k.kernel).cumInflow(), kernel(k.kernel).graduated()]));
  ks.forEach((k, i) => {
    const t = r[4 * i];
    const c = r[4 * i + 1];
    k.token = typeof t === 'string' && t.toLowerCase() !== ZERO ? t : null;
    k.count = typeof c === 'number' ? c : null;
    // cumInflow restarts at graduation, so it says "no tax so far" only while the kernel is on the curve.
    k.idle = r[4 * i + 2] === 0n && r[4 * i + 3] === false;
  });
  const withToken = ks.filter((k) => k.token !== null);
  if (withToken.length > 0) {
    const s = await readAll(rpc, withToken.map((k) => erc20(k.token!).symbol()));
    withToken.forEach((k, i) => {
      const v = s[i];
      k.symbol = typeof v === 'string' ? v : null;
    });
  }
  return ks;
}
