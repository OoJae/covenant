#!/usr/bin/env node
// payto-check: before anyone points the Covenant Architect's x402 PAY_TO at a kernel, check that the address is the
// deployment's v2 kernel and that the chain is ready for it. Read-only (eth_call, eth_getCode); never signs or sends.
//
//   node tools/launch-check/payto-check.ts --deployment deployments/xlayer.json --pay-to <address> [--rpc <url>]
//
// It passes only when PAY_TO is the v2 kernel the deployment names (flagshipV2), created by its KernelFactoryV2,
// quoting in USD₮0, BOUND to its token (USD₮0 sent to an unbound kernel, and any other ERC-20 sent to any kernel,
// stays there for ever), with a vault quoted in USD₮0 that pays this kernel, holding its chip, and not blocked by
// USD₮0. What it cannot check is printed as well: contracts/core-v2/NOTES.md section 9, step 6 sets three conditions
// that live off chain (IGNIX's written confirmation, OKX.AI agent 14683's review finished, the fixed Architect
// deployed). PAY_TO is a seller setting the operator can change at any time; no team wallet may ever pay the kernel.
//
// Exit code 0: every on-chain check passed. 1: a check failed or could not be performed. 2: called wrongly.

import { pathToFileURL } from 'node:url';
import { UsageError, parseFlags, readDeploymentFlag } from './args.ts';
import { DEFAULT_RPCS, connect } from './chain.ts';
import { USDT0, formatLine, got, missing, notPerformed, verdict, type Fact, type Line } from './checks.ts';
import { MANAGER, selectorOf } from './decode.ts';
import { hasKernelV2, missingPartsV2, type Deployment } from './deployment.ts';
import { ZERO_ADDRESS, addressWord, parseAddress, sameAddress, show, strip0x, word } from './hex.ts';
import { kernel as kernelCalls, kernelFactory as factoryCalls } from './kernel-abi.ts';

const USAGE = `payto-check: is this address ready to be the Covenant Architect's x402 PAY_TO? Read-only.

  node tools/launch-check/payto-check.ts --deployment deployments/xlayer.json --pay-to <address> [--rpc <url>]

  --deployment  deployments/xlayer.json with kernel v2 recorded (coreV2, flagshipV2), or the flat
                deploy/rehearsal-v2.json format
  --pay-to      the address proposed as PAY_TO
  --rpc         an X Layer JSON-RPC endpoint (default: rpc.xlayer.tech, then xlayerrpc.okx.com)

Exit code 0: every on-chain check passed (the off-chain conditions it prints must hold too). 1: a check failed or
could not be performed. 2: the tool was called wrongly.`;

const FLAGS = { deployment: 'value', 'pay-to': 'value', rpc: 'value', help: 'flag' } as const;

/** The conditions of contracts/core-v2/NOTES.md section 9, step 6 that no chain read can show. */
export const OFF_CHAIN = [
  '(a) IGNIX has confirmed in writing, in the Developer Support topic, that contract buys funded by third-party x402 revenue paid to the kernel are allowed',
  '(b) OKX.AI agent 14683 has finished its review (PAY_TO must not change on a listed service while it is in review)',
  '(d) the Architect running in production includes the settlement-timeout fix of review A-F6',
] as const;

const pass = (label: string, value: string): Line => ({ kind: 'check', ok: true, label, value });
const fail = (label: string, value: string, detail: string): Line => ({ kind: 'check', ok: false, label, value, detail });
const check = (ok: boolean, label: string, value: string, detail: string): Line => (ok ? pass(label, value) : fail(label, value, detail));

/** One 32-byte word as an address, strictly. */
const asAddress = (ret: string): string => {
  const h = strip0x(ret);
  if (h.length !== 64 || !/^0{24}/.test(h)) throw new Error(`returned ${h.length / 2} bytes, not one address`);
  return '0x' + h.slice(24);
};
const asWord = (ret: string): bigint => {
  const h = strip0x(ret);
  if (h.length !== 64) throw new Error(`returned ${h.length / 2} bytes, not one word`);
  return BigInt('0x' + h);
};

