#!/usr/bin/env node
// verify.ts: after a publication, reads every file of a site back from X Layer with eth_call, compares it
// with the local build byte for byte, and compares what the official gateway actually serves with the chain.
// Read-only: eth_call, eth_getStorageAt, eth_blockNumber, HTTP GET. Prints MATCH or the first difference.
//
//   node tools/deweb/verify.ts --processor 0x<Circuits address> --circuit <id> [--dir web/dist]
//   node tools/deweb/verify.ts --site 12-2-231 --no-local          (any live site: chain against gateway)
//
// Run with --help for every option. Exit code: 0 everything checked and identical; 1 a difference;
// 2 bad usage or an error; 3 no difference found but a check could not be performed.

import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { decAddress } from '../../packages/chain/src/index.ts';
import { encUintArg } from './src/abi.ts';
import { XLAYER, createReader, inspect, nodeRpc, type Target } from './src/chain.ts';
import { loadSite, type SiteFile } from './src/site.ts';
import {
  COVENANT_NEEDS,
  checkGateway,
  checkResolution,
  checkSecondOperator,
  checkSelfConsistent,
  compareLocalWithChain,
  describeGatewayHttp,
  gatewayOrigin,
  parseSite,
  readChainSite,
  verdictOf,
  type Check,
} from './src/verify.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_DIR = resolve(HERE, '../../web/dist');

const HELP = `verify.ts: is the site on chain the site that was built, and does the gateway serve it? (X Layer, read-only)

  node tools/deweb/verify.ts --processor <address> --circuit <id> [options]
  node tools/deweb/verify.ts --site <id>-2-<processor number> [options]

  --processor <address>      the processor: address of its Circuits contract
  --circuit <id>             the circuit whose container holds the site
  --site <name>              instead of the two above: 12-2-231, 12.2.231.tape or a gateway URL
  --dir <path>               the local build to compare with (default: ${DEFAULT_DIR})
  --no-local                 do not compare with a local build (chain against gateway only)
  --allow-extra              a path on chain that is not in the local build is not a difference
  --no-gateway               do not open the gateway
  --gateway <domain>         gateway domain (default ${XLAYER.gateway}); for a gateway run locally, an origin
                             template such as http://{label}.localhost:8096
  --browser <path>           Chromium-family browser for the gateway check (default: Chrome, Edge or Chromium
                             if installed). It runs headless with a throw-away profile
  --expect-selector <css>    also require the page to render this element, e.g. "#app *" for Covenant's site
  --no-covenant-needs        do not check the gateway's policy against what Covenant's site needs
  --rpc <url[,url]>          JSON-RPC endpoints (default: ${XLAYER.rpc.join(', ')})
  --second-rpc <url>         a node of another operator to cross-check (default ${XLAYER.secondOperatorRpc}; "none" = skip)
  --block <n>                read at this block (default: the lower of the two operators' heads, minus 2)
  --timeout <seconds>        per JSON-RPC request (default 20; a local fork that fetches lazily may need more)
  --json                     print the result as JSON instead of text
  --help
`;

function fail(message: string): never {
  console.error(`verify.ts: ${message}`);
  process.exit(2);
}

const isAddress = (s: string | undefined): s is string => typeof s === 'string' && /^0x[0-9a-fA-F]{40}$/.test(s);

async function headOf(urls: readonly string[]): Promise<number> {
  return Number(BigInt((await nodeRpc(urls, 15_000).send('eth_blockNumber')) as string));
}

