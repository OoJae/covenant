// The checks of launch-check, as pure functions: calldata in, chain facts in, lines out.
// Nothing here talks to the network; launch-check.ts gathers the facts and prints the lines.
//
// A check is PASS only when it was performed and held. A check that could not be performed is FAIL and
// says why. Lines of kind 'info' carry no verdict.

import {
  CREATE_TOKEN_SELECTOR,
  DecodeError,
  MANAGER,
  canonicalDifference,
  decodeCreateToken,
  decodeRecipient,
  launchDigest,
  splitCalldata,
  type CreateTokenCall,
} from './decode.ts';
import { ZERO_ADDRESS, formatDuration, formatOkb, formatUtc, hexToBytes, isPlainAscii, sameAddress, show, visible } from './hex.ts';
import type { Envelope, Globals } from './kernel-abi.ts';
import { recoverFromSignature } from './secp256k1.ts';

/** TapeOut's processor factory on X Layer. */
export const TAPEOUT_FACTORY = '0x1f09daefa827f02cbb40967cc91b259763760761';
export const CHAIN_ID = 196n;
/** The signature must still be valid for at least this long when the check runs. */
export const MIN_DEADLINE_SECONDS = 180n;

// Rules of the launch that no expected-values file can relax.
export const FIXED = {
  templateId: 3, // Directed: 100% of the tax to one recipient
  quote: ZERO_ADDRESS, // native OKB (kernel v1 binds nothing else)
  venue: 1, // Uniswap V2 (the only venue a taxed token can use)
  curveFeeBps: 100, // LaunchLogic.validate reverts on anything else
} as const;

export interface Expected {
  taxBuyBps: number;
  taxSellBps: number;
  protectionSecs: number;
  /** Exact token name and ticker, or null to leave the comparison to the human. */
  name: string | null;
  symbol: string | null;
  /** The kernel address, or null: then --kernel is taken as given. */
  kernel: string | null;
  /** The Covenant processor's Circuits (ERC-721) contract, or null: then --circuits must be given. */
  circuits: string | null;
  /** The Covenant processor's Transistors (ERC-1155) contract, or null: then it is not compared. */
  transistors: string | null;
  /** The deployment's KernelFactory, or null: then "kernel was created by the KernelFactory" cannot be checked. */
  kernelFactory: string | null;
  /** The deployment's Fab and SealedVM, or null: then they are not compared with the kernel's globals. */
  fab: string | null;
  sealedVM: string | null;
  /** The deployment's chip id for its kernel, or null: then it is not compared. */
  chipId: bigint | null;
}

export const DEFAULT_EXPECTED: Expected = {
  taxBuyBps: 300,
  taxSellBps: 300,
  protectionSecs: 8_640_000,
  name: null,
  symbol: null,
  kernel: null,
  circuits: null,
  transistors: null,
  kernelFactory: null,
  fab: null,
  sealedVM: null,
  chipId: null,
};

export interface Line {
  kind: 'check' | 'info';
  /** Set for checks only. */
  ok?: boolean;
  /** Short statement of what must hold (checks) or what is shown (info). */
  label: string;
  /** The decoded or read value. */
  value: string;
  /** For a failed check: what was expected, or why the check could not be performed. */
  detail?: string;
}

const pass = (label: string, value: string): Line => ({ kind: 'check', ok: true, label, value });
const fail = (label: string, value: string, detail: string): Line => ({ kind: 'check', ok: false, label, value, detail });
const check = (ok: boolean, label: string, value: string, detail: string): Line => (ok ? pass(label, value) : fail(label, value, detail));
const info = (label: string, value: string): Line => ({ kind: 'info', label, value });
/** A check that could not be performed. It is a failure, and the line says so. */
export const notPerformed = (label: string, why: string): Line => fail(label, 'NOT CHECKED', `could not be performed: ${why}`);

export function formatLine(l: Line): string {
  if (l.kind === 'info') return `      ${l.label}: ${l.value}`;
  return `${l.ok ? 'PASS' : 'FAIL'}  ${l.label}: ${l.value}${l.ok || !l.detail ? '' : `  <-- ${l.detail}`}`;
}