export async function run(d: Deployment, payTo: string, rpcUrls: readonly string[]): Promise<{ lines: Line[]; ok: boolean; passed: number; failed: number }> {
  const lines: Line[] = [];
  const kernel = d.kernelV2 as string;
  const factory = d.kernelFactoryV2 as string;
  lines.push(check(sameAddress(payTo, kernel), "PAY_TO is the deployment's v2 kernel (flagshipV2.kernel)", show(payTo), `the deployment's v2 kernel is ${show(kernel)}; PAY_TO may point only at it`));

  const rpc = connect(rpcUrls, { timeout: 20000, retries: 1 });
  const at = 'latest';
  const k = kernelCalls(payTo);
  const req = (to: string, data: string): readonly [string, readonly unknown[]] => ['eth_call', [{ to, data }, at]] as const;
  const batch = async (reqs: readonly (readonly [string, readonly unknown[]])[]): Promise<unknown[]> => {
    try {
      return await rpc.batch(reqs as never);
    } catch (e) {
      return reqs.map(() => e);
    }
  };
  const fact = <T>(r: unknown, what: string, decode: (x: string) => T): Fact<T> => {
    if (r instanceof Error) return missing(`${what}: ${r.message}`);
    if (typeof r !== 'string') return missing(`${what}: no answer`);
    try {
      return got(decode(r));
    } catch (e) {
      return missing(`${what} ${(e as Error).message}`);
    }
  };
  const [rChain, rCode, rIs, rQuote, rToken, rVault, rChip, rBlocked] = await batch([
    ['eth_chainId', []],
    ['eth_getCode', [payTo, at]],
    req(factory, factoryCalls(factory).isKernel(payTo).data),
    req(payTo, k.quote().data),
    req(payTo, k.token().data),
    req(payTo, k.vault().data),
    req(payTo, k.chipId().data),
    req(USDT0, selectorOf('isBlocked(address)') + addressWord(payTo)),
  ]);
  const on = <T>(f: Fact<T>, label: string, g: (v: T) => Line): Line => (f.ok ? g(f.value) : notPerformed(label, f.error));
  lines.push(on(fact(rChain, 'eth_chainId', (x) => BigInt(x)), 'RPC endpoint is X Layer (chain id 196)', (id) => check(id === 196n, 'RPC endpoint is X Layer (chain id 196)', String(id), 'expected 196')));
  lines.push(on(fact(rCode, 'eth_getCode(PAY_TO)', (x) => strip0x(x).length / 2), 'PAY_TO has code', (n) => check(n > 0, 'PAY_TO has code', `${n} bytes`, 'no contract at this address')));
  lines.push(on(fact(rIs, 'KernelFactoryV2.isKernel(PAY_TO)', asWord), 'PAY_TO was created by the KernelFactoryV2 (isKernel)', (v) => check(v === 1n, 'PAY_TO was created by the KernelFactoryV2 (isKernel)', `isKernel = ${v === 1n} at ${show(factory)}`, 'not a v2 kernel of this deployment')));
  lines.push(on(fact(rQuote, 'kernel.quote()', asAddress), "the kernel's quote is USD₮0", (q) => check(sameAddress(q, USDT0), "the kernel's quote is USD₮0", show(q), `expected ${show(USDT0)}`)));
  const token = fact(rToken, 'kernel.token()', asAddress);
  lines.push(
    on(token, 'the kernel is bound (token() is not the zero address)', (t) =>
      check(!sameAddress(t, ZERO_ADDRESS), 'the kernel is bound (token() is not the zero address)', show(t), 'never point PAY_TO at a kernel before bind() has succeeded: USD₮0 sent to a kernel that is never bound stays there for ever'),
    ),
  );
  const vault = fact(rVault, 'kernel.vault()', asAddress);
  const chip = fact(rChip, 'kernel.chipId()', asWord);
  lines.push(on(fact(rBlocked, 'USD₮0.isBlocked(kernel)', asWord), 'USD₮0 has not blocked the kernel', (b) => check(b === 0n, 'USD₮0 has not blocked the kernel', b === 0n ? 'not blocked' : 'BLOCKED', 'Tether has blocked this address: payments would still arrive, but the kernel could not spend them')));

  // the vault and the chip, which need the answers above
  const second: (readonly [string, readonly unknown[]])[] = [];
  const bound = token.ok && !sameAddress(token.value, ZERO_ADDRESS) && vault.ok && !sameAddress(vault.value, ZERO_ADDRESS);
  if (bound) {
    second.push(req(vault.value, selectorOf('QUOTE()')), req(vault.value, selectorOf('RECIPIENT()')), req(MANAGER, selectorOf('vaultOf(address)') + addressWord(token.value)));
  }
  if (chip.ok && d.circuits) second.push(req(d.circuits, selectorOf('ownerOf(uint256)') + word(chip.value)));
  const r2 = second.length ? await batch(second) : [];
  const vaultLabel = "the token's vault is quoted in USD₮0, pays this kernel, and is the Manager's vault for the token";
  if (bound) {
    const q = fact(r2[0], 'vault.QUOTE()', asAddress);
    const rec = fact(r2[1], 'vault.RECIPIENT()', asAddress);
    const of = fact(r2[2], 'IgnixManager.vaultOf(token)', asAddress);
    if (!q.ok || !rec.ok || !of.ok) lines.push(notPerformed(vaultLabel, [q, rec, of].map((f) => (f.ok ? '' : f.error)).filter(Boolean).join('; ')));
    else {
      const good = sameAddress(q.value, USDT0) && sameAddress(rec.value, payTo) && sameAddress(of.value, vault.value as string);
      lines.push(check(good, vaultLabel, `vault ${show(vault.value as string)}: QUOTE ${show(q.value)}, RECIPIENT ${show(rec.value)}`, `the Manager's vault for the token is ${show(of.value)}`));
    }
  } else {
    lines.push(notPerformed(vaultLabel, 'the kernel is not bound'));
  }
  const chipLabel = "the kernel holds its chip (Circuits.ownerOf(kernel.chipId()))";
  if (!chip.ok) lines.push(notPerformed(chipLabel, chip.error));
  else if (!d.circuits) lines.push(notPerformed(chipLabel, 'the deployment names no Circuits'));
  else lines.push(on(fact(r2[r2.length - 1], 'Circuits.ownerOf(chipId)', asAddress), chipLabel, (o) => check(sameAddress(o, payTo), chipLabel, `chip ${chip.value} is owned by ${show(o)}`, 'the kernel does not hold its chip')));
  return { lines, ...verdict(lines) };
}

