// A stand-in for the chip toolchain that speaks the "covenant-architect/1" contract (see src/toolchain.ts).
// The preset name selects the behaviour, so the tests can drive every branch of the adapter.

import process from 'node:process';

let input = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) input += chunk;

const req = JSON.parse(input);
const out = (doc, code = 0) => {
  process.stdout.write(JSON.stringify(doc));
  process.exitCode = code;
};

const success = (extra = {}) => ({
  ok: true,
  netlistHex: '0x0100006200000001000001',
  manifest: { format: 'tapc-manifest/1', name: req.preset, params: req.params, protocol: req.protocol, op: req.op, ...extra },
  proofs: [{ id: 'shares-sum-256', status: 'proved' }],
  cost: { transistors: 2 },
});

switch (req.preset) {
  case 'reject':
    out({ ok: false, error: { code: 'unknown_param', message: 'epochLen must be at least 300', stage: 'validate', diagnostics: [{ code: 'range', path: 'params.epochLen', message: 'too small', hint: 'use 300 or more' }] } });
    break;
  case 'reject-exit':
    out({ ok: false, error: { code: 'unknown_preset', message: 'no such preset' } }, 2);
    break;
  case 'crash':
    process.stderr.write('Traceback (most recent call last):\n  boom\n');
    process.exitCode = 3;
    break;
  case 'garbage':
    process.stdout.write('Preparing to run yosys. This might take a while...\n');
    break;
  case 'slow':
    await new Promise((r) => setTimeout(r, 60_000));
    out(success());
    break;
  case 'big':
    out({ ...success(), netlistHex: `0x${'00'.repeat(24_001)}` });
    break;
  case 'failed-proof':
    out({ ...success(), proofs: [{ id: 'shares-sum-256', status: 'proved' }, { id: 'clamp-free', status: 'failed', detail: 'counterexample at state 0x3' }] });
    break;
  case 'no-ok':
    out({ netlistHex: '0x00', manifest: {}, proofs: [], cost: {} });
    break;
  case 'bad-hex':
    out({ ...success(), netlistHex: 'not hex' });
    break;
  case 'env':
    // Report which environment variables the toolchain can see.
    out(success({ envKeys: Object.keys(process.env).sort(), cwd: process.cwd(), argv: process.argv.slice(2) }));
    break;
  default:
    out(success());
}
