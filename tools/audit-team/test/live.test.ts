// The nonce walk and the audit on REAL addresses of X Layer, at one pinned block so the results never change.
// Read-only JSON-RPC (https://rpc.xlayer.tech, archive). Skipped when OFFLINE=1.
//
//   Pinned block 72,378,000 (0x4506690), 2026-10-04 20:50:36 UTC,
//   hash 0xd7f9e638318189aa17d89d4ccd99467d2e3e8fb9942820a948ba0b6602b29635.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { runAudit } from '../audit.ts';
import { Chain } from '../chain.ts';
import { loadKnown } from '../known.ts';
import { verdictLines } from '../report.ts';

const offline = process.env.OFFLINE === '1';
const PINNED = 72_378_000;
const PINNED_HASH = '0xd7f9e638318189aa17d89d4ccd99467d2e3e8fb9942820a948ba0b6602b29635';
const DEPLOYER = '0x84ce7bae1b788c7ad985d57721ca428b401ae34d';
const OB_CREATOR = '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404';
const OB_CREATE_TX = '0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1';
const DELEGATING = '0xa572294862758fd4c720b435a8c246b5c76bae43';
const CLI = fileURLToPath(new URL('../audit-team.ts', import.meta.url));
const known = loadKnown(fileURLToPath(new URL('../addresses.json', import.meta.url)));
const urls = process.env.XLAYER_RPC_URL ? [process.env.XLAYER_RPC_URL] : undefined;

let dir: string;
before(() => {
  dir = mkdtempSync(join(tmpdir(), 'audit-team-live-'));
});
after(() => rmSync(dir, { recursive: true, force: true }));

const open = async (cache: string | null = null): Promise<Chain> => {
  const chain = new Chain({ urls, block: PINNED, cachePath: cache });
  await chain.open();
  assert.equal(chain.chainId, 196);
  assert.equal(chain.head, PINNED);
  return chain;
};

test('the pinned block is the block these tests were written against', { skip: offline }, async () => {
  const chain = await open();
  const [b] = (await chain.batch([['eth_getBlockByNumber', ['0x' + PINNED.toString(16), false]]])) as { hash: string; timestamp: string }[];
  assert.equal(b.hash, PINNED_HASH);
  assert.equal(Number(BigInt(b.timestamp)), 1_791_147_036);
});

test('the deployer has sent nothing: zero transactions, every rule checked, clean', { skip: offline }, async () => {
  const chain = await open();
  const r = await runAudit(chain, known, [{ address: DEPLOYER, role: 'Deployer, maintainer payee, token launcher' }]);
  assert.equal(r.wallets[0].transactionCount, 0);
  assert.equal(r.wallets[0].found, 0);
  assert.deepEqual(r.wallets[0].rows, []);
  assert.equal(r.wallets[0].code, '0x', 'a plain externally owned account');
  for (const rule of r.rules) {
    assert.equal(rule.count, 0, rule.title);
    assert.equal(rule.notChecked, null, rule.title);
  }
  assert.equal(r.exitCode, 0);
  assert.match(verdictLines(r).at(-1) as string, /^VERDICT: CLEAN\./);
});