async function main(argv: readonly string[]): Promise<number> {
  let d: Deployment;
  let payTo: string;
  let rpcUrls: readonly string[];
  try {
    const flags = parseFlags(argv, FLAGS);
    if (flags.has('help') || argv.length === 0) {
      console.log(USAGE);
      return argv.length === 0 ? 2 : 0;
    }
    const dep = readDeploymentFlag(flags);
    if (!dep) throw new UsageError('--deployment is required');
    if (!hasKernelV2(dep)) {
      console.log(`payto-check refuses: ${dep.source} records no ${missingPartsV2(dep).map((m) => `${m.part} (${m.what})`).join(', ')}. There is no v2 kernel to point PAY_TO at.`);
      console.log('');
      console.log('VERDICT: FAIL. Keep PAY_TO on the agent wallet.');
      return 1;
    }
    d = dep;
    const p = flags.get('pay-to');
    if (p === undefined) throw new UsageError('--pay-to is required');
    payTo = parseAddress(p, '--pay-to');
    rpcUrls = flags.has('rpc') ? [flags.get('rpc') as string] : [...DEFAULT_RPCS];
  } catch (e) {
    console.error(`payto-check could not run: ${(e as Error).message}`);
    console.error('Nothing was checked. This is NOT a pass. Run with --help for the arguments.');
    return 2;
  }
  const r = await run(d, payTo, rpcUrls);
  console.log('payto-check: the Covenant Architect\'s x402 PAY_TO, before it is changed');
  console.log(`      PAY_TO ${show(payTo)}`);
  console.log('');
  for (const l of r.lines) console.log(formatLine(l));
  console.log('');
  console.log('Conditions no chain read can show (contracts/core-v2/NOTES.md section 9, step 6); they must hold too:');
  for (const c of OFF_CHAIN) console.log(`      ${c}`);
  console.log('PAY_TO is a seller setting the operator can change at any time. No team wallet may ever pay the kernel or call the paid endpoint.');
  console.log('');
  if (r.ok) console.log(`VERDICT: PASS on chain (${r.passed} checks). Change PAY_TO only if (a), (b) and (d) above hold as well.`);
  else console.log(`VERDICT: FAIL. ${r.failed} of ${r.passed + r.failed} checks failed or could not be performed. Keep PAY_TO on the agent wallet.`);
  return r.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      console.error(`payto-check failed unexpectedly: ${e instanceof Error ? e.stack ?? e.message : String(e)}`);
      process.exitCode = 1;
    },
  );
}
