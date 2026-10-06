// Re-creates the fixtures in this directory from the chain (read-only JSON-RPC) and from the list of
// Directed launches cached by contracts/probes. Run it only to refresh them:
//
//   node tools/launch-check/test/fixtures/fetch.ts
//
// Everything written here is public chain data. Nothing is sent.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRpc } from '../../../../packages/chain/src/index.ts';
import { MANAGER, selectorOf } from '../../decode.ts';
import { addressWord } from '../../hex.ts';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../../../..');
const rpc = createRpc(['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com']);
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

const OB_TX = '0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1';
const OB_TOKEN = '0x995546dfdf93bef59c35742ab5f4762fbcb8eeee';

const must = async (reqs: readonly (readonly [string, readonly unknown[]])[]): Promise<unknown[]> => {
  const out = await rpc.batch(reqs);
  out.forEach((r, i) => {
    if (r instanceof Error) throw new Error(`${reqs[i][0]} failed: ${r.message}`);
  });
  return out;
};

// ── 1. the OB launch: transaction, receipt, and the chain's view of the token it created
const [tx, receipt] = (await must([
  ['eth_getTransactionByHash', [OB_TX]],
  ['eth_getTransactionReceipt', [OB_TX]],
])) as [Record<string, string>, Record<string, unknown>];

const cached = resolve(repo, 'contracts/probes/vendor-cache/tx-create-OB.json');
if (existsSync(cached)) {
  const theirs = JSON.parse(readFileSync(cached, 'utf8')).result as Record<string, string>;
  for (const key of ['from', 'to', 'value', 'input', 'nonce', 'blockNumber', 'hash']) {
    if (theirs[key] !== tx[key]) throw new Error(`the node's copy of the OB transaction differs from contracts/probes/vendor-cache in "${key}"`);
  }
}

const at = tx.blockNumber; // state after the block that holds the launch
const before = '0x' + (BigInt(tx.blockNumber) - 1n).toString(16);
const call = (to: string, data: string, block: string) => ['eth_call', [{ to, data }, block]] as const;
const [block, tokens, vault, founder, signer, poolFee, launchFactory, registry] = (await must([
  ['eth_getBlockByNumber', [at, false]],
  call(MANAGER, selectorOf('tokens(address)') + addressWord(OB_TOKEN), at),
  call(MANAGER, selectorOf('vaultOf(address)') + addressWord(OB_TOKEN), at),
  call(MANAGER, selectorOf('founderRound(address)') + addressWord(OB_TOKEN), at),
  call(MANAGER, selectorOf('signer()'), before),
  call(MANAGER, selectorOf('POOL_FEE()'), before),
  call(MANAGER, selectorOf('LAUNCH_FACTORY()'), before),
  call(MANAGER, selectorOf('REGISTRY()'), before),
])) as [Record<string, string>, string, string, string, string, string, string, string];
const vaultAddress = '0x' + vault.slice(26);
const [recipient, vToken, vQuote, vFactory, name, symbol, protection, registered, chainId] = (await must([
  call(vaultAddress, selectorOf('RECIPIENT()'), at),
  call(vaultAddress, selectorOf('TOKEN()'), at),
  call(vaultAddress, selectorOf('QUOTE()'), at),
  call(vaultAddress, selectorOf('FACTORY()'), at),
  call(OB_TOKEN, selectorOf('name()'), at),
  call(OB_TOKEN, selectorOf('symbol()'), at),
  call(OB_TOKEN, selectorOf('protectionDuration()'), at),
  call('0x' + registry.slice(26), selectorOf('factoryOf(uint16)') + (3).toString(16).padStart(64, '0'), before),
  ['eth_chainId', []],
])) as string[];

