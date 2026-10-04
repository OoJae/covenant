// End to end over real HTTP against a local JSON-RPC server: the JSON-RPC client, the pool, the
// scheduler and the entry point together. Still no network beyond 127.0.0.1 and no key.

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { makeRefundDecoder, settleAndRefundCalldata } from '../src/abi.ts';
import { JsonRpcChainClient } from '../src/chain.ts';
import { DEFAULT_REFUNDED_EVENT } from '../src/config.ts';
import { Keeper } from '../src/keeper.ts';
import { RpcPool } from '../src/pool.ts';
import { DEFAULT_OPTIONS, KERNEL_A, KERNEL_B, TANK, WALLET, World, fakeSigner, memoryLogger } from './helpers/fake-chain.ts';
import { startRpcServer } from './helpers/rpc-server.ts';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const realSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

interface Run {
  code: number;
  lines: Array<Record<string, unknown>>;
  stdout: string;
  stderr: string;
}

/** Run the real entry point with exactly the given environment (nothing inherited but PATH). */
function runCli(args: string[], env: Record<string, string>): Promise<Run> {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      ['src/index.ts', ...args],
      { cwd: ROOT, env: { PATH: process.env['PATH'] ?? '', ...env }, timeout: 30_000 },
      (error, stdout, stderr) => {
        const code = error ? (typeof error.code === 'number' ? error.code : 1) : 0;
        const lines = stdout
          .split('\n')
          .filter((l) => l.trim().startsWith('{'))
          .map((l) => JSON.parse(l) as Record<string, unknown>);
        resolve({ code, lines, stdout, stderr });
      },
    );
  });
}

test('scheduler + JSON-RPC client over HTTP: one settle is broadcast, mined and reported with its refund', async () => {
  const world = new World();
  const server = await startRpcServer(world);
  try {
    const log = memoryLogger();
    const pool = new RpcPool([new JsonRpcChainClient(server.url, { timeoutMs: 5000 })], { log, sleep: realSleep });
    const keeper = new Keeper(
      { ...DEFAULT_OPTIONS, receiptPollMs: 20 },
      { pool, signer: fakeSigner(), from: WALLET, log, now: Date.now, sleep: realSleep, decodeRefund: makeRefundDecoder(DEFAULT_REFUNDED_EVENT) },
    );
    await keeper.preflight();
    const out = await keeper.tick();
    assert.deepEqual(out.map((o) => o.kind), ['settled']);

    const broadcasts = server.requests.filter((r) => r.method === 'eth_sendRawTransaction');
    assert.equal(broadcasts.length, 1);
    const tx = world.sent[0]!;
    assert.equal(tx.to.toLowerCase(), TANK.toLowerCase());
    assert.equal(tx.data, settleAndRefundCalldata(KERNEL_A));
    assert.equal(tx.gas, 11_000_000n);
    assert.equal(tx.maxFeePerGas, 41_000_000n);
    assert.equal(tx.chainId, 196);

    // The simulation went out with the exact gas limit and the fee fields (the wallet can afford the worst case).
    const sims = server.requests.filter(
      (r) => r.method === 'eth_call' && (r.params[0] as { gas?: string }).gas !== undefined,
    );
    assert.equal(sims.length, 1);
    assert.deepEqual(sims[0]?.params[0], {
      from: WALLET,
      to: TANK,
      data: settleAndRefundCalldata(KERNEL_A),
      value: '0x0',
      gas: '0xa7d8c0',
      maxFeePerGas: '0x2719c40',
      maxPriorityFeePerGas: '0xf4240',
    });

    const line = log.find('settled')[0]!.fields;
    assert.equal(line['epoch'], 5);
    assert.equal(line['txHash'], tx.hash);
    assert.equal(line['gasUsed'], 4_200_000n);
    assert.equal(line['refundWei'], 123_000_000_000_000n);
    assert.equal(line['record'], 1);

    // Polled again in the same epoch: idle, and no second broadcast.
    assert.deepEqual((await keeper.tick()).map((o) => o.kind), ['idle']);
    assert.equal(server.requests.filter((r) => r.method === 'eth_sendRawTransaction').length, 1);
  } finally {
    await server.close();
  }
});

