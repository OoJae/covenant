// Prints the curl self-check from OKX's A2MCP guide for this service, and can run it.
//
//   node scripts/selfcheck.ts [https://host]                 print the curl commands
//   node scripts/selfcheck.ts https://host --run             perform the checks; exit 1 if any fails
//   node scripts/selfcheck.ts http://localhost:8787 --run --mock-pay   also complete a mock-paid call
//
// With --run, PAY_TO and PRICE_USD from the environment (if set) are compared with the challenge.
// It never signs or pays anything.

import { curlSelfCheck, runSelfCheck } from '../src/selfcheck.ts';

const args = process.argv.slice(2);
const base = args.find((a) => /^https?:\/\//.test(a)) ?? process.env['PUBLIC_BASE_URL'] ?? 'http://localhost:8787';
const preset = process.env['DEFAULT_PRESET'] ?? 'flow-governor';

if (!args.includes('--run')) {
  process.stdout.write(curlSelfCheck(base, preset));
} else {
  const checks = await runSelfCheck(base, {
    payTo: process.env['PAY_TO'] || undefined,
    priceUsd: process.env['PRICE_USD'] || undefined,
    mockPay: args.includes('--mock-pay'),
  });
  for (const c of checks) process.stdout.write(`${c.ok ? 'PASS' : 'FAIL'}  ${c.name}  (${c.detail})\n`);
  const failed = checks.filter((c) => !c.ok).length;
  process.stdout.write(failed === 0 ? `\nall ${checks.length} checks passed\n` : `\n${failed} of ${checks.length} checks failed\n`);
  process.exitCode = failed === 0 ? 0 : 1;
}
