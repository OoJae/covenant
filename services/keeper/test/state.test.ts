// "At most one settle per kernel per epoch" across restarts of the process.

import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { loadConfig } from '../src/config.ts';
import { fileStore, memoryStore } from '../src/state.ts';
import type { StateStore } from '../src/state.ts';
import { KERNEL_A, KERNEL_B, WALLET, World, harness } from './helpers/fake-chain.ts';

const HASH_1 = `0x${'11'.repeat(32)}` as const;
const HASH_2 = `0x${'22'.repeat(32)}` as const;
const kinds = (outcomes: Array<{ kind: string }>): string[] => outcomes.map((o) => o.kind);

function tempFile(t: { after: (fn: () => void) => void }): string {
  const dir = mkdtempSync(join(tmpdir(), 'covenant-keeper-test-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'nested', 'state.json');
}

test('fileStore: empty when there is no file, and a save is read back', (t) => {
  const path = tempFile(t);
  const store = fileStore(path, 196, WALLET);
  assert.equal(store.load().size, 0);

  store.save(KERNEL_A, { epoch: 5, txHash: HASH_1 });
  store.save(KERNEL_B, { epoch: 9, txHash: HASH_2 });
  store.save(KERNEL_A, { epoch: 6, txHash: HASH_2 }); // a later epoch replaces the earlier one

  const again = fileStore(path, 196, WALLET).load();
  assert.deepEqual(again.get(KERNEL_A.toLowerCase()), { epoch: 6, txHash: HASH_2 });
  assert.deepEqual(again.get(KERNEL_B.toLowerCase()), { epoch: 9, txHash: HASH_2 });

  // Readable by the owner only, and it holds nothing but epochs and hashes.
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.deepEqual(Object.keys(JSON.parse(readFileSync(path, 'utf8'))).sort(), ['chainId', 'sent', 'version', 'wallet']);
});

test('fileStore ignores a file written for another chain or another wallet, and a damaged one', (t) => {
  const path = tempFile(t);
  fileStore(path, 196, WALLET).save(KERNEL_A, { epoch: 5, txHash: HASH_1 });
  assert.equal(fileStore(path, 1952, WALLET).load().size, 0);
  assert.equal(fileStore(path, 196, KERNEL_B).load().size, 0);
  assert.equal(fileStore(path, 196, WALLET).load().size, 1);

  writeFileSync(path, '{"version":1,"chainId":196,"wallet":"' + WALLET.toLowerCase() + '","sent":{"nonsense":{"epoch":"x"}}}');
  assert.equal(fileStore(path, 196, WALLET).load().size, 0);
  writeFileSync(path, 'not json');
  assert.equal(fileStore(path, 196, WALLET).load().size, 0);
});

test('a restarted keeper does not send again in an epoch its predecessor already sent in', async (t) => {
  const store = fileStore(tempFile(t), 196, WALLET);
  const world = new World();
  world.autoMine = false; // the first transaction stays pending

  const first = harness({}, { world, store });
  assert.deepEqual(kinds(await first.keeper.tick()), ['pending']);
  assert.equal(world.sent.length, 1);

  // The process dies; the transaction is dropped by the node. A new process starts in the same epoch.
  world.pool.clear();
  const second = harness({}, { world, store });
  assert.deepEqual(kinds(await second.keeper.tick()), ['already_sent']);
  assert.deepEqual(kinds(await second.keeper.tick()), ['already_sent']);
  assert.equal(world.sent.length, 1, 'no second transaction in the same epoch');
  assert.equal(second.signer?.signed, 0);

  // The next epoch is served normally.
  world.autoMine = true;
  world.kernel(KERNEL_A).epochNow = 6;
  assert.deepEqual(kinds(await second.keeper.tick()), ['settled']);
  assert.equal(world.sent.length, 2);
});

test('a restarted keeper does not retry a settle that reverted on chain in the same epoch', async (t) => {
  const store = fileStore(tempFile(t), 196, WALLET);
  const world = new World();
  world.mineReverts = true;
  const first = harness({}, { world, store });
  assert.deepEqual(kinds(await first.keeper.tick()), ['reverted']);

  world.mineReverts = false;
  const second = harness({}, { world, store });
  assert.deepEqual(kinds(await second.keeper.tick()), ['already_sent']);
  assert.equal(world.sent.length, 1);
});

test('without a store a restarted keeper has no memory of the epoch (why the store exists)', async () => {
  const world = new World();
  world.mineReverts = true;
  const first = harness({}, { world });
  assert.deepEqual(kinds(await first.keeper.tick()), ['reverted']);
  world.mineReverts = false;
  const second = harness({}, { world, store: memoryStore() });
  assert.deepEqual(kinds(await second.keeper.tick()), ['settled']);
  assert.equal(world.sent.length, 2);
});

test('a store that cannot be written is reported and does not stop the settle', async () => {
  const broken: StateStore = {
    load: () => new Map(),
    save: () => {
      throw new Error('EROFS: read-only file system');
    },
  };
  const h = harness({}, { store: broken });
  assert.deepEqual(kinds(await h.keeper.tick()), ['settled']);
  assert.match(String(h.log.find('state_not_saved')[0]?.fields['error']), /EROFS/);
  // The in-process memory still holds.
  assert.deepEqual(kinds(await h.keeper.tick()), ['idle']);
});

test('the state is saved before the broadcast', async (t) => {
  const path = tempFile(t);
  const world = new World();
  let savedAtBroadcast = false;
  world.beforeSend = () => {
    savedAtBroadcast = existsSync(path) && fileStore(path, 196, WALLET).load().get(KERNEL_A.toLowerCase())?.epoch === 5;
  };
  const h = harness({}, { world, store: fileStore(path, 196, WALLET) });
  await h.keeper.tick();
  assert.equal(savedAtBroadcast, true);
});

test('STATE_FILE: a file in the temporary directory by default, "none" for memory only', () => {
  const K = '0x00000000000000000000000000000000000000a1';
  assert.equal(loadConfig({ KERNELS: K }, []).stateFile, join(tmpdir(), 'covenant-keeper-state.json'));
  assert.equal(loadConfig({ KERNELS: K, STATE_FILE: 'none' }, []).stateFile, null);
  assert.equal(loadConfig({ KERNELS: K, STATE_FILE: '/data/keeper.json' }, []).stateFile, '/data/keeper.json');
});
