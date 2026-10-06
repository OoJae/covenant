#!/usr/bin/env node
// simulate: runs the exact createToken transaction on a local fork of X Layer and then drives the kernel
// through bind, an outsider's buy and settle (the Foundry project in sim/). Second command of launch day.
//
//   node tools/launch-check/simulate.ts --deployment deployments/xlayer.json --tx @tx.json
//   node tools/launch-check/simulate.ts --deployment deployments/xlayer.json --from <launcher> --to <address> \
//        --value <wei> --data <0x hex | @file> [--kernel <address>] [--rpc <url>] [--block <number>]
//
// The arguments are the ones launch-check.ts takes. The kernel is checked against the deployed contracts the
// deployment file names (KernelFactory, Circuits, Fab, SealedVM, Lens) before anything else. Everything happens
// on a fork inside forge: nothing is signed and nothing is sent to a real network.
//
// Exit code 0: the whole simulation succeeded. 1: it failed or could not run. 2: wrong arguments, or the
// kernel steps were skipped on request (a harness self-test, never a launch approval).

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { UsageError, chooseGeneration, parseFlags, readDeploymentFlag, readTx } from './args.ts';
import { DEFAULT_EXPECTED, USDT0, V2_QUOTE_SHIFT, type Generation, type TxInput } from './checks.ts';
import { sessionTwoRefusal, type Deployment } from './deployment.ts';
import { sameAddress, show } from './hex.ts';

const SIM = join(dirname(fileURLToPath(import.meta.url)), 'sim');
const SUITE = 'test/Live.t.sol:LiveLaunch';
const FULL = 'test_launch_simulation_full()';
const CREATE_ONLY = 'test_launch_simulation_create_only_KERNEL_CHECKS_SKIPPED()';

const USAGE = `simulate: runs the exact createToken transaction on a fork of X Layer, then bind, a buy and settle.

  node tools/launch-check/simulate.ts --deployment deployments/xlayer.json --tx @tx.json
  node tools/launch-check/simulate.ts --deployment deployments/xlayer.json \\
      --from <launcher address> --to <address> --value <wei> --data <0x hex | @file> [--kernel <address>] \\
      [--rpc <url>] [--block <number>]

  The arguments are the ones launch-check.ts takes (--tx or --from --to --value --data).
  --deployment  the Covenant deployment (deployments/xlayer.json, or the deploy/rehearsal.json format). Required:
                the kernel must have been created by its KernelFactory, hold its chip and pass the Lens
                preflight before anything runs. Refused while signing session 2 is not recorded in it.
                A launch quoted in USD₮0 runs against the deployment's kernel v2 (coreV2, flagshipV2) when the
                file names one: the outsider's buy and every balance are then in USD₮0
  --rpc         an X Layer JSON-RPC endpoint with archive state (default https://rpc.xlayer.tech); a local
                anvil fork (http://127.0.0.1:PORT) works the same way
  --block       fork this block instead of the latest one
  --skip-kernel-checks   harness self-test only: stop after the creation; needs no deployment. Never a launch
                approval (exit code 2).

Needs Foundry (forge) and, once: (cd tools/launch-check/sim && forge install foundry-rs/forge-std --no-git --root "$PWD")`;

const FLAGS = {
  deployment: 'value',
  tx: 'value',
  from: 'value',
  to: 'value',
  value: 'value',
  data: 'value',
  kernel: 'value',
  rpc: 'value',
  block: 'value',
  'skip-kernel-checks': 'flag',
  help: 'flag',
} as const;

interface ForgeTest {
  status: string;
  reason: string | null;
  decoded_logs?: string[];
}

interface Outcome {
  code: number;
  lines: string[];
}

const run = (cmd: string, args: readonly string[], env: NodeJS.ProcessEnv): Promise<{ code: number | null; stdout: string; stderr: string; error?: Error }> =>
  new Promise((resolve) => {
    const child = spawn(cmd, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (error) => resolve({ code: null, stdout, stderr, error }));
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });

/** The JSON object forge prints with --json: the last output line that parses as an object. */
function forgeJson(stdout: string): Record<string, { test_results: Record<string, ForgeTest> }> | null {
  const lines = stdout.split('\n').filter((l) => l.trim().startsWith('{'));
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      return JSON.parse(lines[i]);
    } catch {
      // not the result object
    }
  }
  return null;
}

const tail = (s: string, n: number): string => s.trim().split('\n').slice(-n).join('\n');

