// deploy/publish-site.sh end to end, on a local fork of X Layer, in a scratch clone of the repository.
//
//   PUBLISH_E2E=1 node --test tools/deweb/test/publish-site.e2e.test.ts          (about 6 to 10 minutes)
//
// The scratch clone gets the working-tree versions of the wrapper, tools/deweb and deployments/xlayer.json, is
// committed and pushed to a scratch bare `origin`, so the wrapper's "clean and pushed" checks pass honestly there.
// Only in that clone, the wrapper is changed in four places: forge signs with --unlocked instead of the keystore,
// the RPC may be the local fork (http), and the two live checks a fork cannot answer are left out (a second node
// operator, the official gateway). A local anvil fork of X Layer plays mainnet; it impersonates every sender.
//
// Scenarios, in order:
//   1. rehearsal only: plan and rehearsal printed, nothing sent;
//   2. an earlier run that stopped after its first transaction (the container opened, the record says so):
//      --broadcast sends only the rest, records .site with every transaction of both runs;
//   3. a second --broadcast sends nothing;
//   4. an unsigned leftover record (forge stopped at the password prompt) is set aside, nothing is sent;
//   5. a record with a signed transaction that is not on chain stops everything;
//   6. a change in web/ that is not committed is refused.
// Nothing here reaches a real network except the fork's reads of X Layer.

