// The landing's live reads: the token bound to each flagship kernel, its symbol and the kernel's settle count.
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
}

/** Bound token, its symbol and the settle count of each kernel given. */
export async function boundTokens(kernels: { version: 1 | 2; kernel: string }[]): Promise<Bound[]> {
  const ks: Bound[] = kernels.map((k) => ({ ...k, token: null, symbol: null, count: null }));
  if (ks.length === 0) return ks;
  const r = await readAll(rpc, ks.flatMap((k) => [kernel(k.kernel).token(), kernel(k.kernel).count()]));
  ks.forEach((k, i) => {
    const t = r[2 * i];
    const c = r[2 * i + 1];
    k.token = typeof t === 'string' && t.toLowerCase() !== ZERO ? t : null;
    k.count = typeof c === 'number' ? c : null;
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