export interface TxInput {
  from: string;
  to: string;
  value: bigint;
  data: string;
  kernel: string;
}

export interface CalldataResult {
  lines: Line[];
  /** The decoded call, or null when the calldata did not decode. */
  call: CreateTokenCall | null;
}

const quoted = (s: string): string => `"${visible(s)}"` + (isPlainAscii(s) ? '' : '  (contains characters outside printable ASCII, shown as \\u escapes)');
const okb = (wei: bigint): string => `${formatOkb(wei)} OKB (${wei} wei)`;

/** Labels of every check that reads the decoded arguments, used when the calldata does not decode. */
const DEPENDENT_LABELS = [
  'calldata carries nothing beyond its arguments',
  'templateId is 3 (Directed vault)',
  'vault recipient is the kernel',
  'quote is native OKB (the zero address)',
  'venue is 1 (Uniswap V2)',
  'curve fees are 100 / 100 bps',
  'buy tax and sell tax are the expected values',
  'protection period is the expected value',
  'firstBuy is 0 (no team buy)',
  'msg.value is the listing fee alone',
  'anti-snipe is off (snipeStartBps 0)',
  'no founder round (founderBps 0, founderSecs 0, no founder root)',
];

/**
 * Everything that can be decided from the transaction the wallet shows, without the chain.
 * The deadline and the signature need the chain's clock and the Manager's signer, so they are in `chainLines`.
 */
