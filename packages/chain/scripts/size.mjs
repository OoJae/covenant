// Prints the minified (and gzipped) size of the package, part by part, and fails if the whole
// main entry or the keccak module grows past its ceiling.
//
// Design target: "a JSON-RPC client and ABI codec of about 3 KB". The client and the codec
// are listed on their own so that number can be read off directly; the typed call table for
// the TapeOut contracts and the Multicall3 reader come on top. A bundler only keeps what an
// application imports, so the cost inside web/ is at most the "whole main entry" figure.

import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { build } from 'esbuild';

const root = new URL('../', import.meta.url);

const size = async (file) => {
  const r = await build({
    entryPoints: [fileURLToPath(new URL(file, root))],
    bundle: true,
    minify: true,
    format: 'esm',
    target: 'es2022',
    write: false,
    legalComments: 'none',
  });
  const code = r.outputFiles[0].contents;
  return { min: code.length, gz: gzipSync(code, { level: 9 }).length };
};

const rpc = await size('src/rpc.ts');
const abi = await size('src/abi.ts');
const main = await size('src/index.ts');
const keccak = await size('src/keccak.ts');

const MAIN_CEILING = 5120;
const KECCAK_CEILING = 2048;
const line = (label, s, note = '') => console.log(`${label.padEnd(46)} ${String(s.min).padStart(5)} bytes min  ${String(s.gz).padStart(5)} gzip  ${note}`);

line('JSON-RPC client (src/rpc.ts)', rpc);
line('ABI codec (src/abi.ts)', abi);
console.log(`${'client + codec'.padEnd(46)} ${String(rpc.min + abi.min).padStart(5)} bytes min               (design target: about 3,000)`);
line('whole main entry (adds call table, Multicall3)', main, `ceiling ${MAIN_CEILING}: ${main.min <= MAIN_CEILING ? 'ok' : 'TOO LARGE'}`);
line('keccak module (keccak256 + EIP-55)', keccak, `ceiling ${KECCAK_CEILING}: ${keccak.min <= KECCAK_CEILING ? 'ok' : 'TOO LARGE'}`);

if (main.min > MAIN_CEILING || keccak.min > KECCAK_CEILING) process.exit(1);
