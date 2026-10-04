import assert from 'node:assert/strict';
import { test } from 'node:test';
import { RevertError, RpcError, RpcUnavailableError } from '../src/errors.ts';
import { RpcPool } from '../src/pool.ts';
import { FakeChain, World, manualClock, memoryLogger } from './helpers/fake-chain.ts';

function setup(n: number, options: { maxRounds?: number; maxDelayMs?: number; random?: () => number } = {}) {
  const world = new World();
  const chains = Array.from({ length: n }, (_, i) => new FakeChain(world, `rpc-${i}`));
  const log = memoryLogger();
  const clock = manualClock();
  const pool = new RpcPool(chains, { log, sleep: clock.sleep, random: options.random ?? (() => 0), ...options });
  return { world, chains, log, clock, pool };
}

test('a healthy endpoint is used without switching or sleeping', async () => {
  const s = setup(2);
  assert.equal(await s.pool.call('chainId', (c) => c.chainId()), 196);
  assert.equal(s.pool.current.label, 'rpc-0');
  assert.deepEqual(s.clock.slept, []);
});

test('an RPC error switches to the next endpoint at once, without sleeping', async () => {
  const s = setup(3);
  s.chains[0]!.failNext('chainId', 1);
  assert.equal(await s.pool.call('chainId', (c) => c.chainId()), 196);
  assert.equal(s.pool.current.label, 'rpc-1');
  assert.deepEqual(s.clock.slept, []);
  // The pool stays on the endpoint that works.
  await s.pool.call('chainId', (c) => c.chainId());
  assert.equal(s.chains[1]!.calls['chainId'], 2);
  assert.equal(s.chains[0]!.calls['chainId'], 1);
});

test('after a full failed round the pool backs off, doubling each round, then recovers', async () => {
  const s = setup(2, { maxRounds: 5 });
  s.chains[0]!.failNext('chainId', 2);
  s.chains[1]!.failNext('chainId', 2);
  assert.equal(await s.pool.call('chainId', (c) => c.chainId()), 196);
  assert.deepEqual(s.clock.slept, [1000, 2000]);
});

test('it gives up with RpcUnavailableError after maxRounds rounds', async () => {
  const s = setup(2, { maxRounds: 3 });
  s.chains[0]!.failNext('*', 100);
  s.chains[1]!.failNext('*', 100);
  await assert.rejects(s.pool.call('chainId', (c) => c.chainId()), (e: unknown) => {
    assert.ok(e instanceof RpcUnavailableError);
    assert.match(e.message, /all 2 RPC endpoint\(s\) failed 3 time\(s\)/);
    return true;
  });
  assert.deepEqual(s.clock.slept, [1000, 2000]);
  assert.equal(s.chains[0]!.calls['chainId'], 3);
  assert.equal(s.chains[1]!.calls['chainId'], 3);
});

test('a single endpoint backs off after every failure', async () => {
  const s = setup(1, { maxRounds: 4 });
  s.chains[0]!.failNext('chainId', 3);
  assert.equal(await s.pool.call('chainId', (c) => c.chainId()), 196);
  assert.deepEqual(s.clock.slept, [1000, 2000, 4000]);
});

test('the delay is capped and carries up to 25% jitter', () => {
  const s = setup(1, { maxDelayMs: 5000, random: () => 1 });
  assert.equal(s.pool.backoffMs(1), 1250);
  assert.equal(s.pool.backoffMs(2), 2500);
  assert.equal(s.pool.backoffMs(3), 5000);
  assert.equal(s.pool.backoffMs(10), 6250); // capped at 5000, plus jitter
});

test('a revert is not an RPC fault: no switch, no retry', async () => {
  const s = setup(2);
  let attempts = 0;
  await assert.rejects(
    s.pool.call('simulate', async () => {
      attempts++;
      throw new RevertError('epoch already settled');
    }),
    RevertError,
  );
  assert.equal(attempts, 1);
  assert.equal(s.pool.current.label, 'rpc-0');
});

test('errors are logged with the endpoint that failed and the one tried next', async () => {
  const s = setup(2);
  await assert.rejects(
    s.pool.call('x', async (c) => {
      throw new RpcError(c.label, 'eth_x', 'http 502');
    }),
    RpcUnavailableError,
  );
  const first = s.log.find('rpc_error')[0]!.fields;
  assert.equal(first['rpc'], 'rpc-0');
  assert.equal(first['next'], 'rpc-1');
  assert.equal(first['call'], 'x');
});

test('an empty pool is refused', () => {
  const log = memoryLogger();
  assert.throws(() => new RpcPool([], { log, sleep: async () => {} }));
});
