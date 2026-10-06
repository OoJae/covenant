// The audit as text: a markdown table per wallet, one verdict line per rule, and what the method cannot see.

import { checksumAddress } from '../../packages/chain/src/keccak.ts';
import type { AuditResult, Row, RuleResult } from './audit.ts';

const utc = (unix: number): string => new Date(unix * 1000).toISOString().replace('T', ' ').replace(/\.\d+Z$/, '');
const show = (a: string): string => checksumAddress(a);

export function formatOkb(wei: bigint): string {
  const whole = wei / 10n ** 18n;
  const frac = (wei % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '');
  return whole.toString() + (frac ? '.' + frac : '');
}

const cell = (s: string): string => s.replace(/\|/g, '\\|').replace(/\n/g, ' ');

function rowLine(r: Row): string {
  const target = r.target === null ? '(contract creation)' : `\`${show(r.target)}\` ${r.targetLabel}`;
  const fn =
    r.kind === 'authorization'
      ? '(authorisation)'
      : r.kind === 'userOperation'
        ? '(user operation)'
        : r.kind === 'usdt0Transfer'
          ? '(USD₮0 transfer, sent by another account)'
          : r.selector === null
            ? '(none)'
            : `\`${r.selector}\`${r.selectorName ? ' ' + r.selectorName : ''}`;
  const marks = [...r.flags.map((f) => `FLAG ${f}`), ...(r.unknownTarget ? ['WARN unknown target'] : []), ...r.undecided.map((f) => `NOT CHECKED ${f}`)];
  const nonce = r.kind === 'userOperation' ? `op ${r.nonce}` : r.kind === 'usdt0Transfer' ? '(none)' : String(r.nonce);
  const value = r.kind === 'usdt0Transfer' ? '0 (USD₮0 above)' : r.valueWei === '' ? 'not visible' : formatOkb(BigInt(r.valueWei));
  return `| ${r.block} | ${utc(r.timestamp)} | ${nonce} | ${cell(target)} | ${cell(fn)} | ${value} | ${cell(r.classification)}${marks.length ? ' **[' + marks.join('; ') + ']**' : ''} | \`${r.hash}\` |`;
}

/** One line per rule: its count and "expected 0". A rule that could not be decided never says PASS. */
export function ruleLine(r: RuleResult, result: AuditResult): string {
  const where = r.examples.length ? `: ${r.examples.join('; ')}${r.count > r.examples.length ? '; ...' : ''}` : '';
  if (r.count > 0) {
    return `FLAG         ${String(r.count).padStart(3)}  ${r.title} (expected 0${r.reverted ? `; ${r.reverted} of them reverted` : ''})${where}`;
  }
  if (r.notChecked) return `NOT CHECKED       ${r.title} (expected 0): ${r.notChecked}`;
  let note = '';
  const txs = result.wallets.reduce((s, w) => s + w.found, 0);
  if (r.id === 'kernel-value' && txs > 0 && !result.rulesContext.kernelsKnown) note = ' [no kernel is configured yet; decided because no transaction sent value to an unlisted contract]';
  if (r.id === 'transistor-transfer' && txs > 0 && !result.rulesContext.transistorsKnown) note = ' [the transistor contract is not configured yet; decided because no transaction looks like an ERC-1155 transfer]';
  return `PASS         ${String(r.count).padStart(3)}  ${r.title} (expected 0)${note}`;
}