async function main(): Promise<void> {
  const { values: a } = parseArgs({
    options: {
      processor: { type: 'string' },
      circuit: { type: 'string' },
      site: { type: 'string' },
      dir: { type: 'string' },
      'no-local': { type: 'boolean' },
      'allow-extra': { type: 'boolean' },
      'no-gateway': { type: 'boolean' },
      gateway: { type: 'string' },
      browser: { type: 'string' },
      'expect-selector': { type: 'string' },
      'no-covenant-needs': { type: 'boolean' },
      rpc: { type: 'string' },
      'second-rpc': { type: 'string' },
      block: { type: 'string' },
      timeout: { type: 'string' },
      json: { type: 'boolean' },
      help: { type: 'boolean' },
    },
    strict: true,
  });
  if (a.help) {
    console.log(HELP);
    return;
  }
  const say = (line: string = ''): void => {
    if (!a.json) console.log(line);
  };
  const urls = a.rpc ? a.rpc.split(',') : [...XLAYER.rpc];
  const secondUrl = a['second-rpc'] === 'none' ? undefined : (a['second-rpc'] ?? XLAYER.secondOperatorRpc);

  // one block for every read; low enough that the second operator has it too
  let block = a.block === undefined ? undefined : Number(a.block);
  let secondNote = '';
  if (block !== undefined && secondUrl) {
    // a block given explicitly (just after a publication): wait up to two minutes for the second operator to have it
    const until = Date.now() + 120_000;
    for (;;) {
      let other = -1;
      try {
        other = await headOf([secondUrl]);
      } catch (e) {
        secondNote = `its head could not be read: ${(e as Error).message}`;
      }
      if (other >= block) {
        secondNote = '';
        break;
      }
      if (Date.now() > until) {
        secondNote ||= `it had not reached block ${block} after two minutes (its head: ${other})`;
        break;
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  if (block === undefined) {
    const head = await headOf(urls);
    let other = head;
    if (secondUrl) {
      try {
        other = await headOf([secondUrl]);
      } catch (e) {
        secondNote = `its head could not be read: ${(e as Error).message}`;
      }
    }
    block = Math.min(head, other) - 2;
  }
  if (a.timeout !== undefined && !/^[1-9][0-9]*$/.test(a.timeout)) fail('--timeout must be a whole number of seconds');
  const reader = await createReader(urls, block, a.timeout === undefined ? 20_000 : Number(a.timeout) * 1000);

  let processor = a.processor;
  let circuit = a.circuit;
  let processorNumber: number | undefined;
  if (a.site !== undefined) {
    if (a.processor || a.circuit) fail('give either --site or --processor with --circuit');
    let parsed;
    try {
      parsed = parseSite(a.site);
    } catch (e) {
      fail((e as Error).message);
    }
    processorNumber = parsed.processorNumber;
    circuit = parsed.circuitId.toString();
    try {
      processor = decAddress(await reader.call(XLAYER.factory, encUintArg('cpuAt', processorNumber)));
    } catch {
      fail(`the factory has no processor number ${processorNumber}`);
    }
  }
  if (!isAddress(processor)) fail('--processor must be a 0x address, or use --site. See --help.');
  if (!circuit || !/^[1-9][0-9]*$/.test(circuit)) fail('--circuit must be a positive integer. See --help.');

  let local: SiteFile[] | undefined;
  let dir = '';
  if (!a['no-local']) {
    dir = resolve(a.dir ?? DEFAULT_DIR);
    if (!a.dir && !existsSync(dir)) fail(`the default build directory ${dir} does not exist. Build the site, pass --dir, or pass --no-local to compare the chain with the gateway only.`);
    try {
      local = loadSite(dir);
    } catch (e) {
      fail((e as Error).message);
    }
  }

  const target: Target = await inspect(reader, processor, BigInt(circuit), processorNumber);
  say('DeWEB verification (read-only)');
  say(`  site         ${target.name}   processor ${target.processor} (number ${target.processorNumber}${target.processorName ? `, "${target.processorName}"` : ''}), circuit ${target.circuitId}`);
  say(`  container    ${target.container}`);
  say(`  read at      block ${block.toLocaleString('en-US')} through ${new URL(reader.rpc.current()).host}`);
  say(`  local build  ${local ? `${dir} (${local.length} files)` : 'not compared (--no-local)'}`);
  say();

  const checks: Check[] = [];
  const chain = await readChainSite(reader, target.container);
  if (local) checks.push(compareLocalWithChain(local, chain, a['allow-extra'] ?? false));
  checks.push(checkSelfConsistent(chain));
  if (secondUrl) {
    checks.push(
      secondNote
        ? { name: `A second node operator (${new URL(secondUrl).host}) returns the same site`, status: 'NOT CHECKED', detail: secondNote, lines: [] }
        : await checkSecondOperator(secondUrl, block, target.container, chain),
    );
  }
  let httpLine = '';
  if (!a['no-gateway']) {
    const resolution = checkResolution(target);
    checks.push(resolution);
    const gateway = a.gateway ?? XLAYER.gateway;
    httpLine = await describeGatewayHttp(`${gatewayOrigin(target, gateway)}/`);
    const served = await checkGateway(target, chain, {
      gateway,
      executable: a.browser,
      expectSelector: a['expect-selector'],
      needs: a['no-covenant-needs'] ? [] : COVENANT_NEEDS,
      local,
    });
    served.lines.unshift(httpLine);
    checks.push(served);
  }

  const omitted: string[] = [];
  if (!local) omitted.push('the comparison with a local build (--no-local)');
  if (!secondUrl) omitted.push('the second node operator (--second-rpc none)');
  if (a['no-gateway']) omitted.push('everything about the gateway (--no-gateway)');
  const verdict = verdictOf(checks, omitted);
  if (a.json) {
    console.log(
      JSON.stringify(
        {
          target: { ...target, circuitId: target.circuitId.toString(), openFee: target.openFee.toString(), monthlyFee: target.monthlyFee.toString() },
          block,
          localDir: local ? dir : null,
          chain: { paths: chain.paths, fallback: chain.fallback, files: chain.files.map((f) => ({ path: f.path, ...f.info, bytesRead: f.data.length, sha256OfBytes: f.sha256, state: f.state })) },
          checks,
          verdict: verdict.status,
          summary: verdict.line,
        },
        null,
        2,
      ),
    );
  } else {
    say(`On chain: ${chain.files.length} files, ${chain.files.reduce((s, f) => s + f.data.length, 0).toLocaleString('en-US')} bytes; fallback path ${chain.fallback ? `"${chain.fallback}"` : 'not set'}`);
    say();
    checks.forEach((c, i) => {
      say(`${i + 1}. ${c.name}`);
      say(`   ${c.status}: ${c.detail}`);
      for (const line of c.lines) say(`     ${line}`);
    });
    say();
    say(`VERDICT: ${verdict.line}`);
  }
  process.exitCode = verdict.exitCode;
}

main().catch((e: unknown) => fail(e instanceof Error ? e.message : String(e)));
