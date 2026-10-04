// Where the keeper remembers, across restarts, the one settle it sent for each kernel in an epoch.
//
// Inside one process the memory in keeper.ts is enough. A restart loses it; this file brings it back as
// long as the file system survives the restart. It records only what was SENT (epoch and hash), never
// anything secret, and it is written before the broadcast.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import type { Address, Hex } from 'viem';

export interface SentRecord {
  epoch: number;
  txHash: Hex;
}

export interface StateStore {
  /** What was recorded by an earlier run, keyed by lowercase kernel address. Never throws. */
  load(): Map<string, SentRecord>;
  /** Record a send. Throws if it cannot be written; the caller decides what to do about that. */
  save(kernel: Address, record: SentRecord): void;
}

/** Remembers nothing beyond the process. */
export const memoryStore = (): StateStore => ({ load: () => new Map(), save: () => {} });

interface FileShape {
  version: 1;
  chainId: number;
  wallet: string;
  sent: Record<string, SentRecord>;
}

/**
 * A JSON file, replaced atomically on every save. Entries for another chain or another wallet are
 * ignored on load: they say nothing about what this wallet did here.
 */
export function fileStore(path: string, chainId: number, wallet: Address): StateStore {
  const walletKey = wallet.toLowerCase();
  const read = (): Map<string, SentRecord> => {
    const out = new Map<string, SentRecord>();
    try {
      const doc = JSON.parse(readFileSync(path, 'utf8')) as Partial<FileShape>;
      if (doc.version !== 1 || doc.chainId !== chainId || doc.wallet !== walletKey || !doc.sent) return out;
      for (const [kernel, r] of Object.entries(doc.sent)) {
        if (
          /^0x[0-9a-f]{40}$/.test(kernel) &&
          r &&
          Number.isSafeInteger(r.epoch) &&
          r.epoch >= 0 &&
          typeof r.txHash === 'string' &&
          /^0x[0-9a-fA-F]{64}$/.test(r.txHash)
        ) {
          out.set(kernel, { epoch: r.epoch, txHash: r.txHash });
        }
      }
    } catch {
      // No file yet, or an unreadable one: start empty.
    }
    return out;
  };

  return {
    load: read,
    save(kernel, record) {
      const sent = Object.fromEntries(read());
      sent[kernel.toLowerCase()] = record;
      const doc: FileShape = { version: 1, chainId, wallet: walletKey, sent };
      mkdirSync(dirname(path), { recursive: true });
      const tmp = `${path}.${process.pid}.tmp`;
      writeFileSync(tmp, JSON.stringify(doc), { mode: 0o600 });
      renameSync(tmp, path);
    },
  };
}