export function verdictLines(result: AuditResult): string[] {
  const out: string[] = [];
  for (const r of result.rules) out.push(ruleLine(r, result));
  out.push(`${result.unknownTargets ? 'WARN' : 'NOTE'}         ${String(result.unknownTargets).padStart(3)}  transactions to targets that are not in the known list (a warning, not a flag)`);
  const reg = result.registry;
  if (reg) {
    out.push(`NOTE         ${String(reg.entries.length).padStart(3)}  wallet(s) listed in the TeamRegistry ${show(reg.address)}${reg.entry0IsDeployer ? ' (entry 0 is the deployer)' : ''}; all of them were audited`);
    out.push(
      `${reg.onlyInRegistry.length ? 'WARN' : 'NOTE'}         ${String(reg.onlyInRegistry.length).padStart(3)}  wallet(s) listed in the TeamRegistry but not declared in docs/WALLETS.md (a warning, not a flag)` +
        (reg.onlyInRegistry.length ? ': ' + reg.onlyInRegistry.map(show).join(', ') : ''),
    );
    out.push(
      `${reg.onlyInDoc.length ? 'WARN' : 'NOTE'}         ${String(reg.onlyInDoc.length).padStart(3)}  wallet(s) declared in docs/WALLETS.md (or as the deployer) but not listed in the TeamRegistry (a warning, not a flag)` +
        (reg.onlyInDoc.length ? ': ' + reg.onlyInDoc.map(show).join(', ') : ''),
    );
  } else if (!result.walletsByHand) {
    out.push('NOTE              the TeamRegistry is not configured (covenant.teamRegistry is null): the wallets come from docs/WALLETS.md and the deployer only');
  }
  for (const w of result.wallets) {
    const auths = w.rows.filter((r) => r.kind === 'authorization').length;
    const complete = w.found + auths === w.audited && w.audited === w.transactionCount;
    out.push(
      `${complete ? 'COMPLETE  ' : 'INCOMPLETE'}   ${String(w.found).padStart(3)}  transaction(s)${auths ? ` and ${auths} authorisation(s)` : ''} found for the ${w.transactionCount} nonce(s) of ${show(w.wallet.address)} (${w.wallet.role})` +
        (w.audited < w.transactionCount ? ` [only the first ${w.audited} nonces were audited]` : ''),
    );
    const u = w.userOps;
    if (u && u.scanned) {
      const n = w.rows.filter((r) => r.kind === 'userOperation').length;
      out.push(
        `COVERED      ${String(n).padStart(3)}  user operation(s) of ${show(w.wallet.address)} found through ${u.entryPoints.join(' and ')} in blocks ${u.from}..${u.to} (UserOperationEvent logs)` +
          (u.skipped.length ? `; ${u.skipped.join(', ')} has no code on X Layer, so no operation can go through it` : ''),
      );
    } else if (u) {
      out.push(`NOT COVERED       user operations of ${show(w.wallet.address)}: ${u.why ?? 'not scanned'}`);
    }
  }
  const s = result.usdt0Scan;
  if (s && s.scanned) {
    out.push(`COVERED      ${String(s.found).padStart(3)}  USD₮0 transfer(s) out of the team wallets in transactions they did not send (EIP-3009 authorisations such as x402 payments, allowances), blocks ${s.from}..${s.to} (USD₮0 Transfer logs, from the KernelFactoryV2's creation)`);
  } else if (s) {
    out.push(`NOT COVERED       USD₮0 moved out of the team wallets by other accounts: ${s.why ?? 'not scanned'}`);
  }
  const total = result.wallets.reduce((s, w) => s + w.found, 0);
  const ops = result.wallets.reduce((s, w) => s + w.rows.filter((r) => r.kind === 'userOperation').length, 0);
  out.push('');
  if (result.exitCode === 0) {
    out.push(
      `VERDICT: CLEAN. ${total} transaction(s)${ops ? ` and ${ops} user operation(s)` : ''} of ${result.wallets.length} declared wallet(s) were examined at block ${result.block}; every rule was checked on every path the audit covers and none was broken (what it cannot see is listed below).`,
    );
  } else if (result.exitCode === 1) {
    const broken = result.rules.filter((r) => r.count > 0);
    out.push(`VERDICT: FLAGGED. ${broken.length} rule(s) were broken by ${broken.reduce((s, r) => s + r.count, 0)} finding(s) (the FLAG lines above).`);
    if (result.incomplete.length) out.push('The audit is also incomplete: ' + result.incomplete.join(' | '));
  } else {
    out.push('VERDICT: INCOMPLETE. Nothing was flagged in what was examined, but the audit could not be completed, so this is NOT a clean result:');
    for (const i of result.incomplete) out.push('  - ' + i);
  }
  return out;
}

export const LIMITS: readonly string[] = [
  'Calls made by contracts on a wallet\'s behalf. Only the transactions a wallet itself signed and sent are listed, and, for a wallet that has code (an EIP-7702 delegation), its ERC-4337 user operations through the EntryPoints of addresses.json. A contract the wallet controls, a relayer, or the wallet\'s delegate code called directly by another account (not through an EntryPoint) can act for it in transactions sent by other accounts; those are invisible here. Within a wallet\'s own transactions and user operations, internal calls are visible only through the events they emit (the IGNIX Trade event and token Transfer / Approval events are checked); an internal call or a value transfer that emits nothing is not seen (debug_traceTransaction is not available on the public RPC).',
  'Wallets that were never declared. The audit covers the addresses it is given and nothing else. It cannot show that the team controls no other wallet.',
  'Anything off-chain (for example trades on a centralised exchange).',
  'Tokens moved out of a wallet by other accounts. The one exception is USD₮0, the quote of kernel v2: every USD₮0 Transfer out of a team wallet is scanned (EIP-3009 authorisations, such as x402 payments, and allowances need no transaction of the wallet), from the creation of the KernelFactoryV2, before which no kernel quoted in USD₮0 could receive any.',
];