import assert from 'node:assert/strict';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { appendFileSync, cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const DEPLOYER = '0x84cE7bAe1b788C7aD985D57721cA428b401aE34D';
const OPENER = '0x536adD8F30f03b69f6fbF29d425A816A0dC50106';
const BINDING = '0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9';
const UPSTREAM = process.env.XLAYER_RPC_URL ?? 'https://rpc.xlayer.tech';

const has = (cmd: string): boolean => spawnSync('/usr/bin/env', ['which', cmd]).status === 0;
const skip =
  process.env.PUBLISH_E2E !== '1'
    ? 'set PUBLISH_E2E=1 to run (about 6 to 10 minutes)'
    : !['anvil', 'forge', 'cast', 'jq', 'rsync', 'git'].every(has)
      ? 'anvil, forge, cast, jq, rsync and git are needed'
      : false;

let dir = '';
let anvil: ChildProcess | undefined;
let transcript = '';
after(() => {
  anvil?.kill();
  if (dir && process.env.KEEP_E2E !== '1') rmSync(dir, { recursive: true, force: true });
});

const sh = (cmd: string, args: string[], cwd: string, env: NodeJS.ProcessEnv = process.env): string => {
  const r = spawnSync(cmd, args, { cwd, env, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')} failed (${r.status}): ${r.stdout}\n${r.stderr}`);
  return r.stdout.trim();
};
const run = (cwd: string, args: string[], env: NodeJS.ProcessEnv, title: string): Promise<{ code: number | null; out: string }> =>
  new Promise((resolve, reject) => {
    const child = spawn('bash', ['deploy/publish-site.sh', ...args], { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) => {
      appendFileSync(transcript, `\n$ ${title}\n${out}(exit code ${code})\n`);
      resolve({ code, out });
    });
  });
const freePort = (): Promise<number> =>
  new Promise((resolve) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });

test('deploy/publish-site.sh: rehearse, resume a partial run, send, rerun sends nothing, recover an unsigned record', { skip, timeout: 3_600_000 }, async (t) => {
  dir = mkdtempSync(join(tmpdir(), 'publish-site-e2e-'));
  transcript = process.env.E2E_TRANSCRIPT ?? join(dir, 'transcript.txt');
  writeFileSync(transcript, `deploy/publish-site.sh end to end, ${new Date().toISOString()}\n`);
  t.diagnostic(`transcript: ${transcript}`);

  // ── the scratch clone, committed and pushed to a scratch origin
  const clone = join(dir, 'repo');
  const origin = join(dir, 'origin.git');
  sh('git', ['clone', '--quiet', REPO, clone], dir);
  sh('git', ['init', '--quiet', '--bare', origin], dir);
  sh('git', ['remote', 'set-url', 'origin', origin], clone);
  // the working-tree versions of what this test is about (not committed in the repository yet)
  cpSync(join(REPO, 'deploy/publish-site.sh'), join(clone, 'deploy/publish-site.sh'));
  // HEAD's site fails its own budget while deployments/xlayer.json carries the Architect's endpoint URLs
  // (web/src/config.ts bundles the whole file; web/scripts/check-budget.mjs refuses unknown hosts). In the clone only,
  // those two URLs are left out so that the site builds; the wrapper itself is not changed for this.
  const record = JSON.parse(readFileSync(join(REPO, 'deployments/xlayer.json'), 'utf8'));
  if (record.architect) {
    delete record.architect.endpoint;
    delete record.architect.freeEndpoint;
  }
  writeFileSync(join(clone, 'deployments/xlayer.json'), JSON.stringify(record, null, 2) + '\n');
  rmSync(join(clone, 'tools/deweb'), { recursive: true, force: true });
  cpSync(join(REPO, 'tools/deweb'), join(clone, 'tools/deweb'), { recursive: true, filter: (src) => !/\/tools\/deweb\/(research|sim\/broadcast)(\/|$)/.test(src) });
  // dependencies, ignored by git: copied as they are
  for (const nm of ['node_modules', 'web/node_modules', 'tools/node_modules', ...readdirSync(join(REPO, 'packages')).map((p) => `packages/${p}/node_modules`)]) {
    if (existsSync(join(REPO, nm))) sh('rsync', ['-a', join(REPO, nm) + '/', join(clone, nm) + '/'], dir);
  }
  // the four changes that make the wrapper usable on a fork, in the clone only
  const wrapper = join(clone, 'deploy/publish-site.sh');
  let text = readFileSync(wrapper, 'utf8');
  const patch = (from: string, to: string): void => {
    assert.ok(text.includes(from), `the wrapper still contains: ${from}`);
    text = text.replace(from, to);
  };
  patch('--account "$ACCOUNT"', '--unlocked');
  patch('  https://*) ;;', '  https://* | http://127.0.0.1:*) ;;');
  patch('LIVE_VERIFY_OPTS=()', 'LIVE_VERIFY_OPTS=(--second-rpc none --timeout 180)');
  patch('GATEWAY_CHECK=yes', 'GATEWAY_CHECK=no');
  writeFileSync(wrapper, text);
  sh('git', ['add', '-A'], clone);
  sh('git', ['-c', 'user.name=e2e', '-c', 'user.email=e2e@localhost', 'commit', '--quiet', '-m', 'scratch: the working tree under test'], clone);
  sh('git', ['push', '--quiet', 'origin', 'HEAD:main'], clone);
  sh('git', ['fetch', '--quiet', 'origin'], clone);
  assert.equal(sh('git', ['status', '--porcelain'], clone), '', 'the scratch clone is clean');

  // ── the fork that plays X Layer mainnet
  const port = await freePort();
  const rpc = `http://127.0.0.1:${port}`;
  anvil = spawn('anvil', ['--fork-url', UPSTREAM, '--port', String(port), '--auto-impersonate', '--silent', '--retries', '20', '--fork-retry-backoff', '1000', '--timeout', '60000'], { stdio: 'ignore' });
  for (let i = 0; ; i++) {
    try {
      if (sh('cast', ['chain-id', '--rpc-url', rpc], dir) === '196') break;
    } catch {
      if (i > 120) throw new Error('the fork did not start');
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  const cast = (...args: string[]): string => sh('cast', [...args, '--rpc-url', rpc], dir);
  const live = JSON.parse(readFileSync(join(clone, 'deployments/xlayer.json'), 'utf8'));
  const circuits = live.issuance.circuits as string;
  const circuitId = String(live.probe.circuitId);
  const container = cast('call', OPENER, 'accountOf(address,uint256)(address)', circuits, circuitId);
  assert.equal(cast('call', OPENER, 'isOpened(address,uint256)(bool)', circuits, circuitId), 'false', 'on mainnet the container is not opened yet');
  const env = { ...process.env, XLAYER_RPC_URL: rpc };
  for (const k of Object.keys(env)) if (/^(FOUNDRY_|DAPP_)/.test(k) || k === 'COVENANT_FORK') delete env[k];
  const nonce = (): number => Number(cast('nonce', DEPLOYER));
  const records = join(clone, 'tools/deweb/sim/broadcast/Publish.s.sol/196');

  // 1. rehearsal only
  const n0 = nonce();
  const r1 = await run(clone, [], env, 'deploy/publish-site.sh   (rehearsal only)');
  assert.equal(r1.code, 0, r1.out);
  assert.match(r1.out, /Transactions, in order|transactions \(one signature each\)/);
  assert.match(r1.out, /rehearsal: (\d+) transaction\(s\), [0-9.e-]+ OKB in fees and gas; the site reads back byte for byte from the fork/);
  assert.match(r1.out, /rehearsal only\. To send it: deploy\/publish-site\.sh --broadcast/);
  assert.equal(nonce(), n0, 'nothing was sent');
  const planned = Number(/rehearsal: (\d+) transaction/.exec(r1.out)?.[1]);
  assert.ok(planned >= 3, 'open, the files, bind');

  // 2. an earlier run that stopped after its first transaction: the container was opened, the record says so
  const fee = cast('call', OPENER, 'FEE()(uint256)').split(' ')[0];
  const openTx = JSON.parse(sh('cast', ['send', OPENER, 'open(address,uint256)', circuits, circuitId, '--value', fee, '--from', DEPLOYER, '--unlocked', '--json', '--rpc-url', rpc], dir)).transactionHash as string;
  sh('mkdir', ['-p', records], dir);
  const partial = { transactions: [{ hash: openTx, function: 'open(address,uint256)', transaction: { from: DEPLOYER, to: OPENER } }, { hash: null, function: 'putFile(address,string,string,bytes32,bytes)', transaction: { from: DEPLOYER } }] };
  writeFileSync(join(records, 'run-1791000000000.json'), JSON.stringify(partial));
  writeFileSync(join(records, 'run-latest.json'), JSON.stringify(partial));
  const n1 = nonce();
  const r2 = await run(clone, ['--broadcast'], env, 'deploy/publish-site.sh --broadcast   (after a partial run: the container is already opened)');
  assert.equal(r2.code, 0, r2.out);
  assert.match(r2.out, /BROADCAST: (\d+) transaction\(s\)/);
  const sent = nonce() - n1;
  assert.equal(sent, planned - 1, 'everything but the opening, which the earlier run did');
  assert.equal(cast('call', OPENER, 'isOpened(address,uint256)(bool)', circuits, circuitId), 'true');
  assert.equal(cast('call', BINDING, 'isContainerLive(address)(bool)', container), 'true', 'the name is active');
  const site = JSON.parse(readFileSync(join(clone, 'deployments/xlayer.json'), 'utf8')).site;
  assert.equal(site.container.toLowerCase(), container.toLowerCase());
  assert.equal(site.name, `${circuitId}.2.283.tape`);
  assert.equal(site.gateway, `https://${circuitId}-2-283.tapekit.org/`);
  assert.equal(site.txs.length, planned, 'the opening of the earlier run and every transaction of this one');
  assert.ok(site.txs.includes(openTx));
  assert.ok(site.files.some((f: { path: string }) => f.path === 'index.html'));
  assert.ok(site.paidUntil > Date.now() / 1000 + 29 * 86_400);
  assert.match(r2.out, /DONE\. https:\/\/1-2-283\.tapekit\.org\//);

  // 3. again: nothing to send
  const n2 = nonce();
  const r3 = await run(clone, ['--broadcast'], env, 'deploy/publish-site.sh --broadcast   (again)');
  assert.equal(r3.code, 0, r3.out);
  assert.match(r3.out, /rehearsal: 0 transaction\(s\)/);
  assert.match(r3.out, /nothing to send: the container already holds this build and the name is active/);
  assert.equal(nonce(), n2, 'nothing was sent');
  assert.deepEqual(JSON.parse(readFileSync(join(clone, 'deployments/xlayer.json'), 'utf8')).site.txs, site.txs, 'the record is unchanged');

  // 4. an unsigned leftover: forge wrote its record, then the password prompt was left with Ctrl-C
  const latest = JSON.parse(readFileSync(join(records, 'run-latest.json'), 'utf8'));
  for (const tx of latest.transactions) tx.hash = null;
  writeFileSync(join(records, 'run-latest.json'), JSON.stringify(latest));
  writeFileSync(join(records, 'run-1799999999999.json'), JSON.stringify(latest));
  const r4 = await run(clone, ['--broadcast'], env, 'deploy/publish-site.sh --broadcast   (an unsigned record is left over)');
  assert.equal(r4.code, 0, r4.out);
  assert.match(r4.out, /an earlier run stopped before signing .* Nothing of it was sent\./);
  assert.match(r4.out, /removing forge's unsigned record/);
  assert.ok(!existsSync(join(records, 'run-1799999999999.json')) && !existsSync(join(records, 'run-latest.json')), 'both copies are set aside');
  assert.equal(nonce(), n2, 'nothing was sent');

  // 5. a signed transaction that is not on chain stops everything
  const ghost = { transactions: [{ hash: '0x' + 'ab'.repeat(32), function: 'putFile(address,string,string,bytes32,bytes)' }] };
  writeFileSync(join(records, 'run-latest.json'), JSON.stringify(ghost));
  const r5 = await run(clone, ['--broadcast'], env, 'deploy/publish-site.sh --broadcast   (a record names a transaction that is not on chain)');
  assert.equal(r5.code, 1);
  assert.match(r5.out, /REFUSED: .*holds a signed transaction that is not on chain yet/);
  rmSync(join(records, 'run-latest.json'));
  assert.equal(nonce(), n2);

  // 6. a change that is not committed
  appendFileSync(join(clone, 'web/index.html'), '\n');
  const r6 = await run(clone, ['--broadcast'], env, 'deploy/publish-site.sh --broadcast   (web/ changed, not committed)');
  assert.equal(r6.code, 1);
  assert.match(r6.out, /REFUSED: the site or the publishing tool differ from HEAD/);
  sh('git', ['checkout', '--', 'web/index.html'], clone);
  assert.equal(nonce(), n2);
});
