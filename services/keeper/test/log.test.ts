import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createLogger, keyRedactions, toJson, urlRedactions } from '../src/log.ts';

const capture = (options: Parameters<typeof createLogger>[0] = {}): { lines: string[]; log: ReturnType<typeof createLogger> } => {
  const lines: string[] = [];
  const log = createLogger({ ...options, write: (l) => void lines.push(l), now: () => new Date('2026-10-04T12:00:00.000Z') });
  return { lines, log };
};

test('one JSON object per line, with ts, level and event', () => {
  const { lines, log } = capture();
  log.info('settled', { kernel: '0xabc', epoch: 5, gasUsed: 4_200_000n, refundWei: null });
  assert.equal(lines.length, 1);
  assert.doesNotMatch(lines[0]!, /\n/);
  assert.deepEqual(JSON.parse(lines[0]!), {
    ts: '2026-10-04T12:00:00.000Z',
    level: 'info',
    event: 'settled',
    message: 'settled',
    kernel: '0xabc',
    epoch: 5,
    gasUsed: '4200000',
    refundWei: null,
  });
});

test('bigint becomes a decimal string and an Error loses its stack', () => {
  assert.equal(toJson({ a: 2n ** 100n }), '{"a":"1267650600228229401496703205376"}');
  assert.equal(toJson({ e: new RangeError('boom') }), '{"e":{"name":"RangeError","message":"boom"}}');
});

test('levels below the threshold are dropped', () => {
  const { lines, log } = capture({ level: 'warn' });
  log.debug('a');
  log.info('b');
  log.warn('c');
  log.error('d');
  assert.deepEqual(lines.map((l) => JSON.parse(l).event), ['c', 'd']);
});

// Not a key: 2^256-1 is outside the valid range of a secp256k1 scalar. It only has the shape of one.
const KEY_SHAPED = 'f'.repeat(64);

test('a key-shaped secret never reaches the output, with or without 0x, in any letter case', () => {
  const { lines, log } = capture({ redactions: keyRedactions(`0x${KEY_SHAPED}`) });
  log.error('oops', {
    a: `0x${KEY_SHAPED}`,
    b: KEY_SHAPED,
    c: `prefix ${KEY_SHAPED.toUpperCase()} suffix`,
    nested: { d: [`0X${KEY_SHAPED}`] },
    e: new Error(`signing failed for ${KEY_SHAPED}`),
  });
  assert.equal(lines.length, 1);
  assert.doesNotMatch(lines[0]!, /f{16}/i);
  assert.equal((lines[0]!.match(/\[redacted-key\]/g) ?? []).length, 5);
  // The line is still valid JSON.
  assert.equal(JSON.parse(lines[0]!).event, 'oops');
});

test('keyRedactions ignores an absent or very short value', () => {
  assert.deepEqual(keyRedactions(null), []);
  assert.deepEqual(keyRedactions('0x12'), []);
});

test('RPC URLs are replaced by their host, so an API key in the path or query stays out of the logs', () => {
  const urls = ['https://rpc.example/v2/API-KEY-123', 'https://other.example/?apikey=SECRET'];
  const { lines, log } = capture({ redactions: urlRedactions(urls) });
  log.warn('rpc_error', { error: `request to ${urls[0]} failed`, also: urls[1] });
  assert.doesNotMatch(lines[0]!, /API-KEY-123|SECRET/);
  const parsed = JSON.parse(lines[0]!);
  assert.equal(parsed.error, 'request to rpc.example failed');
  assert.equal(parsed.also, 'other.example');
});