writeFileSync(
  resolve(here, 'ob-launch.json'),
  JSON.stringify(
    {
      source: 'https://rpc.xlayer.tech (read-only), fetched by tools/launch-check/test/fixtures/fetch.ts',
      chainId,
      transaction: tx,
      receipt,
      block: { number: block.number, timestamp: block.timestamp, hash: block.hash },
      // eth_call results at the launch block (after it), raw return data
      chain: {
        'IgnixManager.tokens(token)': tokens,
        'IgnixManager.vaultOf(token)': vault,
        'IgnixManager.founderRound(token)': founder,
        'vault.RECIPIENT()': recipient,
        'vault.TOKEN()': vToken,
        'vault.QUOTE()': vQuote,
        'vault.FACTORY()': vFactory,
        'token.name()': name,
        'token.symbol()': symbol,
        'token.protectionDuration()': protection,
      },
      // eth_call results at the block before the launch: what createToken itself read
      before: {
        'IgnixManager.signer()': signer,
        'IgnixManager.POOL_FEE()': poolFee,
        'IgnixManager.LAUNCH_FACTORY()': launchFactory,
        'IgnixManager.REGISTRY()': registry,
        'VaultRegistry.factoryOf(3)': registered,
      },
    },
    null,
    1,
  ) + '\n',
);
console.log('wrote ob-launch.json');

// ── 2. more real launches: every Directed (template 3) launch known to the probes' cache
const list = resolve(repo, 'contracts/probes/vendor-cache/ignix-directed-launches.json');
if (!existsSync(list)) {
  console.log('contracts/probes/vendor-cache/ignix-directed-launches.json is missing: directed-launches.json was not refreshed');
} else {
  const launches = (JSON.parse(readFileSync(list, 'utf8')).directedLaunches as { tokenAddress: string; createdTx: string; quote: string }[]).filter(
    (l) => /^0x[0-9a-f]{64}$/i.test(l.createdTx),
  );
  // every native-OKB launch, and every fourth ERC-20-quoted one
  const native = launches.filter((l) => /^0x0{40}$/.test(l.quote));
  const erc20 = launches.filter((l) => !/^0x0{40}$/.test(l.quote)).filter((_, i) => i % 4 === 0);
  const picked = [...native, ...erc20];
  const txs: Record<string, unknown>[] = [];
  const indirect: { token: string; hash: string; to: string; selector: string }[] = [];
  for (let o = 0; o < picked.length; o += 10) {
    const part = picked.slice(o, o + 10);
    const got = (await must(part.map((l) => ['eth_getTransactionByHash', [l.createdTx]] as const))) as Record<string, string>[];
    got.forEach((t, i) => {
      const token = part[i].tokenAddress.toLowerCase();
      // Some launches are not a direct call: the creator is a smart account and the transaction is an
      // ERC-4337 EntryPoint.handleOps sent by a bundler. Those are recorded but carry no createToken calldata.
      if (t.to?.toLowerCase() !== MANAGER || !t.input.startsWith(selectorOf('createToken((string,string,string,bytes32,address,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint256,uint256,uint16,uint32,bytes32),uint16,bytes,uint64,address,uint8,uint64,bytes)'))) {
        indirect.push({ token, hash: t.hash, to: t.to, selector: t.input.slice(0, 10) });
      } else {
        txs.push({ token, hash: t.hash, from: t.from, to: t.to, value: t.value, input: t.input, blockNumber: t.blockNumber });
      }
    });
    await sleep(250);
  }
  writeFileSync(
    resolve(here, 'directed-launches.json'),
    JSON.stringify(
      {
        source:
          'createToken transactions of IGNIX Directed launches: hashes from contracts/probes/vendor-cache/ignix-directed-launches.json ' +
          '(IGNIX read-only API, 2026-10-04), transactions from https://rpc.xlayer.tech. All native-OKB launches and every fourth ERC-20-quoted one.',
        count: txs.length,
        notDirectCalls: indirect,
        launches: txs,
      },
      null,
      0,
    ) + '\n',
  );
  console.log(`wrote directed-launches.json (${txs.length} direct createToken transactions; ${indirect.length} launches made through another contract were left out)`);
}
