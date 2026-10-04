import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DEFAULT_REFUNDED_EVENT, DEFAULT_RPC_URLS, loadConfig, takePrivateKey } from '../src/config.ts';
import { ConfigError } from '../src/errors.ts';
import { signerFromKey } from '../src/signer.ts';

const K1 = '0x00000000000000000000000000000000000000A1';
const K2 = '0x00000000000000000000000000000000000000b2';
const USDT0 = '0x779Ded0c9e1022225f8E0630b35a9b54bE713736';

const bad = (env: Record<string, string>, argv: string[], pattern: RegExp): void => {
  assert.throws(() => loadConfig(env, argv), (e: unknown) => e instanceof ConfigError && pattern.test(e.message));
};

test('defaults', () => {
  const c = loadConfig({ KERNELS: K1 }, []);
  assert.deepEqual(c.kernels, [K1]);
  assert.equal(c.tank, null);
  assert.deepEqual(c.rpcUrls, DEFAULT_RPC_URLS);
  assert.equal(c.chainId, 196);
  assert.equal(c.maxFeePerGasCap, 100_000_000n); // 0.1 gwei
  assert.equal(c.priorityFeePerGas, 1_000_000n); // 0.001 gwei
  assert.equal(c.maxGasLimit, 30_000_000n);
  assert.equal(c.pollIntervalMs, 30_000);
  assert.equal(c.minEpochLag, 1);
  assert.equal(c.receiptTimeoutMs, 60_000);
  assert.equal(c.stuckTxMs, 180_000);
  assert.equal(c.directFallback, true);
  assert.equal(c.dryRun, false);
  assert.equal(c.once, false);
  assert.equal(c.minBalanceWei, 20_000_000_000_000_000n); // 0.02 OKB
  assert.equal(c.logLevel, 'info');
  assert.equal(c.keeperAddress, null);
  assert.equal(c.refundedEvent, DEFAULT_REFUNDED_EVENT);
});

test('KERNELS: comma-separated, trimmed, checksummed on the way in', () => {
  const c = loadConfig({ KERNELS: ` ${K1.toLowerCase()} , ${K2} ,` }, []);
  assert.deepEqual(c.kernels, [K1, '0x00000000000000000000000000000000000000b2']);
});

test('KERNELS is required and must hold valid, distinct, non-zero addresses', () => {
  bad({}, [], /KERNELS is required/);
  bad({ KERNELS: '  ' }, [], /KERNELS is required/);
  bad({ KERNELS: ',,' }, [], /no address found/);
  bad({ KERNELS: '0x1234' }, [], /not a 20-byte hex address/);
  bad({ KERNELS: `${K1},${K1.toLowerCase()}` }, [], /listed twice/);
  bad({ KERNELS: '0x0000000000000000000000000000000000000000' }, [], /zero address/);
  // A single flipped letter case breaks the EIP-55 checksum: a typo guard.
  bad({ KERNELS: USDT0.replace('D', 'd') }, [], /EIP-55 checksum/);
});

test('TANK is optional, validated, and may not be one of the kernels', () => {
  assert.equal(loadConfig({ KERNELS: K1, TANK: '' }, []).tank, null);
  assert.equal(loadConfig({ KERNELS: K1, TANK: K2 }, []).tank, '0x00000000000000000000000000000000000000b2');
  bad({ KERNELS: K1, TANK: 'tank' }, [], /TANK: .*not a 20-byte hex address/);
  bad({ KERNELS: K1, TANK: K1 }, [], /TANK must not also be listed in KERNELS/);
});

test('fees', () => {
  const c = loadConfig({ KERNELS: K1, MAX_FEE_GWEI: '0.05', PRIORITY_FEE_GWEI: '0' }, []);
  assert.equal(c.maxFeePerGasCap, 50_000_000n);
  assert.equal(c.priorityFeePerGas, 0n);
  bad({ KERNELS: K1, MAX_FEE_GWEI: '0' }, [], /greater than zero/);
  bad({ KERNELS: K1, MAX_FEE_GWEI: '-1' }, [], /not a gwei amount/);
  bad({ KERNELS: K1, MAX_FEE_GWEI: '1e-2' }, [], /not a gwei amount/);
  bad({ KERNELS: K1, MAX_FEE_GWEI: '0.0000000001' }, [], /not a gwei amount/);
  bad({ KERNELS: K1, MAX_FEE_GWEI: '0.01', PRIORITY_FEE_GWEI: '0.02' }, [], /must not exceed MAX_FEE_GWEI/);
});