test('the creator of the OB token: all 11 transactions are found, and its first buy and its trades are flagged', { skip: offline }, async () => {
  const chain = await open(join(dir, 'cache.json'));
  const [count] = await chain.counts(OB_CREATOR, [PINNED]);
  assert.equal(count, 11, 'eth_getTransactionCount at the pinned block');

  const r = await runAudit(chain, known, [{ address: OB_CREATOR, role: 'creator of OB' }]);
  chain.save();
  const w = r.wallets[0];
  assert.equal(w.transactionCount, count);
  assert.equal(w.found, count, 'exactly eth_getTransactionCount transactions were found');
  assert.equal(w.audited, count);
  assert.deepEqual(w.unexplained, []);
  assert.deepEqual(w.rows.map((x) => x.nonce), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 'every nonce, once');
  assert.ok(w.rows.every((x) => x.wallet === OB_CREATOR && x.kind === 'transaction'));

  // nonce 0 is the real createToken, with the first buy of 0.4 OKB
  const create = w.rows[0];
  assert.equal(create.hash, OB_CREATE_TX);
  assert.equal(create.block, 71_350_520);
  assert.equal(create.target, '0x96b51c57e5346d0c0198899243cf851d1e23c309');
  assert.equal(create.selector, '0xef44bdf2');
  assert.equal(create.selectorName, 'createToken');
  assert.equal(create.valueWei, '400000000000000000');
  assert.deepEqual(create.flags, ['first-buy']);
  assert.equal(create.classification, 'createToken "OB" WITH A FIRST BUY of 0.4 OKB');

  // two nonces in one block (71,394,296): the approval of the token and the sale that follows it
  assert.equal(w.rows[5].block, 71_394_296);
  assert.equal(w.rows[6].block, 71_394_296);
  assert.deepEqual(w.rows[5].flags, ['ignix-token-call']);
  assert.equal(w.rows[5].target, '0x995546dfdf93bef59c35742ab5f4762fbcb8eeee');
  assert.equal(w.rows[5].selectorName, 'approve');
  // the sale went through a DEX aggregator, so the target is not IGNIX: it is found in the logs
  assert.deepEqual(w.rows[6].flags, ['ignix-activity']);
  assert.equal(w.rows[6].target, '0x7c5bee2a8091c3ef39072f64f18fac913060aeaf');
  assert.match(w.rows[6].classification, /THE WALLET SOLD IGNIX token 0x9955\.\.\.eeee on the curve inside this transaction/);

  // the rest: six tax claims from its own vault and two plain transfers. Unknown targets, not flags.
  const claims = w.rows.filter((x) => x.selectorName === 'claim');
  assert.equal(claims.length, 6);
  for (const c of claims) {
    assert.equal(c.target, '0xec7732c9dcf978c8a97e6c44499331757d240365');
    assert.equal(c.targetLabel, 'IGNIX vault of token 0x9955...eeee');
    assert.deepEqual(c.flags, []);
    assert.equal(c.unknownTarget, true);
  }
  const transfers = w.rows.filter((x) => x.selector === null);
  assert.equal(transfers.length, 2);
  for (const t of transfers) assert.match(t.classification, /^unknown target \(an address without code\): plain transfer$/);
  assert.equal(r.unknownTargets, 9);

  const counts = Object.fromEntries(r.rules.map((x) => [x.id, x.count]));
  assert.deepEqual(counts, { 'ignix-call': 0, 'first-buy': 1, 'dex-call': 0, 'ignix-token-call': 1, 'ignix-activity': 1, 'kernel-value': 0, 'transistor-transfer': 0, delegation: 0, 'unexplained-nonce': 0 });
  assert.equal(r.exitCode, 1);
  assert.ok(w.walk.probes < 400, `${w.walk.probes} count queries for 11 transactions`);

  // a second run answers from the cache
  const again = await open(join(dir, 'cache.json'));
  const r2 = await runAudit(again, known, [{ address: OB_CREATOR, role: 'creator of OB' }]);
  assert.deepEqual(r2.wallets[0].rows, w.rows);
  assert.ok(again.stats.calls < chain.stats.calls / 3, `second run: ${again.stats.calls} RPC calls; first: ${chain.stats.calls}`);
});

test('a real wallet that signed an EIP-7702 authorisation: the nonce it used is explained (first 12 of 50 nonces)', { skip: offline }, async () => {
  // This wallet has 50 nonces at the pinned block. To keep the test short only the first 12 are audited:
  // 11 transactions and one authorisation (nonce 1, carried by a relayer's transaction).
  const chain = await open();
  const [count] = await chain.counts(DELEGATING, [PINNED]);
  assert.equal(count, 50);
  const r = await runAudit(chain, known, [{ address: DELEGATING, role: 'not a team wallet: a public example' }], { maxNonces: 12 });
  const w = r.wallets[0];
  assert.equal(w.transactionCount, 50);
  assert.equal(w.audited, 12);
  assert.equal(w.found, 11);
  assert.deepEqual(w.unexplained, []);
  assert.deepEqual(w.rows.map((x) => x.nonce), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  const auth = w.rows[1];
  assert.equal(auth.kind, 'authorization');
  assert.equal(auth.target, '0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4', 'the delegate named in the authorisation');
  assert.equal(auth.hash, '0xd930c6718fd35d2b8a249a62d475541d47cee91adfe1cb984557e73ae01e50d2', 'the transaction that carried it');
  assert.match(auth.classification, /carried by a transaction from 0x833290075c3196310f80fbcd96282d8ebe3ec6e8/);
  assert.match(w.code, /^0xef0100e40ccb2d94975c51bff0c004efdfd9b3a5796fa4$/, 'the wallet still carries the delegation');
  assert.equal(r.rules.find((x) => x.id === 'delegation')?.count, 2);
  // it trades IGNIX tokens through an aggregator: found in the logs
  assert.ok((r.rules.find((x) => x.id === 'ignix-activity')?.count ?? 0) >= 5);
  assert.ok((r.rules.find((x) => x.id === 'ignix-token-call')?.count ?? 0) >= 2);
  assert.equal(r.exitCode, 1);
  assert.match(r.incomplete.join(' '), /only the first 12 of 50 nonces were audited/);
});

const cli = (args: readonly string[]): Promise<{ code: number | null; stdout: string; stderr: string }> =>
  new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [CLI, ...args], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });

test('the program: the declared wallets of docs/WALLETS.md are clean at the pinned block (exit code 0)', { skip: offline }, async () => {
  const r = await cli(['--block', String(PINNED), '--out', join(dir, 'declared'), '--no-cache', ...(urls ? ['--rpc', urls[0]] : [])]);
  assert.equal(r.code, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /`0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` \(Deployer, maintainer payee, token launcher\)/);
  assert.match(r.stdout, /No transaction has ever been sent by this wallet\./);
  assert.match(r.stdout, /^VERDICT: CLEAN\. 0 transaction\(s\) of \d+ declared wallet\(s\) were examined at block 72378000/m);
  assert.match(r.stdout, /## What this method cannot see/);
  const j = JSON.parse(readFileSync(join(dir, 'declared', 'audit.json'), 'utf8'));
  assert.equal(j.verdict, 'CLEAN');
  assert.equal(j.block, PINNED);
});

test('the program: the OB creator is flagged (exit code 1) and the table and the JSON are written', { skip: offline }, async () => {
  const r = await cli(['--wallet', '0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404', '--block', String(PINNED), '--out', join(dir, 'ob'), '--no-cache', ...(urls ? ['--rpc', urls[0]] : [])]);
  assert.equal(r.code, 1, r.stdout + r.stderr);
  assert.match(r.stdout, /\| 71350520 \| 2026-09-22 23:25:56 \| 0 \| `0x96B51c57e5346D0C0198899243cf851D1E23C309` IgnixManager \| `0xef44bdf2` createToken \| 0\.4 \| createToken "OB" WITH A FIRST BUY of 0\.4 OKB \*\*\[FLAG first-buy\]\*\* \| `0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1` \|/);
  assert.match(r.stdout, /^FLAG\s+1\s+createToken with a first buy .*\(expected 0\): 0xc12f\.\.\.e404 nonce 0$/m);
  assert.match(r.stdout, /^COMPLETE\s+11\s+transaction\(s\) found for the 11 nonce\(s\) of 0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404/m);
  assert.match(r.stdout, /^VERDICT: FLAGGED\. 3 rule\(s\) were broken by 3 finding\(s\)/m);
  const j = JSON.parse(readFileSync(join(dir, 'ob', 'audit.json'), 'utf8'));
  assert.equal(j.verdict, 'FLAGGED');
  assert.equal(j.wallets[0].transactions.length, 11);
  assert.equal(j.wallets[0].transactions[0].hash, OB_CREATE_TX);
  assert.match(readFileSync(join(dir, 'ob', 'audit.md'), 'utf8'), /## Verdict/);
});

test('the program: wrong arguments and an unreachable node are exit code 2, never a clean result', async () => {
  const bad = await cli(['--wallet', '0x1234']);
  assert.equal(bad.code, 2);
  assert.match(bad.stderr, /not a 20-byte hex address/);
  const unknown = await cli(['--walet', DEPLOYER]);
  assert.equal(unknown.code, 2);
  const dead = await cli(['--wallet', DEPLOYER, '--rpc', 'http://127.0.0.1:9', '--no-cache', '--out', join(dir, 'dead')]);
  assert.equal(dead.code, 2);
  assert.match(dead.stderr, /could not complete the audit/);
  assert.match(dead.stderr, /NOT a clean result/);
  assert.doesNotMatch(dead.stdout, /VERDICT: CLEAN/);
});