export function calldataLines(tx: TxInput, expected: Expected): CalldataResult {
  const lines: Line[] = [];

  lines.push(check(sameAddress(tx.to, MANAGER), 'to is the IgnixManager proxy', show(tx.to), `expected ${show(MANAGER)}`));

  let selector: string | null = null;
  try {
    selector = splitCalldata(tx.data).selector;
  } catch (e) {
    lines.push(fail('function selector is createToken', 'unreadable', (e as Error).message));
  }
  if (selector !== null) {
    lines.push(check(selector === CREATE_TOKEN_SELECTOR, 'function selector is createToken', selector, `expected ${CREATE_TOKEN_SELECTOR}`));
  }

  let call: CreateTokenCall | null = null;
  try {
    call = decodeCreateToken(tx.data);
    lines.push(pass('calldata decodes as createToken arguments', `${(tx.data.trim().replace(/^0x/i, '').length / 2)} bytes`));
  } catch (e) {
    const why = e instanceof DecodeError ? e.message : String(e);
    lines.push(fail('calldata decodes as createToken arguments', 'no', why));
    for (const label of DEPENDENT_LABELS) lines.push(notPerformed(label, 'the calldata did not decode'));
    return { lines, call: null };
  }
  const p = call.p;

  const diff = canonicalDifference(tx.data, call);
  lines.push(check(diff === null, DEPENDENT_LABELS[0], diff === null ? 'exact canonical encoding' : 'no', diff ?? ''));

  // ── vault ──
  lines.push(check(call.templateId === FIXED.templateId, DEPENDENT_LABELS[1], String(call.templateId), 'expected 3'));
  try {
    const recipient = decodeRecipient(call.vaultData);
    lines.push(check(sameAddress(recipient, tx.kernel), DEPENDENT_LABELS[2], show(recipient), `expected the kernel ${show(tx.kernel)}; the recipient can never be changed after launch`));
  } catch (e) {
    lines.push(fail(DEPENDENT_LABELS[2], call.vaultData, (e as Error).message));
  }
  if (expected.kernel !== null) {
    lines.push(check(sameAddress(expected.kernel, tx.kernel), 'kernel is the one the deployment / expected-values file names', show(tx.kernel), `the file says ${show(expected.kernel)}`));
  }

  // ── market ──
  lines.push(check(sameAddress(p.quote, FIXED.quote), DEPENDENT_LABELS[3], show(p.quote), 'expected the zero address; kernel v1 binds only a native OKB vault'));
  lines.push(check(call.venue === FIXED.venue, DEPENDENT_LABELS[4], String(call.venue), 'expected 1'));
  lines.push(
    check(
      p.buyFeeBps === FIXED.curveFeeBps && p.sellFeeBps === FIXED.curveFeeBps,
      DEPENDENT_LABELS[5],
      `${p.buyFeeBps} / ${p.sellFeeBps}`,
      'the Manager reverts FeeTooHigh() on anything else',
    ),
  );
  lines.push(
    check(
      p.taxBuyBps === expected.taxBuyBps && p.taxSellBps === expected.taxSellBps,
      DEPENDENT_LABELS[6],
      `${p.taxBuyBps} / ${p.taxSellBps} bps`,
      `expected ${expected.taxBuyBps} / ${expected.taxSellBps} bps`,
    ),
  );
  lines.push(
    check(
      call.graduationProtectionSecs === BigInt(expected.protectionSecs),
      DEPENDENT_LABELS[7],
      `${call.graduationProtectionSecs} s (${formatDuration(call.graduationProtectionSecs)})`,
      `expected ${expected.protectionSecs} s`,
    ),
  );

  // ── no team buy, no anti-snipe, no founder round ──
  lines.push(check(p.firstBuy === 0n, DEPENDENT_LABELS[8], okb(p.firstBuy), 'a first buy is executed inside createToken with the launcher\'s own money: a team buy'));
  lines.push(
    check(
      tx.value === p.listingFee,
      DEPENDENT_LABELS[9],
      `value ${okb(tx.value)}, listingFee ${okb(p.listingFee)}`,
      'the value must equal the listing fee; anything above it is spent on a first buy',
    ),
  );
  lines.push(
    check(p.snipeStartBps === 0, DEPENDENT_LABELS[10], `snipeStartBps ${p.snipeStartBps}, snipeMins ${p.snipeMins}`, 'expected snipeStartBps 0; the surcharge goes to the platform and the kernel skips buys while it is on'),
  );
  lines.push(
    check(
      p.founderBps === 0 && p.founderSecs === 0 && BigInt(p.founderRoot) === 0n,
      DEPENDENT_LABELS[11],
      `founderBps ${p.founderBps}, founderSecs ${p.founderSecs}, founderRoot ${BigInt(p.founderRoot) === 0n ? '0x0' : p.founderRoot}`,
      'expected all three to be zero',
    ),
  );

  // ── for the human ──
  if (expected.name !== null) lines.push(check(p.name === expected.name, 'name is the expected name', quoted(p.name), `expected ${quoted(expected.name)}`));
  else lines.push(info('name   (compare with what you typed)', quoted(p.name)));
  if (expected.symbol !== null) lines.push(check(p.symbol === expected.symbol, 'ticker is the expected ticker', quoted(p.symbol), `expected ${quoted(expected.symbol)}`));
  else lines.push(info('ticker (compare with what you typed)', quoted(p.symbol)));
  if (!p.textOk) lines.push(fail('name, ticker and metadata URI are valid UTF-8', 'no', 'one of the three strings is not valid UTF-8 text'));
  lines.push(info('metadata URI', quoted(p.metadataURI)));
  lines.push(info('graduation target', okb(p.graduation)));
  lines.push(info('listing fee (paid to the platform)', okb(p.listingFee)));
  lines.push(info('salt', p.salt));
  lines.push(info('vault factory argument', show(call.factory)));
  lines.push(info('signature deadline', `${call.deadline} (${formatUtc(call.deadline)})`));

  return { lines, call };
}

// ───────────────────────────── chain facts ─────────────────────────────

/** A value read from the chain, or the reason it could not be read. */
export type Fact<T> = { ok: true; value: T } | { ok: false; error: string };
export const got = <T>(value: T): Fact<T> => ({ ok: true, value });
export const missing = <T>(error: string): Fact<T> => ({ ok: false, error });