export function renderMarkdown(result: AuditResult): string {
  const out: string[] = [];
  out.push('# Team wallet audit');
  out.push('');
  out.push(`- Chain: X Layer (chain id ${result.chainId}), state at block **${result.block}** (${utc(result.blockTime)} UTC)`);
  out.push(`- Source: public JSON-RPC only (${result.rpc}); no explorer API`);
  out.push('- Method: for each wallet, `eth_getTransactionCount` at the audit block gives the number of nonces used; a bisection over `eth_getTransactionCount` at historical blocks finds the block of every nonce; each block is fetched and the wallet\'s transactions are read from it, with their receipts');
  out.push(`- Wallets: ${result.wallets.map((w) => `\`${show(w.wallet.address)}\` (${w.wallet.role})`).join(', ') || 'none'}`);
  if (result.pendingRoles.length) out.push(`- Roles in docs/WALLETS.md that have no address yet (not audited): ${result.pendingRoles.join(', ')}`);
  if (result.registry) out.push(`- TeamRegistry: \`${show(result.registry.address)}\`, read with \`count()\` and \`at(i)\` at the audit block`);
  out.push('');
  if (result.registry) {
    out.push('## TeamRegistry');
    out.push('');
    if (result.registry.entries.length) {
      out.push('| entry | wallet | role | declared (UTC) |');
      out.push('|---|---|---|---|');
      for (const e of result.registry.entries) out.push(`| ${e.index} | \`${show(e.wallet)}\` | ${cell(e.role)} | ${utc(e.timestamp)} |`);
    } else {
      out.push('The registry lists no wallet.');
    }
    out.push('');
  }
  for (const w of result.wallets) {
    out.push(`## \`${show(w.wallet.address)}\` (${w.wallet.role})`);
    out.push('');
    out.push(`Nonces used at block ${result.block}: **${w.transactionCount}**. Transactions found: **${w.found}**.` + (w.audited < w.transactionCount ? ` Only the first ${w.audited} nonces were audited.` : ''));
    if (w.smartWallet) {
      out.push(`\nThis address is a smart wallet: its code is the EIP-7702 designator to \`${show(w.smartWallet.implementation)}\`, a known smart-wallet implementation: ${w.smartWallet.label}.`);
    } else if (w.code !== '0x') {
      out.push(`\nThis address has code at the audit block (${(w.code.length - 2) / 2} bytes): it is not a plain externally owned account, nor a known smart wallet.`);
    }
    if (w.userOps?.scanned) {
      out.push(`\nUser operations: ${w.rows.filter((r) => r.kind === 'userOperation').length} found through ${w.userOps.entryPoints.join(' and ')}, in blocks ${w.userOps.from} (its first activity) to ${w.userOps.to}. They are listed below with the transactions; only their events are visible. A call to its delegate code made directly by another account, without an EntryPoint, is not visible here.`);
    } else if (w.userOps) {
      out.push(`\nUser operations were NOT scanned: ${w.userOps.why}.`);
    }
    if (w.unexplained.length) out.push(`\nNonces that no transaction of this wallet explains: ${w.unexplained.join(', ')}.`);
    out.push('');
    if (w.rows.length) {
      out.push('| block | time (UTC) | nonce | target | function | value (OKB) | classification | transaction |');
      out.push('|---|---|---|---|---|---|---|---|');
      for (const r of w.rows) out.push(rowLine(r));
    } else {
      out.push('No transaction has ever been sent by this wallet.');
    }
    out.push('');
  }
  out.push('## Verdict');
  out.push('');
  out.push('```');
  out.push(...verdictLines(result));
  out.push('```');
  out.push('');
  out.push('## What this method cannot see');
  out.push('');
  for (const l of LIMITS) out.push(`- ${l}`);
  out.push('');
  return out.join('\n');
}

export function toJson(result: AuditResult): string {
  return JSON.stringify(
    {
      generatedBy: 'tools/audit-team/audit-team.ts',
      chainId: result.chainId,
      block: result.block,
      blockTimeUtc: utc(result.blockTime),
      rpc: result.rpc,
      exitCode: result.exitCode,
      verdict: result.exitCode === 0 ? 'CLEAN' : result.exitCode === 1 ? 'FLAGGED' : 'INCOMPLETE',
      rules: result.rules,
      unknownTargets: result.unknownTargets,
      incomplete: result.incomplete,
      cannotSee: LIMITS,
      pendingRoles: result.pendingRoles,
      teamRegistry: result.registry,
      wallets: result.wallets.map((w) => ({
        address: w.wallet.address,
        role: w.wallet.role,
        transactionCount: w.transactionCount,
        audited: w.audited,
        found: w.found,
        hasCode: w.code !== '0x',
        smartWallet: w.smartWallet,
        userOperations: w.userOps,
        unexplainedNonces: w.unexplained,
        transactions: w.rows.map((r) => ({
          kind: r.kind,
          userOpHash: r.userOpHash ?? null,
          block: r.block,
          timeUtc: utc(r.timestamp),
          nonce: r.nonce,
          hash: r.hash,
          target: r.target,
          targetLabel: r.targetLabel,
          selector: r.selector,
          function: r.selectorName,
          valueWei: r.valueWei,
          reverted: r.reverted,
          classification: r.classification,
          flags: r.flags,
          unknownTarget: r.unknownTarget,
          notChecked: r.undecided,
        })),
      })),
    },
    null,
    1,
  );
}
