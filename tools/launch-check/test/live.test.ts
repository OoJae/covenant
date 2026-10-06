// The decoder against the live chain (read-only JSON-RPC). Skipped when OFFLINE=1.
//
//   1. The fixture of the OB launch is what the chain says today (so the offline tests compare against
//      real chain values, not against a stale copy).
//   2. For every real launch in the corpus, the decoded fields equal what IgnixManager, the vault and the
//      token report now.
//   3. launch-check, run as a program against the real chain, refuses the real OB launch.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createRpc, decAddress, decString, decUint, readAll, type Call } from '../../../packages/chain/src/index.ts';
import { MANAGER, decodeCreateToken, decodeRecipient, selectorOf } from '../decode.ts';
import { addressWord, strip0x } from '../hex.ts';

const offline = process.env.OFFLINE === '1';
const rpc = createRpc(process.env.XLAYER_RPC_URL ? [process.env.XLAYER_RPC_URL] : ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com']);
const fixture = (name: string): any => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
const ob = fixture('ob-launch.json');
const corpus = fixture('directed-launches.json');

const words = (ret: string): bigint[] => {
  const h = strip0x(ret);
  const out: bigint[] = [];
  for (let i = 0; i < h.length; i += 64) out.push(BigInt('0x' + h.slice(i, i + 64)));
  return out;
};
const addr = (w: bigint): string => '0x' + w.toString(16).padStart(40, '0');
const mk = <T>(to: string, signature: string, args: string, decode: (ret: string) => T): Call<T> => ({ to, data: selectorOf(signature) + args, decode });

test('the OB fixture is what X Layer reports now', { skip: offline }, async () => {
  const at = ob.transaction.blockNumber;
  const before = '0x' + (BigInt(at) - 1n).toString(16);
  const token = '0x995546dfdf93bef59c35742ab5f4762fbcb8eeee';
  const call = (to: string, signature: string, args: string, block: string) => ['eth_call', [{ to, data: selectorOf(signature) + args }, block]] as const;
  const r = await rpc.batch([
    ['eth_chainId', []],
    ['eth_getTransactionByHash', [ob.transaction.hash]],
    ['eth_getTransactionReceipt', [ob.transaction.hash]],
    call(MANAGER, 'tokens(address)', addressWord(token), at),
    call(MANAGER, 'vaultOf(address)', addressWord(token), at),
    call(MANAGER, 'founderRound(address)', addressWord(token), at),
    call(MANAGER, 'signer()', '', before),
    call(MANAGER, 'POOL_FEE()', '', before),
    call(MANAGER, 'LAUNCH_FACTORY()', '', before),
  ]);
  for (const x of r) assert.ok(!(x instanceof Error), String(x));
  assert.equal(r[0], '0xc4');
  const tx = r[1] as Record<string, string>;
  for (const key of ['from', 'to', 'value', 'input', 'nonce', 'blockNumber', 'r', 's', 'yParity']) assert.equal(tx[key], ob.transaction[key], key);
  assert.deepEqual((r[2] as any).logs, ob.receipt.logs);
  assert.equal((r[2] as any).status, '0x1');
  assert.equal(r[3], ob.chain['IgnixManager.tokens(token)']);
  assert.equal(r[4], ob.chain['IgnixManager.vaultOf(token)']);
  assert.equal(r[5], ob.chain['IgnixManager.founderRound(token)']);
  assert.equal(r[6], ob.before['IgnixManager.signer()']);
  assert.equal(r[7], ob.before['IgnixManager.POOL_FEE()']);
  assert.equal(r[8], ob.before['IgnixManager.LAUNCH_FACTORY()']);

  const vault = '0x' + (r[4] as string).slice(26);
  const r2 = await rpc.batch([
    call(vault, 'RECIPIENT()', '', at),
    call(vault, 'TOKEN()', '', at),
    call(vault, 'QUOTE()', '', at),
    call(vault, 'FACTORY()', '', at),
    call(token, 'name()', '', at),
    call(token, 'symbol()', '', at),
    call(token, 'protectionDuration()', '', at),
  ]);
  const keys = ['vault.RECIPIENT()', 'vault.TOKEN()', 'vault.QUOTE()', 'vault.FACTORY()', 'token.name()', 'token.symbol()', 'token.protectionDuration()'];
  r2.forEach((x, i) => assert.equal(x, ob.chain[keys[i]], keys[i]));
});

test(`${corpus.count} real launches: the decoded fields equal what the Manager, the vault and the token report`, { skip: offline }, async () => {
  const launches = corpus.launches as { token: string; hash: string; from: string; input: string }[];
  const decoded = launches.map((l) => decodeCreateToken(l.input));

  const first = await readAll(
    rpc,
    launches.flatMap((l) => [
      mk(MANAGER, 'tokens(address)', addressWord(l.token), (ret) => words(ret)),
      mk(MANAGER, 'vaultOf(address)', addressWord(l.token), decAddress),
      mk(l.token, 'name()', '', decString),
      mk(l.token, 'symbol()', '', decString),
      mk(l.token, 'protectionDuration()', '', decUint),
    ]),
    { chunk: 100 },
  );
  const vaults: string[] = [];
  launches.forEach((l, i) => {
    const c = decoded[i];
    const [t, vault, name, symbol, protection] = first.slice(5 * i, 5 * i + 5) as [bigint[] | Error, string | Error, string | Error, string | Error, bigint | Error];
    for (const x of [t, vault, name, symbol, protection]) assert.ok(!(x instanceof Error), `${l.hash}: ${String(x)}`);
    const w = t as bigint[];
    assert.ok(w.length >= 16, 'tokens() returns at least 16 words');
    assert.equal(addr(w[0]), l.from, `${l.hash}: creator`);
    assert.equal(w[1], BigInt(c.p.buyFeeBps), `${l.hash}: buyFeeBps`);
    assert.equal(w[2], BigInt(c.p.sellFeeBps), `${l.hash}: sellFeeBps`);
    assert.equal(w[3], BigInt(c.p.taxBuyBps), `${l.hash}: taxBuyBps`);
    assert.equal(w[4], BigInt(c.p.taxSellBps), `${l.hash}: taxSellBps`);
    assert.equal(addr(w[5]), c.p.quote, `${l.hash}: quote`);
    assert.equal(w[6], BigInt(c.p.snipeStartBps), `${l.hash}: snipeStartBps`);
    assert.equal(w[7], BigInt(c.p.snipeMins), `${l.hash}: snipeMins`);
    assert.ok(w[8] <= c.deadline, `${l.hash}: created no later than the signed deadline`);
    assert.equal(name, c.p.name, `${l.hash}: name`);
    assert.equal(symbol, c.p.symbol, `${l.hash}: symbol`);
    assert.equal(protection, c.graduationProtectionSecs, `${l.hash}: protection period`);
    vaults.push(vault as string);
  });

  const second = await readAll(
    rpc,
    vaults.flatMap((v) => [mk(v, 'RECIPIENT()', '', decAddress), mk(v, 'QUOTE()', '', decAddress), mk(v, 'FACTORY()', '', decAddress), mk(v, 'TOKEN()', '', decAddress)]),
    { chunk: 100 },
  );
  launches.forEach((l, i) => {
    const c = decoded[i];
    const [recipient, quote, factory, token] = second.slice(4 * i, 4 * i + 4);
    for (const x of [recipient, quote, factory, token]) assert.ok(!(x instanceof Error), `${l.hash}: ${String(x)}`);
    assert.equal(recipient, decodeRecipient(c.vaultData), `${l.hash}: the vault RECIPIENT is the address in vaultData`);
    assert.equal(quote, c.p.quote, `${l.hash}: vault quote`);
    assert.equal(factory, c.factory, `${l.hash}: vault factory`);
    assert.equal(token, l.token, `${l.hash}: vault token`);
  });
});

test('launch-check against the real chain refuses the real OB launch (exit code 1)', { skip: offline }, async () => {
  const tx = ob.transaction;
  const cli = fileURLToPath(new URL('../launch-check.ts', import.meta.url));
  const out = await new Promise<{ code: number | null; stdout: string }>((resolve, reject) => {
    const child = spawn(process.execPath, [cli, '--from', tx.from, '--to', tx.to, '--value', tx.value, '--data', tx.input, '--kernel', '0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404'], { stdio: ['ignore', 'pipe', 'inherit'] });
    let stdout = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout }));
  });
  assert.equal(out.code, 1);
  assert.match(out.stdout, /^PASS  RPC endpoint is X Layer \(chain id 196\): 196$/m);
  assert.match(out.stdout, /^FAIL  firstBuy is 0 \(no team buy\): 0\.4 OKB/m);
  assert.match(out.stdout, /^FAIL  anti-snipe is off/m);
  assert.match(out.stdout, /^FAIL  signature deadline has at least 3 minutes left: expired/m);
  assert.match(out.stdout, /^FAIL  kernel address has code: 0 bytes/m);
  // the platform signer has not been rotated since that launch, so the old signature still verifies
  assert.match(out.stdout, /platform signature is valid for this launcher and this calldata: signed by 0x6EFa1Fad18900B929Fe6782fd3eaBeac2563416A/);
  assert.match(out.stdout, /DO NOT SIGN/);
});