export interface ChainFacts {
  rpcUrl: string;
  chainId: Fact<bigint>;
  /** The block every other fact was read at. */
  block: Fact<{ number: bigint; timestamp: bigint; hash: string }>;
  /** Local wall-clock time in unix seconds when the facts were read. */
  localTime: bigint;
  signer: Fact<string>;
  poolFee: Fact<bigint>;
  launchFactory: Fact<string>;
  /** REGISTRY.factoryOf(templateId of the call). */
  registeredFactory: Fact<string>;
  /** pausedUntil(0): the LAUNCH switch. */
  launchPausedUntil: Fact<bigint>;
  launcherBalance: Fact<bigint>;
  kernelCodeSize: Fact<number>;
  kernelToken: Fact<string>;
  kernelChipId: Fact<bigint>;
  kernelEnvelope: Fact<Envelope>;
  kernelGlobals: Fact<Globals>;
  /** The Circuits address used for the chip check (expected file or --circuits), or the reason there is none. */
  circuits: Fact<string>;
  circuitsCodeSize: Fact<number>;
  /** TapeOutFactory.isCPU(circuits). */
  circuitsIsProcessor: Fact<boolean>;
  /** Circuits.transistors(). */
  circuitsTransistors: Fact<string>;
  /** Circuits.ownerOf(kernel.chipId()). */
  chipOwner: Fact<string>;
  /** KernelFactory.isKernel(kernel), for the deployment's KernelFactory. */
  kernelIsKernel: Fact<boolean>;
}

/** Runs `f` on a fact's value, or reports the check as not performed. */
function on<T>(fact: Fact<T>, label: string, f: (v: T) => Line): Line {
  return fact.ok ? f(fact.value) : notPerformed(label, fact.error);
}

