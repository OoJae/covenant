#!/usr/bin/env node
// launch-check: the last check before a human signs IgnixManager.createToken for a Covenant token.
//
//   node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json --tx @tx.json
//   node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json --from <launcher> --to <address> \
//        --value <wei> --data <0x hex | @file> [--kernel <address>] [--expected <json file>] [--rpc <url>]
//
// It decodes the calldata the wallet shows, reads the chain at the latest block (read-only calls) and prints
// one line per check: PASS or FAIL with the decoded value. Exit code 0 only if every check passed.
// A check that could not be performed is a failure. This tool never signs and never sends anything.

import { pathToFileURL } from 'node:url';
import { UsageError, loadExpected, parseFlags, readDeploymentFlag, readTx, withDeployment } from './args.ts';
import { sessionTwoRefusal } from './deployment.ts';
import { DEFAULT_RPCS, connect, readChain } from './chain.ts';
import { calldataLines, chainLines, formatLine, got, missing, verdict, type Expected, type Fact, type Line, type TxInput } from './checks.ts';
import { parseAddress, sameAddress, show } from './hex.ts';

const USAGE = `launch-check: the last check before signing createToken. It never signs and never sends.

  node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json --tx @tx.json
  node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json \\
      --from <launcher address> --to <address> --value <wei> --data <0x hex | @file> \\
      [--kernel <address>] [--expected <json file>] [--circuits <address>] [--rpc <url>] [--json]

  --deployment  the Covenant deployment: deployments/xlayer.json (the mainnet record of the signing sessions)
                or a file in the format of deploy/rehearsal.json. It names the kernel, its KernelFactory, the
                processor's Circuits and Transistors, the Fab and the SealedVM. Refused while signing session 2
                (evaluator, core, flagship) is not recorded in it
  --tx          the eth_sendTransaction parameters {"from","to","value","data"} as JSON, or @file holding them
                (what a hook on the page's window.ethereum.request captures); replaces the next four options
  --from        the wallet that will sign (the launcher)
  --to          the address the wallet says it is interacting with
  --value       the amount the wallet says it sends: wei ("0"), hex wei, or OKB with the unit ("0.4okb")
  --data        the raw hex data of the transaction, or @file holding it (it starts with 0xef44bdf2)
  --kernel      the kernel that must receive the token's tax (default: the deployment's kernel; if both
                are given they must be the same)
  --expected    expected values (see expected.cvref.json). Default: tax 300/300 bps, protection 8,640,000 s
  --circuits    the Covenant processor's Circuits contract, if no file names it
  --rpc         an X Layer JSON-RPC endpoint (default: rpc.xlayer.tech, then xlayerrpc.okx.com)
  --json        print the result as JSON instead of text

Without --deployment the check "kernel was created by the Covenant KernelFactory" cannot be performed,
so the verdict cannot be PASS.

Exit code 0: every check passed. 1: at least one check failed or could not be performed. 2: the tool was called wrongly.`;

const FLAGS = {
  deployment: 'value',
  tx: 'value',
  from: 'value',
  to: 'value',
  value: 'value',
  data: 'value',
  kernel: 'value',
  expected: 'value',
  circuits: 'value',
  rpc: 'value',
  json: 'flag',
  help: 'flag',
} as const;

export interface Report {
  lines: Line[];
  passed: number;
  failed: number;
  ok: boolean;
}

/** The Circuits address to check the chip in: the expected file, the flag, or the reason there is none. */
export function pickCircuits(expected: Expected, flag: string | undefined): Fact<string> {
  let fromFlag: string | null = null;
  if (flag !== undefined) fromFlag = parseAddress(flag, '--circuits');
  if (fromFlag && expected.circuits && !sameAddress(fromFlag, expected.circuits)) {
    return missing(`--circuits ${show(fromFlag)} differs from the Circuits ${show(expected.circuits)} of the deployment / expected-values file`);
  }
  const c = fromFlag ?? expected.circuits;
  return c ? got(c) : missing('no Circuits address was given: pass --deployment (or --circuits)');
}

/** Runs every check. `rpcUrls` are tried in order; `now` (unix seconds) is this machine's clock. */
export async function run(tx: TxInput, expected: Expected, circuits: Fact<string>, rpcUrls: readonly string[], now?: bigint): Promise<Report> {
  const { lines: first, call } = calldataLines(tx, expected);
  const rpc = connect(rpcUrls, { timeout: 20000, retries: 1 });
  const facts = await readChain(rpc, tx, call, circuits, now ?? BigInt(Math.floor(Date.now() / 1000)), expected.kernelFactory);
  const lines = [...first, ...chainLines(tx, call, expected, facts)];
  return { lines, ...verdict(lines) };
}

export function render(tx: TxInput, report: Report): string {
  const out: string[] = [];
  out.push('launch-check: IgnixManager.createToken, before signing');
  out.push(`      from   ${show(tx.from)}`);
  out.push(`      to     ${show(tx.to)}`);
  out.push(`      kernel ${show(tx.kernel)}`);
  out.push('');
  for (const l of report.lines) out.push(formatLine(l));
  out.push('');
  const total = report.passed + report.failed;
  if (report.ok) {
    out.push(`VERDICT: PASS. All ${total} checks passed.`);
    out.push('Next: run the fork simulation with the same arguments (tools/launch-check/simulate.ts). Sign only if it passes too.');
    out.push('Before signing, compare the name, the ticker and the metadata URI above with what you typed.');
  } else {
    out.push(`VERDICT: FAIL. ${report.failed} of ${total} checks failed or could not be performed. DO NOT SIGN this transaction.`);
  }
  return out.join('\n');
}

const jsonable = (_k: string, v: unknown): unknown => (typeof v === 'bigint' ? v.toString() : v);

async function main(argv: readonly string[]): Promise<number> {
  let flags: Map<string, string>;
  let tx: TxInput;
  let expected: Expected;
  let circuits: Fact<string>;
  try {
    flags = parseFlags(argv, FLAGS);
    if (flags.has('help') || argv.length === 0) {
      console.log(USAGE);
      return argv.length === 0 ? 2 : 0;
    }
    const deployment = readDeploymentFlag(flags);
    const refusal = deployment ? sessionTwoRefusal(deployment) : null;
    if (refusal) {
      console.log(`launch-check refuses: ${refusal}`);
      console.log('');
      console.log('VERDICT: FAIL. Nothing can be approved without the deployed kernel. DO NOT SIGN this transaction.');
      return 1;
    }
    expected = loadExpected(flags.get('expected'));
    if (deployment) expected = withDeployment(expected, deployment);
    tx = readTx(flags, expected.kernel);
    circuits = pickCircuits(expected, flags.get('circuits'));
  } catch (e) {
    if (!(e instanceof UsageError) && !(e instanceof Error)) throw e;
    console.error(`launch-check could not run: ${(e as Error).message}`);
    console.error('Nothing was checked. This is NOT a pass. Run with --help for the arguments.');
    return 2;
  }
  const rpcUrls = flags.has('rpc') ? [flags.get('rpc') as string] : [...DEFAULT_RPCS];
  const report = await run(tx, expected, circuits, rpcUrls);
  if (flags.has('json')) console.log(JSON.stringify({ tx, ...report }, jsonable, 2));
  else console.log(render(tx, report));
  return report.ok ? 0 : 1;
}

// Run only when this file is the program (the tests import it instead).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      console.error(`launch-check failed unexpectedly: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
      console.error('Nothing can be concluded. This is NOT a pass.');
      process.exitCode = 1;
    },
  );
}