/** Turns forge's result into a verdict. Exported for the tests. */
export function judge(json: ReturnType<typeof forgeJson>, skipKernel: boolean, forgeOutput: string): Outcome {
  const lines: string[] = [];
  const tests = json?.[SUITE]?.test_results;
  if (!tests) {
    lines.push('forge did not report the simulation tests. Its output ended with:');
    lines.push(tail(forgeOutput, 25));
    lines.push('');
    lines.push('VERDICT: FAIL. The simulation could not run, so nothing was shown. DO NOT SIGN on the strength of this run.');
    return { code: 1, lines };
  }
  const wanted = tests[skipKernel ? CREATE_ONLY : FULL];
  const other = tests[skipKernel ? FULL : CREATE_ONLY];
  for (const l of wanted?.decoded_logs ?? []) lines.push('  ' + l);
  lines.push('');
  if (!wanted || wanted.status !== 'Success') {
    const why = !wanted ? 'the test is missing' : wanted.status === 'Skipped' ? 'the simulation was skipped: forge did not receive the inputs' : wanted.reason ?? 'no reason given';
    lines.push(`FAIL  ${why}`);
    lines.push('');
    lines.push('VERDICT: FAIL. The simulated launch did not complete. DO NOT SIGN this transaction.');
    return { code: 1, lines };
  }
  if (other && other.status !== 'Skipped') {
    lines.push(`VERDICT: FAIL. Unexpected result of the other simulation test: ${other.status}. DO NOT SIGN on the strength of this run.`);
    return { code: 1, lines };
  }
  if (skipKernel) {
    lines.push('VERDICT: INCOMPLETE. Only the creation was simulated; bind and settle were skipped on request.');
    lines.push('This is a self-test of the harness. It is NOT a pass and approves no launch.');
    return { code: 2, lines };
  }
  lines.push('VERDICT: PASS. On the fork, the kernel belongs to the deployment, the exact transaction created the token with');
  lines.push('the kernel as vault recipient, kernel.bind (by an unrelated address) succeeded, an unrelated buy paid tax into');
  lines.push('the vault, and kernel.settle wrote a record and took the tax.');
  return { code: 0, lines };
}

const ZERO = '0x0000000000000000000000000000000000000000';

/**
 * The input file forge reads. `value` and `chipId` are decimal strings so that no precision is lost. For kernel v2
 * the deployment is its v2 part (KernelFactoryV2, LensV2, the v2 chip) plus the quote and its code shift.
 */
export function inputFile(tx: TxInput, block: number, skipKernel: boolean, d: Deployment | null = null, generation: Generation = 'v1'): string {
  const o: Record<string, unknown> = { from: tx.from, to: tx.to, value: tx.value.toString(), data: tx.data, kernel: tx.kernel, block, skipKernelChecks: skipKernel };
  if (d && generation === 'v2') {
    o.deployment = {
      kernelFactory: d.kernelFactoryV2 ?? ZERO,
      circuits: d.circuits ?? ZERO,
      fab: d.fab ?? ZERO,
      sealedVM: d.sealedVM ?? ZERO,
      lens: d.lensV2 ?? ZERO,
      chipId: (d.chipIdV2 ?? 0n).toString(),
      quote: USDT0,
      quoteShift: (d.quoteShiftV2 ?? V2_QUOTE_SHIFT).toString(),
    };
  } else if (d) {
    o.deployment = {
      kernelFactory: d.kernelFactory ?? ZERO,
      circuits: d.circuits ?? ZERO,
      fab: d.fab ?? ZERO,
      sealedVM: d.sealedVM ?? ZERO,
      lens: d.lens ?? ZERO,
      chipId: (d.chipId ?? 0n).toString(),
    };
  }
  return JSON.stringify(o, null, 1) + '\n';
}

/** Signing session 2 is not recorded in the deployment: the simulation has nothing to run against. */
export class NotDeployed extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotDeployed';
  }
}

/** The deployment the full simulation needs: session 2 recorded, and the same kernel as --kernel (v1 or v2). */
export function checkDeployment(d: Deployment | null, tx: TxInput, skipKernel: boolean, generation: Generation = 'v1'): void {
  if (skipKernel) return;
  if (!d) throw new UsageError('--deployment is required: the simulation runs against the deployed Covenant contracts (deployments/xlayer.json)');
  const refusal = sessionTwoRefusal(d);
  if (refusal) throw new NotDeployed(refusal);
  const want = generation === 'v2' ? d.kernelV2 : d.kernel;
  if (want !== null && !sameAddress(want, tx.kernel)) {
    throw new UsageError(`--kernel ${show(tx.kernel)} is not the deployment's ${generation === 'v2' ? 'v2 kernel (the launch is quoted in USD₮0)' : 'kernel'} ${show(want)}`);
  }
}

