#!/usr/bin/env node
// audit-team: every transaction ever sent by each declared team wallet, classified.
//
//   node tools/audit-team/audit-team.ts [--wallet <address>]... [--wallets-file docs/WALLETS.md]
//        [--addresses tools/audit-team/addresses.json] [--deployment <deployment json>] [--rpc <url>]
//        [--block <number>] [--max-nonces <n>] [--out <directory>] [--no-cache] [--quiet]
//
// The wallets are the table of docs/WALLETS.md, the deployer, the keeper, and every wallet the on-chain
// TeamRegistry lists (count / at) when its address is known; --wallet replaces them all.
// It uses only a public archive JSON-RPC endpoint (no explorer API, no key) and only read calls.
// Exit code 0: every rule was checked and none was broken. 1: at least one rule was broken.
// 2: nothing was flagged but the audit could not be completed (it is then NOT a clean result).

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { UsageError, parseFlags } from '../launch-check/args.ts';
import { parseAddress } from '../launch-check/hex.ts';
import { runAudit, type AuditResult } from './audit.ts';
import { Chain, DEFAULT_RPCS } from './chain.ts';
import { DeploymentError, loadDeployment } from '../launch-check/deployment.ts';
import { ConfigError, loadKnown, parseWalletsTable, withDeployment, type Wallet } from './known.ts';
import { RegistryError, withRegistry } from './registry.ts';
import { renderMarkdown, toJson } from './report.ts';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');

const USAGE = `audit-team: lists and classifies every transaction ever sent by each declared team wallet.

  node tools/audit-team/audit-team.ts [options]

  --wallet <address>      a wallet to audit (may be repeated). Without it, the wallets are the table in
                          docs/WALLETS.md, the deployer, and every wallet the TeamRegistry lists on-chain
  --wallets-file <path>   another markdown file with a wallets table (default docs/WALLETS.md)
  --addresses <path>      the known addresses (default tools/audit-team/addresses.json)
  --deployment <path>     the deployment record, deployments/xlayer.json (or the deploy/rehearsal.json format):
                          it fills in the Covenant addresses addresses.json leaves null (TeamRegistry, keeper,
                          transistors, kernels, ...). Session 2 (evaluator, core, flagship) may be absent
  --rpc <url>             an X Layer archive JSON-RPC endpoint (default rpc.xlayer.tech, then xlayerrpc.okx.com)
  --block <number>        audit the state at this block (default: the latest block)
  --max-nonces <n>        look only at the first n nonces of each wallet (the result is then never "clean")
  --out <directory>       where audit.md and audit.json are written (default tools/audit-team/out)
  --no-cache              do not read or write tools/audit-team/cache
  --quiet                 print only the verdict lines, not the tables

Exit code 0: clean. 1: at least one rule was broken. 2: not flagged, but the audit could not be completed.`;

const FLAGS = {
  wallet: 'list',
  'wallets-file': 'value',
  addresses: 'value',
  deployment: 'value',
  rpc: 'value',
  block: 'value',
  'max-nonces': 'value',
  out: 'value',
  'no-cache': 'flag',
  quiet: 'flag',
  help: 'flag',
} as const;

const positive = (s: string, what: string): number => {
  if (!/^[1-9][0-9]*$/.test(s)) throw new UsageError(`${what}: "${s}" is not a positive whole number`);
  return Number(s);
};

export interface Plan {
  wallets: Wallet[];
  pending: string[];
}

/** The wallets to audit: the --wallet flags, or the table of the wallets file. */
export function planWallets(flagList: string | undefined, walletsFile: string): Plan {
  if (flagList !== undefined) {
    const wallets: Wallet[] = [];
    for (const raw of flagList.split(',')) {
      const address = parseAddress(raw, '--wallet');
      if (!wallets.some((w) => w.address === address)) wallets.push({ address, role: 'given with --wallet' });
    }
    return { wallets, pending: [] };
  }
  let text: string;
  try {
    text = readFileSync(walletsFile, 'utf8');
  } catch (e) {
    throw new UsageError(`cannot read the wallets file ${walletsFile}: ${(e as Error).message}`);
  }
  const { wallets, pending } = parseWalletsTable(text);
  if (!wallets.length) throw new UsageError(`${walletsFile} declares no wallet address`);
  return { wallets, pending };
}

async function main(argv: readonly string[]): Promise<number> {
  let result: AuditResult;
  let outDir: string;
  let quiet = false;
  try {
    const flags = parseFlags(argv, FLAGS);
    if (flags.has('help')) {
      console.log(USAGE);
      return 0;
    }
    quiet = flags.has('quiet');
    const plan = planWallets(flags.get('wallet'), resolve(process.cwd(), flags.get('wallets-file') ?? join(REPO, 'docs/WALLETS.md')));
    let known = loadKnown(resolve(process.cwd(), flags.get('addresses') ?? join(HERE, 'addresses.json')));
    if (flags.has('deployment')) {
      try {
        known = withDeployment(known, loadDeployment(flags.get('deployment') as string));
      } catch (e) {
        if (e instanceof DeploymentError) throw new ConfigError(e.message);
        throw e;
      }
    }
    outDir = resolve(process.cwd(), flags.get('out') ?? join(HERE, 'out'));
    const chain = new Chain({
      urls: flags.has('rpc') ? [flags.get('rpc') as string] : DEFAULT_RPCS,
      cachePath: flags.has('no-cache') ? null : join(HERE, 'cache', 'chain-196.json'),
      block: flags.has('block') ? positive(flags.get('block') as string, '--block') : undefined,
    });
    await chain.open();
    try {
      const byHand = flags.has('wallet');
      const { wallets, view } = byHand ? { wallets: plan.wallets, view: null } : await withRegistry(chain, known, plan.wallets);
      if (view) console.error(`TeamRegistry ${view.address}: ${view.entries.length} wallet(s) listed`);
      result = await runAudit(chain, known, wallets, {
        maxNonces: flags.has('max-nonces') ? positive(flags.get('max-nonces') as string, '--max-nonces') : undefined,
        pendingRoles: plan.pending,
        log: (m) => console.error(m),
        registry: view,
        walletsByHand: byHand,
      });
    } finally {
      chain.save();
    }
  } catch (e) {
    const usage = e instanceof UsageError || e instanceof ConfigError || e instanceof RegistryError;
    console.error(`audit-team could not ${usage ? 'run' : 'complete the audit'}: ${e instanceof Error ? e.message : String(e)}`);
    console.error('No verdict was reached. This is NOT a clean result.');
    return 2;
  }

  const markdown = renderMarkdown(result);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'audit.md'), markdown);
  writeFileSync(join(outDir, 'audit.json'), toJson(result) + '\n');
  if (quiet) {
    const start = markdown.indexOf('## Verdict');
    console.log(markdown.slice(start));
  } else {
    console.log(markdown);
  }
  console.error(`written: ${join(outDir, 'audit.md')} and ${join(outDir, 'audit.json')}  (${result.stats.httpRequests} HTTP requests, ${result.stats.calls} RPC calls, ${result.stats.cacheHits} answers from the cache)`);
  return result.exitCode;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      console.error(`audit-team failed unexpectedly: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
      console.error('No verdict was reached. This is NOT a clean result.');
      process.exitCode = 2;
    },
  );
}

export { existsSync };