/** The checks that need the chain: the clock, the signer and the kernel. */
export function chainLines(tx: TxInput, call: CreateTokenCall | null, expected: Expected, facts: ChainFacts): Line[] {
  const lines: Line[] = [];
  const noCall = 'the calldata did not decode';

  lines.push(on(facts.chainId, 'RPC endpoint is X Layer (chain id 196)', (id) => check(id === CHAIN_ID, 'RPC endpoint is X Layer (chain id 196)', String(id), 'expected 196')));
  if (facts.block.ok) {
    const b = facts.block.value;
    lines.push(info('chain state read at block', `${b.number} (${formatUtc(b.timestamp)}), ${facts.rpcUrl}`));
  } else {
    lines.push(notPerformed('chain state read at one block', facts.block.error));
  }

  // ── deadline: block.timestamp must not exceed it. The later of the chain clock and this machine's clock is used.
  {
    const label = 'signature deadline has at least 3 minutes left';
    if (!call) lines.push(notPerformed(label, noCall));
    else {
      const deadline = call.deadline;
      lines.push(
        on(facts.block, label, (b) => {
          const now = b.timestamp > facts.localTime ? b.timestamp : facts.localTime;
          const left = deadline - now;
          return check(
            left >= MIN_DEADLINE_SECONDS,
            label,
            `${left >= 0n ? formatDuration(left) + ' left' : 'expired ' + formatDuration(-left) + ' ago'} (deadline ${formatUtc(deadline)}; chain clock ${formatUtc(b.timestamp)}, this machine ${formatUtc(facts.localTime)})`,
            left < 0n ? 'the signature has expired: createToken would revert SignatureExpired()' : 'too little time to sign and be mined; ask ignix.bot for a fresh signature',
          );
        }),
      );
    }
  }

  // ── the platform signature covers exactly this calldata, this launcher and this chain
  {
    const label = 'platform signature is valid for this launcher and this calldata';
    if (!call) lines.push(notPerformed(label, noCall));
    else if (!facts.signer.ok) lines.push(notPerformed(label, facts.signer.error));
    else if (!facts.poolFee.ok) lines.push(notPerformed(label, facts.poolFee.error));
    else if (!facts.launchFactory.ok) lines.push(notPerformed(label, facts.launchFactory.error));
    else if (!facts.chainId.ok) lines.push(notPerformed(label, facts.chainId.error));
    else {
      const digest = launchDigest(call, {
        chainId: facts.chainId.value,
        manager: tx.to,
        sender: tx.from,
        poolFee: facts.poolFee.value,
        launchFactory: facts.launchFactory.value,
      });
      let sigBytes: Uint8Array | null = null;
      try {
        sigBytes = hexToBytes(call.sig);
      } catch {
        sigBytes = null;
      }
      const rec = sigBytes ? recoverFromSignature(digest, sigBytes) : { signer: null, problem: 'the signature is not hex' };
      if (rec.signer === null) lines.push(fail(label, 'no', rec.problem ?? 'unrecoverable'));
      else {
        lines.push(
          check(
            sameAddress(rec.signer, facts.signer.value),
            label,
            `signed by ${show(rec.signer)}`,
            `the Manager's signer is ${show(facts.signer.value)}: the calldata was altered or mis-copied, or --from is not the wallet the signature was issued to; createToken would revert BadSignature()`,
          ),
        );
      }
    }
  }

  {
    const label = 'vault factory argument is the registered template factory';
    if (!call) lines.push(notPerformed(label, noCall));
    else {
      const factory = call.factory;
      lines.push(on(facts.registeredFactory, label, (reg) => check(sameAddress(reg, factory) && !sameAddress(reg, ZERO_ADDRESS), label, show(factory), `the registry says ${show(reg)}; createToken would revert FactoryChanged()`)));
    }
  }

  {
    const label = 'launches are not paused on the Manager';
    if (!facts.block.ok) lines.push(notPerformed(label, facts.block.error));
    else {
      const now = facts.block.value.timestamp;
      lines.push(on(facts.launchPausedUntil, label, (until) => check(until <= now, label, until === 0n ? 'open' : `pausedUntil(LAUNCH) = ${until}`, `paused until ${formatUtc(until)}; createToken would revert Paused()`)));
    }
  }

  // ── the kernel
  lines.push(on(facts.kernelCodeSize, 'kernel address has code', (n) => check(n > 0, 'kernel address has code', `${n} bytes at ${show(tx.kernel)}`, 'no contract is deployed at the kernel address')));
  lines.push(
    on(facts.kernelToken, 'kernel is not bound yet (token() is the zero address)', (t) =>
      check(sameAddress(t, ZERO_ADDRESS), 'kernel is not bound yet (token() is the zero address)', show(t), 'this kernel is already bound to a token; bind succeeds only once'),
    ),
  );
  lines.push(
    on(facts.kernelEnvelope, "kernel's envelope launcher is --from", (e) =>
      check(
        sameAddress(e.launcher, tx.from),
        "kernel's envelope launcher is --from",
        show(e.launcher),
        `--from is ${show(tx.from)}; the kernel was created for its envelope's launcher, and a token another wallet creates can be bound only by the launcher itself, never by the keeper`,
      ),
    ),
  );
  {
    const label = 'kernel was created by the Covenant KernelFactory (isKernel)';
    if (expected.kernelFactory === null) lines.push(notPerformed(label, 'no KernelFactory address was given: pass --deployment with the deployment file'));
    else {
      const f = expected.kernelFactory;
      lines.push(on(facts.kernelIsKernel, label, (is) => check(is, label, `isKernel = ${is} at ${show(f)}`, 'this address was not created by the deployment\'s KernelFactory: its envelope and its code are not the audited ones')));
    }
  }
  {
    const want: [string, keyof Globals, string | null][] = [
      ['KernelFactory', 'factory', expected.kernelFactory],
      ['Fab', 'fab', expected.fab],
      ['SealedVM', 'sealedVM', expected.sealedVM],
    ];
    const known = want.filter(([, , a]) => a !== null) as [string, keyof Globals, string][];
    if (known.length) {
      const label = `kernel's globals name the deployment's ${known.map(([n]) => n).join(', ')}`;
      lines.push(
        on(facts.kernelGlobals, label, (g) => {
          const wrong = known.filter(([, k, a]) => !sameAddress(g[k] as string, a));
          return check(
            wrong.length === 0,
            label,
            known.map(([n, k]) => `${n} ${show(g[k] as string)}`).join(', '),
            wrong.map(([n, , a]) => `the deployment's ${n} is ${show(a)}`).join('; '),
          );
        }),
      );
    }
  }
  lines.push(
    on(facts.kernelGlobals, 'kernel is wired to the IgnixManager proxy', (g) =>
      check(sameAddress(g.manager, MANAGER), 'kernel is wired to the IgnixManager proxy', show(g.manager), `expected ${show(MANAGER)}; bind looks the vault up in the kernel's own manager`),
    ),
  );

  // ── the chip
  if (facts.circuits.ok) lines.push(info('Circuits (processor) address used for the chip checks', show(facts.circuits.value)));
  else lines.push(notPerformed('Circuits (processor) address is known', facts.circuits.error));
  {
    const label = "Circuits address is the kernel's own processor";
    if (!facts.circuits.ok) lines.push(notPerformed(label, facts.circuits.error));
    else {
      const c = facts.circuits.value;
      lines.push(on(facts.kernelGlobals, label, (g) => check(sameAddress(g.circuits, c), label, show(g.circuits), `the address given to this tool is ${show(c)}; the kernel checks its chip in its own processor`)));
    }
  }
  lines.push(on(facts.circuitsCodeSize, 'Circuits address has code', (n) => check(n > 0, 'Circuits address has code', `${n} bytes`, 'no contract is deployed at the Circuits address')));
  lines.push(
    on(facts.circuitsIsProcessor, 'Circuits is a processor created by the TapeOut factory', (is) =>
      check(is, 'Circuits is a processor created by the TapeOut factory', is ? 'isCPU = true' : 'isCPU = false', `the factory ${show(TAPEOUT_FACTORY)} does not know this address`),
    ),
  );
  if (expected.transistors !== null) {
    const want = expected.transistors;
    lines.push(
      on(facts.circuitsTransistors, "Circuits' transistor contract is the expected one", (t) =>
        check(sameAddress(t, want), "Circuits' transistor contract is the expected one", show(t), `the expected-values file says ${show(want)}`),
      ),
    );
  }
  {
    const label = 'kernel holds its chip (Circuits.ownerOf(kernel.chipId()) is the kernel)';
    if (!facts.kernelChipId.ok) lines.push(notPerformed(label, facts.kernelChipId.error));
    else {
      const id = facts.kernelChipId.value;
      lines.push(on(facts.chipOwner, label, (o) => check(sameAddress(o, tx.kernel), label, `chip ${id} is owned by ${show(o)}`, `expected the kernel ${show(tx.kernel)}; bind fails until the chip NFT is transferred to it`)));
    }
  }
  if (expected.chipId !== null) {
    const label = "kernel's chip is the deployment's chip";
    const want = expected.chipId;
    lines.push(on(facts.kernelChipId, label, (id) => check(id === want, label, `chip ${id}`, `the deployment file says chip ${want}`)));
  }
  {
    const label = "kernel's chipId() and globals().chipId agree";
    if (!facts.kernelChipId.ok) lines.push(notPerformed(label, facts.kernelChipId.error));
    else {
      const id = facts.kernelChipId.value;
      lines.push(on(facts.kernelGlobals, label, (g) => check(g.chipId === id, label, String(id), `globals().chipId is ${g.chipId}`)));
    }
  }

  if (facts.launcherBalance.ok) {
    lines.push(info('launcher balance', `${formatOkb(facts.launcherBalance.value)} OKB (the transaction sends ${formatOkb(tx.value)} OKB plus gas)`));
  }
  if (facts.kernelEnvelope.ok) {
    const e = facts.kernelEnvelope.value;
    lines.push(info('kernel envelope', `epoch ${e.epochLen} s, allowance payee ${show(e.allowancePayee)}, capT ${e.capT}, allowCumBps ${e.allowCumBps}, buys ${e.buyEnabled ? 'enabled' : 'disabled'}`));
  }
  if (facts.kernelGlobals.ok) {
    const g = facts.kernelGlobals.value;
    lines.push(info('kernel chip', `${g.gateCount} gates, ${g.nState} latches; step gas ${g.stepFloor} (TapeOut), ${g.sealedFloor} (sealed)`));
  }
  return lines;
}

export interface Verdict {
  passed: number;
  failed: number;
  ok: boolean;
}

export function verdict(lines: readonly Line[]): Verdict {
  const checks = lines.filter((l) => l.kind === 'check');
  const failed = checks.filter((l) => !l.ok).length;
  return { passed: checks.length - failed, failed, ok: failed === 0 && checks.length > 0 };
}