async function main(argv: readonly string[]): Promise<number> {
  let tx: TxInput;
  let block = 0;
  let skipKernel = false;
  let rpc: string | undefined;
  let deployment: Deployment | null;
  let generation: Generation = 'v1';
  try {
    const flags = parseFlags(argv, FLAGS);
    if (flags.has('help') || argv.length === 0) {
      console.log(USAGE);
      return argv.length === 0 ? 2 : 0;
    }
    deployment = readDeploymentFlag(flags);
    skipKernel = flags.has('skip-kernel-checks');
    const refusal = deployment && !skipKernel ? sessionTwoRefusal(deployment) : null;
    if (refusal) throw new NotDeployed(refusal);
    // kernel v1 or v2 by the launch's quote, exactly as launch-check.ts decides it
    tx = readTx(flags, (data) => {
      generation = chooseGeneration(DEFAULT_EXPECTED, deployment, data);
      return (generation === 'v2' ? deployment?.kernelV2 : deployment?.kernel) ?? null;
    });
    checkDeployment(deployment, tx, skipKernel, generation);
    rpc = flags.get('rpc');
    if (flags.has('block')) {
      const b = flags.get('block') as string;
      if (!/^[1-9][0-9]*$/.test(b)) throw new UsageError(`--block: "${b}" is not a block number`);
      block = Number(b);
    }
  } catch (e) {
    if (e instanceof NotDeployed) {
      console.log(`simulate refuses: ${e.message}`);
      console.log('');
      console.log('VERDICT: FAIL. Nothing was simulated. DO NOT SIGN this transaction.');
      return 1;
    }
    console.error(`simulate could not run: ${(e as Error).message}`);
    console.error('Nothing was simulated. This is NOT a pass. Run with --help for the arguments.');
    return 2;
  }

  if (!existsSync(join(SIM, 'lib', 'forge-std', 'src', 'Test.sol'))) {
    console.error('simulate could not run: forge-std is not installed in tools/launch-check/sim/lib.');
    console.error('Run once:  (cd tools/launch-check/sim && forge install foundry-rs/forge-std --no-git --root "$PWD")');
    console.error('Nothing was simulated. This is NOT a pass.');
    return 1;
  }
  // one input file per run, so that two runs can never read each other's transaction
  const inputName = `launch-${process.pid}-${Date.now()}.json`;
  mkdirSync(join(SIM, 'inputs'), { recursive: true });
  writeFileSync(join(SIM, 'inputs', inputName), inputFile(tx, block, skipKernel, skipKernel ? null : deployment, generation));

  console.log('simulate: the exact createToken transaction on a fork of X Layer (nothing is sent)');
  console.log(`      from   ${show(tx.from)}`);
  console.log(`      to     ${show(tx.to)}`);
  console.log(`      kernel ${show(tx.kernel)}`);
  if (deployment && !skipKernel) console.log(`      deployment ${deployment.source}`);
  if (generation === 'v2' && !skipKernel) console.log('      kernel v2 (contracts/core-v2): the launch is quoted in USD₮0');
  console.log(`      fork   ${block === 0 ? 'the latest block' : 'block ' + block}${rpc ? ' of ' + rpc : ''}`);
  console.log('');

  const env: NodeJS.ProcessEnv = { ...process.env, LAUNCH_INPUT: `inputs/${inputName}` };
  if (rpc) env.XLAYER_RPC_URL = rpc;
  const r = await run('forge', ['test', '--root', SIM, '--match-contract', 'LiveLaunch', '--json', '-vv'], env);
  rmSync(join(SIM, 'inputs', inputName), { force: true });
  if (r.error) {
    console.error(`simulate could not run forge: ${r.error.message}`);
    console.error('Install Foundry (https://getfoundry.sh). Nothing was simulated. This is NOT a pass.');
    return 1;
  }
  const outcome = judge(forgeJson(r.stdout), skipKernel, r.stdout + '\n' + r.stderr);
  console.log(outcome.lines.join('\n'));
  return outcome.code;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      console.error(`simulate failed unexpectedly: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
      console.error('Nothing can be concluded. This is NOT a pass.');
      process.exitCode = 1;
    },
  );
}
