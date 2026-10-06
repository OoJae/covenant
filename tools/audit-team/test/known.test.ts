// addresses.json, the wallets table of docs/WALLETS.md, and the selector names. Offline.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { planWallets } from '../audit-team.ts';
import { parseDeployment } from '../../launch-check/deployment.ts';
import { COVENANT_CONTRACTS, ConfigError, SEL, TOPIC, parseKnown, parseWalletsTable, selectorName, selectorOf, withDeployment } from '../known.ts';

const repo = fileURLToPath(new URL('../../../', import.meta.url));

test('addresses.json names the fixed contracts and the deployer, and leaves the Covenant contracts null until deployment', () => {
  const text = readFileSync(new URL('../addresses.json', import.meta.url), 'utf8');
  const k = parseKnown(text);
  assert.equal(k.manager, '0x96b51c57e5346d0c0198899243cf851d1e23c309');
  assert.equal(k.tapeoutFactory, '0x1f09daefa827f02cbb40967cc91b259763760761');
  assert.equal(k.router, '0x182a927119d56008d921126764bf884221b10f59');
  assert.equal(k.wokb, '0xe538905cf8410324e03a5a23c1c177a474d59b2b');
  assert.equal(k.usdt0, '0x779ded0c9e1022225f8e0630b35a9b54be713736', 'USD₮0 on X Layer, the quote of kernel v2');
  assert.equal(k.deployer, '0x84ce7bae1b788c7ad985d57721ca428b401ae34d');
  for (const c of COVENANT_CONTRACTS) assert.equal(k[c], null, `covenant.${c} is filled in after deployment`);
  assert.deepEqual([...COVENANT_CONTRACTS], ['splitter', 'keeperTank', 'teamRegistry', 'transistors', 'circuits', 'sealedVM', 'fab', 'kernelFactory', 'lens', 'kernelFactoryV2', 'lensV2']);
  assert.deepEqual(k.kernels, []);
  assert.deepEqual(Object.values(k.other), ['0x8004a169fb4a3325136eb29fa0ceb6d2e539a432']);
  // ERC-4337 EntryPoints and the known smart-wallet implementation (OKX Agentic Wallet)
  assert.deepEqual(k.entryPoints, [
    { address: '0x0000000071727de22e5e9d8baf0edac6f37da032', label: 'EntryPoint v0.7' },
    { address: '0x5ff137d4b0fdcd49dca30c7cf57e578a026d2789', label: 'EntryPoint v0.6' },
  ]);
  assert.match(k.smartWallets['0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4'], /^OKX SmartWalletEntry \(.*OKLink/);
  assert.equal(Object.keys(k.smartWallets).length, 1);
  assert.equal(k.agentWallet, null, 'the agent wallet comes from docs/WALLETS.md and the deployment file');
  const raw = JSON.parse(text);
  assert.match(raw.covenant.comment, /deployments\/xlayer\.json/);
  assert.equal(k.keeper, null, 'the keeper comes from docs/WALLETS.md and the deployment file');
  assert.doesNotMatch(text, /LaunchpadSocket/, 'there is no LaunchpadSocket in the current design');
});

test('deployments/xlayer.json (nested, the live record) fills in the session-1 addresses and the keeper', () => {
  const k = parseKnown(readFileSync(new URL('../addresses.json', import.meta.url), 'utf8'));
  const live = parseDeployment(readFileSync(repo + 'deployments/xlayer.json', 'utf8'), 'deployments/xlayer.json');
  const m = withDeployment(k, live);
  assert.equal(m.keeper, '0x7444ec2a06d3c1070203b76c2c3eee998317c4ff');
  for (const c of ['splitter', 'keeperTank', 'teamRegistry', 'transistors', 'circuits'] as const) assert.match(String(m[c]), /^0x[0-9a-f]{40}$/, c);
  assert.equal(m.deployer, '0x84ce7bae1b788c7ad985d57721ca428b401ae34d');
  assert.equal(m.agentWallet, '0xbe5088307e15aaf8cf0c53bfcc4c612c9ead6da0', 'architect.agentWallet');
});

test('a deployment file fills in the null Covenant addresses; a disagreement is refused', () => {
  const k = parseKnown(readFileSync(new URL('../addresses.json', import.meta.url), 'utf8'));
  const d = parseDeployment(
    '{"forkBlock": null, "deployer": "0x84cE7bAe1b788C7aD985D57721cA428b401aE34D", "commit": "47d4a85c3a5268adce80ecc684418bffbe5a94a9", "splitter": "0xfd73b7bc92cda68ec57799987fd3449ba5dadd88", "circuits": "0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b", "transistors": "0xC372dc307eFE4B551c866A79F582D692A373960A", "keeperTank": "0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e", "teamRegistry": "0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2", "probeCircuitId": 1, "sealedVM": "0x3410db75fd8127837207f80db7cfd68441b43006", "fab": "0x19c248cf463c1e167121e52b77aba7ec68cbe47b", "kernelFactory": "0xdcac8c47af534dc0cde30f60056bce7d63a79afe", "lens": "0xaaa75144304cf81cc7cf513f434e00980d1803ad", "chipId": 2, "kernel": "0x99B767ceaF6c87BaB2f750963F17103240013951", "manifestHash": "0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209", "deployerNonceAfter": 11, "deployerBalanceAfter": "0.519538355380475733"}',
  );
  const m = withDeployment(k, d);
  assert.equal(m.teamRegistry, '0x6f1a330b7ffac901205704eaca8e46ee4091f3a2');
  assert.equal(m.lens, '0xaaa75144304cf81cc7cf513f434e00980d1803ad');
  assert.deepEqual(m.kernels, ['0x99b767ceaf6c87bab2f750963f17103240013951']);
  assert.equal(k.teamRegistry, null, 'the original is not changed');
  assert.throws(() => withDeployment({ ...k, deployer: '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404' }, d), /covenant\.deployer is 0xc12f.*the deployment file .* says 0x84ce/);
});

test('a malformed addresses.json is refused', () => {
  const good = JSON.parse(readFileSync(new URL('../addresses.json', import.meta.url), 'utf8'));
  const variant = (change: (o: any) => void): string => {
    const o = structuredClone(good);
    change(o);
    return JSON.stringify(o);
  };
  assert.throws(() => parseKnown('nope'), ConfigError);
  assert.throws(() => parseKnown(variant((o) => (o.chainId = 1))), /chainId must be 196/);
  assert.throws(() => parseKnown(variant((o) => (o.ignixManagr = o.ignixManager))), /unknown key "ignixManagr"/);
  assert.throws(() => parseKnown(variant((o) => (o.covenant.kernel = []))), /unknown key "covenant\.kernel"/);
  assert.throws(() => parseKnown(variant((o) => (o.wokb = '0xe538905cf8410324e03A5A23C1c177a474D59b2B'))), /wrong EIP-55 checksum/);
  assert.throws(() => parseKnown(variant((o) => (o.covenant.kernels = ['0x12']))), /not a 20-byte hex address/);
  assert.throws(() => parseKnown(variant((o) => delete o.uniswapV2Router)), /uniswapV2Router must be an address/);
  const filled = parseKnown(variant((o) => {
    o.covenant.kernels = ['0x00000000000000000000000000000000c0fe0001'];
    o.covenant.transistors = '0x00000000000000000000000000000000c0fe0003';
    o.covenant.teamRegistry = '0x00000000000000000000000000000000c0fe000a';
    o.other['Some other contract'] = '0x00000000000000000000000000000000c0fe000b';
  }));
  assert.deepEqual(filled.kernels, ['0x00000000000000000000000000000000c0fe0001']);
  assert.equal(filled.transistors, '0x00000000000000000000000000000000c0fe0003');
  assert.equal(filled.teamRegistry, '0x00000000000000000000000000000000c0fe000a');
  assert.equal(filled.other['Some other contract'], '0x00000000000000000000000000000000c0fe000b');
  assert.throws(() => parseKnown(variant((o) => (o.smartWalletImplementations['0x00000000000000000000000000000000c0fe00cc'] = { name: 'x' }))), /must give a "name" and the "source"/);
  assert.throws(() => parseKnown(variant((o) => (o.entryPoints['v0.8'] = '0x12'))), /not a 20-byte hex address/);
  assert.throws(() => parseKnown(variant((o) => (o.covenant.launchpadSocket = null))), /unknown key "covenant\.launchpadSocket"/);
  assert.throws(() => parseKnown(variant((o) => (o.covenant.comment = 5))), /covenant\.comment must be text/);
});

test('the wallets table of docs/WALLETS.md is read: the deployer, and a keeper still to be added', () => {
  const { wallets, pending } = parseWalletsTable(readFileSync(repo + 'docs/WALLETS.md', 'utf8'));
  assert.ok(wallets.some((w) => w.address === '0x84ce7bae1b788c7ad985d57721ca428b401ae34d' && /Deployer/.test(w.role)), 'the deployer is declared');
  for (const w of wallets) assert.match(w.address, /^0x[0-9a-f]{40}$/);
  // The keeper row has no address until the keeper wallet exists; once it has one it is audited like the others.
  assert.ok(pending.includes('Keeper') || wallets.some((w) => /Keeper/.test(w.role)));
});

test('wallet tables: several rows, several addresses in a cell, duplicates, bad checksums', () => {
  const md = [
    '# Team wallets',
    '',
    '| Role | Address | Notes |',
    '|:---|:---:|---|',
    '| Deployer | `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` | deploys |',
    '| Keeper | to be added | settles |',
    '| Donor, launcher | 0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404 and `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` | two in one cell |',
    '',
    'A sentence with 0x1111111111111111111111111111111111111111 outside the table is ignored.',
  ].join('\n');
  const { wallets, pending } = parseWalletsTable(md);
  assert.deepEqual(wallets, [
    { address: '0x84ce7bae1b788c7ad985d57721ca428b401ae34d', role: 'Deployer' },
    { address: '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404', role: 'Donor, launcher' },
  ]);
  assert.deepEqual(pending, ['Keeper']);
  assert.throws(() => parseWalletsTable('| Role | Address |\n|---|---|\n| X | 0x84cE7bAe1b788C7aD985D57721cA428b401aE34d |'), /wrong EIP-55 checksum/);
  assert.deepEqual(parseWalletsTable('no table here'), { wallets: [], pending: [] });
});

test('--wallet flags replace the table', () => {
  const plan = planWallets('0x84cE7bAe1b788C7aD985D57721cA428b401aE34D,0xc12fbf15df59800f39f2ebb34c9cbdce150ae404,0x84ce7bae1b788c7ad985d57721ca428b401ae34d', '/nonexistent');
  assert.deepEqual(plan.wallets.map((w) => w.address), ['0x84ce7bae1b788c7ad985d57721ca428b401ae34d', '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404']);
  assert.throws(() => planWallets('0x1234', '/nonexistent'), /not a 20-byte hex address/);
  assert.throws(() => planWallets(undefined, '/nonexistent/WALLETS.md'), /cannot read the wallets file/);
  assert.equal(planWallets(undefined, repo + 'docs/WALLETS.md').wallets[0].address, '0x84ce7bae1b788c7ad985d57721ca428b401ae34d');
});

test('selectors and topics are computed from signatures and match the values measured on the chain', () => {
  // values recorded in contracts/probes (FINDINGS.md and the interface files), or standard
  assert.equal(SEL.createToken, '0xef44bdf2');
  assert.equal(selectorOf('buyTo(address,uint256,uint256,address)'), '0x9415aa2a');
  assert.equal(selectorOf('claim(address)'), '0x1e83409a');
  assert.equal(selectorOf('claimFor(address,address)'), '0xb4ba9e11');
  assert.equal(selectorOf('creatorOf(address)'), '0xdea5c2e0');
  assert.equal(selectorOf('vaultOf(address)'), '0x0709df45');
  assert.equal(selectorOf('approve(address,uint256)'), '0x095ea7b3');
  assert.equal(selectorOf('transfer(address,uint256)'), '0xa9059cbb');
  assert.equal(SEL.erc1155Transfer, '0xf242432a');
  assert.equal(SEL.erc1155BatchTransfer, '0x2eb2c2d6');
  assert.equal(TOPIC.transfer, '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef');
  assert.equal(TOPIC.approval, '0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925');
  assert.equal(TOPIC.transferSingle, '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62');
  assert.equal(TOPIC.transferBatch, '0x4a39dc06d4c0dbc64b70af90fd698a233a518aa5d07e595d983b8c0526c8f7fb');
  assert.equal(selectorName('0xef44bdf2'), 'createToken');
  assert.equal(selectorName('0x095EA7B3'), 'approve');
  assert.equal(selectorName('0x1e83409a'), 'claim');
  assert.equal(selectorName('0x765e827f'), 'handleOps');
  assert.equal(selectorName(selectorOf('declare(string)')), 'declare');
  assert.equal(selectorName(selectorOf('invite(address)')), 'invite');
  assert.equal(selectorName(selectorOf('settleAndRefund(address)')), 'settleAndRefund');
  assert.equal(selectorName(selectorOf('create((address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address),uint256,bytes32)')), 'create');
  assert.equal(selectorName('0x0c307f76'), null);
});
