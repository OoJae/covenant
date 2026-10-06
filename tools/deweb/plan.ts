#!/usr/bin/env node
// plan.ts: prints the ordered transactions that publish a site directory into the DeWEB container of one
// TapeOut circuit on X Layer. It reads the chain (eth_call only) and sends nothing.
//
//   node tools/deweb/plan.ts --processor 0x<Circuits address> --circuit <id> [--dir web/dist]
//
// Run with --help for every option. The transactions themselves are sent by the forge script
// tools/deweb/sim/script/Publish.s.sol, which builds the same list (checked by test/plan-vs-fork.test.ts).

import { writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { toBytes } from '../../packages/chain/src/index.ts';
import { keccak256Hex } from '../../packages/chain/src/keccak.ts';
import { XLAYER, assumeFresh, canEdit, createReader, inspect, type Target } from './src/chain.ts';
import { DEFAULT_OPTIONS, EMPTY_SITE, KIND_NUMBER, buildPlan, okb, readOnChainSite, staleFiles, totalsOf, type OnChainSite, type Options, type Step } from './src/plan.ts';
import { chunkCountOf, isUnknownType, loadSite, type SiteFile } from './src/site.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_DIR = resolve(HERE, '../../web/dist');

const HELP = `plan.ts: the transactions that publish a site into a TapeOut circuit's DeWEB container (X Layer).
Reads the chain with eth_call. Sends nothing, needs no key.

  node tools/deweb/plan.ts --processor <address> --circuit <id> [options]

  --processor <address>      the processor: address of its Circuits contract            (required)
  --circuit <id>             the circuit whose container receives the site              (required)
  --dir <path>               site directory (default: ${DEFAULT_DIR})
  --months <n>               months of name activation to pay if the container is not activated;
                             0 = do not pay (default 1)
  --renew                    pay for --months more even if it is already activated
  --fallback <path>          make <path> the site's fallback for unknown paths without an extension
  --prune                    remove on-chain files that are not in the directory
  --from <address>           the account that will send; checked against the circuit's holder
  --processor-number <n>     the processor's index in the factory (otherwise found by scanning)
  --assume-fresh             do not read the chain: plan for a container that was never opened, with the
                             fees as read on 2026-10-04. Needs --processor-number and --from
  --rpc <url[,url]>          JSON-RPC endpoints (default: ${XLAYER.rpc.join(', ')})
  --block <n>                read at this block instead of the head minus 2
  --timeout <seconds>        per JSON-RPC request (default 20; a local fork that fetches lazily may need more)
  --gas-price-gwei <x>       gas price for the cost column (default 0.02, X Layer's base fee)
  --json <file>              also write the plan as JSON ("-" = standard output, nothing else printed)
  --help
`;

function fail(message: string): never {
  console.error(`plan.ts: ${message}`);
  process.exit(2);
}

const isAddress = (s: string | undefined): s is string => typeof s === 'string' && /^0x[0-9a-fA-F]{40}$/.test(s);

/** Gwei as a decimal string to wei, exactly. */
function gweiToWei(text: string): bigint {
  if (!/^\d+(\.\d{1,9})?$/.test(text)) fail(`--gas-price-gwei: not a number with at most 9 decimals: ${text}`);
  const [whole, frac = ''] = text.split('.');
  return BigInt(whole) * 1_000_000_000n + BigInt(frac.padEnd(9, '0'));
}

const n = (v: number | bigint): string => v.toLocaleString('en-US');
const TARGET_NAMES: Record<string, string> = {
  [XLAYER.opener.toLowerCase()]: 'container opener',
  [XLAYER.registry.toLowerCase()]: 'SiteRegistry',
  [XLAYER.binding.toLowerCase()]: 'DomainBinding',
};

function describeSite(dir: string, files: readonly SiteFile[]): string[] {
  const bytes = files.reduce((s, f) => s + f.data.length, 0);
  const chunks = files.reduce((s, f) => s + chunkCountOf(f.data.length), 0);
  const out = [`Site directory   ${dir}`, `                 ${files.length} files, ${n(bytes)} bytes, ${chunks} chunks of at most 24,000 bytes`];
  for (const f of files) out.push(`                   ${f.path}  ${n(f.data.length)} bytes  ${f.contentType}  sha256 ${f.sha256}`);
  return out;
}

function describeTarget(t: Target, assumed: boolean): string[] {
  const until = t.paidUntil ? new Date(t.paidUntil * 1000).toISOString() : 'never paid';
  return [
    `Processor        ${t.processor}  number ${t.processorNumber}${t.processorName ? `  "${t.processorName}"` : ''}`,
    `Circuit          ${t.circuitId}, held by ${t.holder}`,
    `Container        ${t.container}`,
    `                 ${t.opened ? 'opened' : 'NOT opened'}; name ${t.live ? `activated until ${until}` : `NOT activated (${until})`}`,
    `On-chain name    ${t.name}`,
    `Gateway          https://${t.host}.${XLAYER.gateway}/   (status: /.tape/status)`,
    `Fees             open ${okb(t.openFee)} OKB once; name ${okb(t.monthlyFee)} OKB per 30 days`,
    assumed ? 'Chain state      NOT READ (--assume-fresh): a container never opened, fees as read on 2026-10-04' : `Chain state      read at block ${n(t.block ?? 0)}`,
  ];
}

function describeStep(i: number, s: Step, gasPrice: bigint): string[] {
  const rough = s.gasIsRough ? ' (rough)' : '';
  return [
    `${String(i + 1).padStart(3)}. ${s.fn}`,
    `     to        ${s.target}  (${TARGET_NAMES[s.target.toLowerCase()] ?? 'unknown'})`,
    `     arguments ${s.args}`,
    `     value ${okb(s.value)} OKB | calldata ${n((s.data.length - 2) / 2)} bytes | estimated gas ${n(s.gas)}${rough} | estimated gas cost ${okb(BigInt(s.gas) * gasPrice)} OKB`,
  ];
}

async function main(): Promise<void> {
  const { values: a } = parseArgs({
    options: {
      processor: { type: 'string' },
      circuit: { type: 'string' },
      dir: { type: 'string' },
      months: { type: 'string' },
      renew: { type: 'boolean' },
      fallback: { type: 'string' },
      prune: { type: 'boolean' },
      from: { type: 'string' },
      'processor-number': { type: 'string' },
      'assume-fresh': { type: 'boolean' },
      rpc: { type: 'string' },
      block: { type: 'string' },
      timeout: { type: 'string' },
      'gas-price-gwei': { type: 'string' },
      json: { type: 'string' },
      help: { type: 'boolean' },
    },
    strict: true,
  });
  if (a.help) {
    console.log(HELP);
    return;
  }
  if (!isAddress(a.processor)) fail('--processor must be a 0x address (the processor\'s Circuits contract). See --help.');
  if (!a.circuit || !/^[1-9][0-9]*$/.test(a.circuit)) fail('--circuit must be a positive integer. See --help.');
  if (a.from !== undefined && !isAddress(a.from)) fail('--from must be a 0x address');
  const circuitId = BigInt(a.circuit);
  const processorNumber = a['processor-number'] === undefined ? undefined : Number(a['processor-number']);
  if (processorNumber !== undefined && (!Number.isInteger(processorNumber) || processorNumber < 0)) fail('--processor-number must be a non-negative integer');
  const options: Options = {
    months: a.months === undefined ? DEFAULT_OPTIONS.months : Number(a.months),
    renew: a.renew ?? false,
    fallbackPath: a.fallback ?? '',
    prune: a.prune ?? false,
  };
  const gasPrice = gweiToWei(a['gas-price-gwei'] ?? '0.02');
  const dir = resolve(a.dir ?? DEFAULT_DIR);
  const quiet = a.json === '-';
  const say = (line: string = ''): void => {
    if (!quiet) console.log(line);
  };

  let files: SiteFile[];
  try {
    files = loadSite(dir);
  } catch (e) {
    fail(`${(e as Error).message}${a.dir ? '' : '\n(the default directory is the web build output; build the site first or pass --dir)'}`);
  }

  let target: Target;
  let onChain: OnChainSite = EMPTY_SITE;
  const notes: string[] = [];
  if (a['assume-fresh']) {
    if (processorNumber === undefined || !a.from) fail('--assume-fresh needs --processor-number and --from (nothing is read from the chain)');
    target = assumeFresh(a.processor, circuitId, processorNumber, a.from);
  } else {
    if (a.timeout !== undefined && !/^[1-9][0-9]*$/.test(a.timeout)) fail('--timeout must be a whole number of seconds');
    const reader = await createReader(a.rpc ? a.rpc.split(',') : XLAYER.rpc, a.block === undefined ? undefined : Number(a.block), a.timeout === undefined ? 20_000 : Number(a.timeout) * 1000);
    target = await inspect(reader, a.processor, circuitId, processorNumber);
    onChain = await readOnChainSite(reader, target, files);
    if (a.from) {
      const holds = target.holder.toLowerCase() === a.from.toLowerCase();
      const may = target.opened ? await canEdit(reader, target.container, a.from) : holds;
      if (!may) notes.push(`REFUSED ON CHAIN: ${a.from} may not write to this container. The circuit is held by ${target.holder}. Every write would revert with NotOwner().`);
      else if (!holds) notes.push(`${a.from} is not the holder but may write files as an operator. Only the holder can call bind.`);
    } else {
      notes.push(`No --from given: the transactions must be sent by the circuit's holder, ${target.holder}.`);
    }
    if (!target.implementationsAccepted) {
      notes.push('The SiteRegistry or DomainBinding implementation is not the one the official gateway accepts: tapekit.org answers "store-changed" for every X Layer site until the gateway is updated.');
    }
  }

  let steps: Step[];
  try {
    steps = buildPlan(target, files, options, onChain);
  } catch (e) {
    fail((e as Error).message);
  }
  const totals = totalsOf(steps, gasPrice);

  const unknown = files.filter((f) => isUnknownType(f.path)).map((f) => f.path);
  if (unknown.length) notes.push(`Unknown file extension, declared as application/octet-stream (a browser will not run or render it): ${unknown.join(', ')}`);
  const identical = files.filter((f) => onChain.identical.has(f.path)).map((f) => f.path);
  if (identical.length) notes.push(`Already on chain byte for byte, not sent again: ${identical.join(', ')}`);
  const stale = staleFiles(files, onChain);
  if (stale.length && !options.prune) notes.push(`On chain but not in the directory (kept; pass --prune to remove them): ${stale.join(', ')}`);
  if (options.months === 0 && !target.live) notes.push('--months 0 and the name is not activated: the official gateway answers HTTP 402 until bind is paid.');
  if (target.live && !options.renew && options.months !== 0) notes.push('The name is already activated: no bind in this plan (pass --renew to extend it).');
  if (steps.some((s) => s.gasIsRough)) notes.push('Gas marked (rough) is for a call that replaces or removes existing data; it can be off by a quarter.');

  say('DeWEB publication plan (nothing is sent)');
  say();
  for (const line of describeSite(dir, files)) say(line);
  for (const line of describeTarget(target, a['assume-fresh'] ?? false)) say(line);
  say();
  say(`Transactions, in order: ${steps.length}`);
  steps.forEach((s, i) => describeStep(i, s, gasPrice).forEach((l) => say(l)));
  if (steps.length === 0) say('  none: the container already holds this site.');
  say();
  say('TOTAL');
  say(`  transactions (one signature each)   ${totals.transactions}`);
  say(`  calldata                            ${n(steps.reduce((s, x) => s + (x.data.length - 2) / 2, 0))} bytes`);
  say(`  estimated gas                       ${n(totals.gas)}`);
  say(`  estimated gas cost at ${a['gas-price-gwei'] ?? '0.02'} gwei     ${okb(totals.gasCost)} OKB`);
  say(`  fees paid to the protocol           ${okb(totals.value)} OKB`);
  say(`  estimated total                     ${okb(totals.total)} OKB`);
  if (notes.length) {
    say();
    say('Notes');
    for (const note of notes) say(`  - ${note}`);
  }

  if (a.json !== undefined) {
    const json = JSON.stringify(
      {
        siteDir: dir,
        target: { ...target, circuitId: target.circuitId.toString(), openFee: target.openFee.toString(), monthlyFee: target.monthlyFee.toString() },
        assumed: a['assume-fresh'] ?? false,
        options,
        files: files.map((f) => ({ path: f.path, contentType: f.contentType, sha256: f.sha256, bytes: f.data.length, chunks: chunkCountOf(f.data.length) })),
        steps: steps.map((s) => ({
          kind: s.kind,
          kindNumber: KIND_NUMBER[s.kind],
          target: s.target,
          function: s.fn,
          arguments: s.args,
          label: s.label,
          value: s.value.toString(),
          calldataBytes: (s.data.length - 2) / 2,
          calldataHash: keccak256Hex(toBytes(s.data)),
          gas: s.gas,
          gasIsRough: s.gasIsRough,
          data: s.data,
        })),
        totals: { transactions: totals.transactions, gas: totals.gas, gasPriceWei: gasPrice.toString(), gasCost: totals.gasCost.toString(), value: totals.value.toString(), total: totals.total.toString() },
        notes,
      },
      null,
      2,
    );
    if (quiet) console.log(json);
    else writeFileSync(a.json, json + '\n');
  }
}

main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