test('numbers, booleans, flags', () => {
  const c = loadConfig(
    { KERNELS: K1, POLL_INTERVAL_SECONDS: '15', MIN_EPOCH_LAG: '2', DRY_RUN: 'true', DIRECT_FALLBACK: '0', CHAIN_ID: '1952' },
    ['--once'],
  );
  assert.equal(c.pollIntervalMs, 15_000);
  assert.equal(c.minEpochLag, 2);
  assert.equal(c.dryRun, true);
  assert.equal(c.directFallback, false);
  assert.equal(c.once, true);
  assert.equal(c.chainId, 1952);
  assert.equal(loadConfig({ KERNELS: K1 }, ['--dry-run']).dryRun, true);
  assert.equal(loadConfig({ KERNELS: K1, ONCE: '1' }, []).once, true);

  bad({ KERNELS: K1, POLL_INTERVAL_SECONDS: '1' }, [], /outside 2\.\.3600/);
  bad({ KERNELS: K1, POLL_INTERVAL_SECONDS: 'soon' }, [], /not a whole number/);
  bad({ KERNELS: K1, MIN_EPOCH_LAG: '0' }, [], /outside 1\.\.14/);
  // The chip's elapsed-epochs input saturates at 15; a lag policy at or above that is refused.
  bad({ KERNELS: K1, MIN_EPOCH_LAG: '15' }, [], /outside 1\.\.14/);
  bad({ KERNELS: K1, DRY_RUN: 'maybe' }, [], /not a boolean/);
  bad({ KERNELS: K1, LOG_LEVEL: 'loud' }, [], /LOG_LEVEL/);
  bad({ KERNELS: K1 }, ['--send-everything'], /unknown argument/);
  bad({ KERNELS: K1, RECEIPT_TIMEOUT_SECONDS: '120', STUCK_TX_SECONDS: '60' }, [], /STUCK_TX_SECONDS must be at least/);
});

test('RPC_URLS', () => {
  const c = loadConfig({ KERNELS: K1, RPC_URLS: 'https://a.example/rpc , http://127.0.0.1:8545' }, []);
  assert.deepEqual(c.rpcUrls, ['https://a.example/rpc', 'http://127.0.0.1:8545']);
  bad({ KERNELS: K1, RPC_URLS: 'not a url' }, [], /not a valid URL/);
  bad({ KERNELS: K1, RPC_URLS: 'ws://a.example' }, [], /must use http or https/);
  bad({ KERNELS: K1, RPC_URLS: 'https://a.example,https://a.example' }, [], /listed twice/);
  bad({ KERNELS: K1, RPC_URLS: ' , ' }, [], /no URL given/);
});

test('a malformed RPC URL is not echoed (it may hold an API key)', () => {
  try {
    loadConfig({ KERNELS: K1, RPC_URLS: 'https//rpc.example/v2/SECRET-API-KEY' }, []);
    assert.fail('expected a ConfigError');
  } catch (e) {
    assert.ok(e instanceof ConfigError);
    assert.doesNotMatch(e.message, /SECRET-API-KEY/);
  }
});

test('KEEPER_ADDRESS is validated', () => {
  assert.equal(loadConfig({ KERNELS: K1, KEEPER_ADDRESS: USDT0 }, []).keeperAddress, USDT0);
  bad({ KERNELS: K1, KEEPER_ADDRESS: '0xabc' }, [], /KEEPER_ADDRESS/);
});

// The strings below are not keys: zero and 2^256-1 are both outside the valid range of a secp256k1 scalar.
const NOT_A_KEY_ZERO = '0'.repeat(64);
const NOT_A_KEY_MAX = 'F'.repeat(64);

test('takePrivateKey removes the variable from the environment and normalises the format', () => {
  const env: Record<string, string | undefined> = { KEEPER_PRIVATE_KEY: `  ${NOT_A_KEY_MAX}  `, OTHER: 'x' };
  const taken = takePrivateKey(env);
  assert.equal(taken, `0x${'f'.repeat(64)}`);
  assert.equal('KEEPER_PRIVATE_KEY' in env, false);
  assert.equal(env['OTHER'], 'x');

  assert.equal(takePrivateKey({ KEEPER_PRIVATE_KEY: `0x${NOT_A_KEY_ZERO}` }), `0x${NOT_A_KEY_ZERO}`);
  assert.equal(takePrivateKey({}), null);
  assert.equal(takePrivateKey({ KEEPER_PRIVATE_KEY: '   ' }), null);
});

test('takePrivateKey rejects a malformed value without echoing it', () => {
  const secretish = 'my-very-secret-value-that-must-not-be-printed';
  const env: Record<string, string | undefined> = { KEEPER_PRIVATE_KEY: secretish };
  try {
    takePrivateKey(env);
    assert.fail('expected a ConfigError');
  } catch (e) {
    assert.ok(e instanceof ConfigError);
    assert.doesNotMatch(e.message, /my-very-secret/);
    assert.match(e.message, /not 32 bytes of hex/);
  }
  // Removed from the environment even when it is rejected.
  assert.equal('KEEPER_PRIVATE_KEY' in env, false);
});

test('signerFromKey turns an out-of-range value into a ConfigError that does not contain it', () => {
  for (const value of [NOT_A_KEY_ZERO, NOT_A_KEY_MAX.toLowerCase()]) {
    try {
      signerFromKey(`0x${value}`);
      assert.fail('expected a ConfigError');
    } catch (e) {
      assert.ok(e instanceof ConfigError);
      assert.equal(e.message, 'KEEPER_PRIVATE_KEY is not a valid secp256k1 private key');
    }
  }
});