test('entry point, --once --dry-run: prints what it would send, exits 0, broadcasts nothing', async () => {
  const world = new World();
  world.addKernel(KERNEL_B, { epochNow: 4, lastEpoch: 4 }); // nothing due for this one
  const server = await startRpcServer(world);
  const stateDir = mkdtempSync(join(tmpdir(), 'covenant-keeper-e2e-'));
  const stateFile = join(stateDir, 'state.json');
  try {
    const run = await runCli(['--once', '--dry-run'], {
      RPC_URLS: server.url,
      KERNELS: `${KERNEL_A},${KERNEL_B}`,
      TANK,
      KEEPER_ADDRESS: WALLET,
      STATE_FILE: stateFile,
    });
    assert.equal(run.code, 0, run.stdout + run.stderr);
    const events = run.lines.map((l) => l['event']);
    assert.deepEqual(
      events.filter((e) => ['started', 'kernel_ok', 'dry_run', 'idle', 'heartbeat', 'done'].includes(String(e))),
      ['started', 'kernel_ok', 'kernel_ok', 'dry_run', 'idle', 'heartbeat', 'done'],
    );

    const dry = run.lines.find((l) => l['event'] === 'dry_run')!;
    assert.equal(dry['wouldSend'], true);
    assert.equal(dry['kernel'], KERNEL_A);
    assert.equal(dry['epoch'], 5);
    assert.equal(dry['via'], 'tank');
    assert.equal(dry['from'], WALLET);
    assert.equal(dry['to'], TANK);
    assert.equal(dry['data'], settleAndRefundCalldata(KERNEL_A));
    assert.equal(dry['gasLimit'], '11000000');
    assert.equal(dry['maxFeePerGasWei'], '41000000');
    assert.equal(dry['maxPriorityFeePerGasWei'], '1000000');
    assert.equal(dry['nonce'], 7);

    const started = run.lines.find((l) => l['event'] === 'started')!;
    assert.equal(started['dryRun'], true);
    assert.equal(started['signer'], false);
    assert.deepEqual(started['rpc'], [new URL(server.url).host]);

    assert.equal(server.requests.filter((r) => r.method === 'eth_sendRawTransaction').length, 0);
    assert.equal(world.sent.length, 0);
    // A dry run sends nothing, so it leaves no state behind either.
    assert.equal(existsSync(stateFile), false);
  } finally {
    await server.close();
    rmSync(stateDir, { recursive: true, force: true });
  }
});

test('entry point, --once: a due settle that cannot be simulated exits 1', async () => {
  const world = new World();
  world.kernel(KERNEL_A).settleRevert = 'evaluator failed';
  const server = await startRpcServer(world);
  try {
    const run = await runCli(['--once', '--dry-run'], { RPC_URLS: server.url, KERNELS: KERNEL_A, TANK, KEEPER_ADDRESS: WALLET });
    assert.equal(run.code, 1, run.stdout + run.stderr);
    const failed = run.lines.find((l) => l['event'] === 'settle_simulation_failed')!;
    assert.match(String(failed['reason']), /evaluator failed/);
  } finally {
    await server.close();
  }
});

test('entry point: configuration errors exit 2 before anything else happens', async () => {
  const world = new World();
  const server = await startRpcServer(world);
  try {
    // No key and not a dry run.
    let run = await runCli(['--once'], { RPC_URLS: server.url, KERNELS: KERNEL_A });
    assert.equal(run.code, 2);
    assert.match(String(run.lines.at(-1)?.['error']), /KEEPER_PRIVATE_KEY is required/);
    assert.equal(server.requests.length, 0, 'nothing was asked of the chain');

    // The chain behind the RPC is not the configured one.
    run = await runCli(['--once', '--dry-run'], { RPC_URLS: server.url, KERNELS: KERNEL_A, CHAIN_ID: '1' });
    assert.equal(run.code, 2);
    assert.match(String(run.lines.at(-1)?.['error']), /serves chain 196, expected 1/);

    // A kernel address with no code behind it.
    run = await runCli(['--once', '--dry-run'], { RPC_URLS: server.url, KERNELS: WALLET });
    assert.equal(run.code, 2);
    assert.match(String(run.lines.at(-1)?.['error']), /no contract code/);

    // An event signature that does not parse.
    run = await runCli(['--once', '--dry-run'], { RPC_URLS: server.url, KERNELS: KERNEL_A, TANK_REFUNDED_EVENT: 'Refunded' });
    assert.equal(run.code, 2);
    assert.match(String(run.lines.at(-1)?.['error']), /TANK_REFUNDED_EVENT/);
  } finally {
    await server.close();
  }
});

test('entry point, --once: an unreachable chain exits 1, not 2', async () => {
  const run = await runCli(['--once', '--dry-run'], {
    RPC_URLS: 'http://127.0.0.1:9',
    KERNELS: KERNEL_A,
    RPC_TIMEOUT_SECONDS: '2',
  });
  assert.equal(run.code, 1, run.stdout + run.stderr);
  assert.ok(run.lines.some((l) => l['event'] === 'rpc_unavailable'));
});

test('entry point: a key-shaped but invalid KEEPER_PRIVATE_KEY is refused and never printed', async () => {
  // Not a key: zero is outside the valid range of a secp256k1 scalar.
  const notAKey = '0'.repeat(64);
  const run = await runCli(['--once'], { RPC_URLS: 'http://127.0.0.1:9', KERNELS: KERNEL_A, KEEPER_PRIVATE_KEY: notAKey });
  assert.equal(run.code, 2);
  assert.match(String(run.lines.at(-1)?.['error']), /not a valid secp256k1 private key/);
  assert.doesNotMatch(run.stdout + run.stderr, /0{64}/);
});
