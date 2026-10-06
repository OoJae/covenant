// The hand-written codec of src/abi.ts against Foundry's `cast` (test/fixtures/cast-vectors.json, written by
// test/fixtures/make-cast-vectors.sh) and every selector recomputed from its signature. Offline.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { toBytes } from '../../../packages/chain/src/index.ts';
import { keccak256Hex } from '../../../packages/chain/src/keccak.ts';
import {
  ERRORS,
  SIGNATURES,
  decBytesValue,
  decFileInfo,
  decStringArray,
  decStringValue,
  encAccountOf,
  encAppendChunk,
  encBind,
  encCanEdit,
  encFileInfo,
  encIsLive,
  encOpen,
  encPathsRange,
  encPutFile,
  encRead,
  encReadRange,
  encRemoveFile,
  encSetFallback,
  explainRevert,
} from '../src/abi.ts';

const v = JSON.parse(readFileSync(new URL('./fixtures/cast-vectors.json', import.meta.url), 'utf8')) as Record<string, string>;
const C = v.container;
const H = v.hash;

test('every selector is the first four bytes of keccak256 of its signature', () => {
  for (const [name, [signature, selector]] of Object.entries(SIGNATURES)) {
    assert.equal(keccak256Hex(new TextEncoder().encode(signature)).slice(2, 10), selector, name);
  }
});

test('every custom error selector is the hash of an error the contracts declare', () => {
  const declared = [
    'NotOwner()', 'NotOpened()', 'TooLarge()', 'NoSuchFile()', 'BadIndex()', 'DeployFailed()', 'NotRegisteredCPU()', 'NoNesting()',
    'AlreadyOpened()', 'SelfOwnership()', 'FeeTooLow(uint256,uint256)', 'FeeTransferFailed()', 'BadPayment()', 'BadDomain()', 'NotContainer()', 'TooFarAhead()',
  ];
  const selectors = new Set(declared.map((s) => keccak256Hex(new TextEncoder().encode(s)).slice(2, 10)));
  for (const sel of Object.keys(ERRORS)) assert.ok(selectors.has(sel), `ERRORS has ${sel}, which is none of the declared errors`);
  assert.equal(selectors.size, Object.keys(ERRORS).length);
  assert.match(explainRevert('0xbdbbb533'), /^BadPayment/);
  assert.equal(explainRevert('0x08c379a0' + '0'.repeat(62) + '20' + '0'.repeat(63) + '3' + '616263' + '0'.repeat(58)), 'abc');
  assert.equal(explainRevert('0x'), 'reverted without data');
});

test('calldata is byte-identical to cast', () => {
  assert.equal(encPutFile(C, 'assets/a b.js', 'text/javascript; charset=utf-8', H, toBytes('0xdeadbeef00')), v.putFile);
  assert.equal(encPutFile(C, 'e', 'application/manifest+json; charset=utf-8', H, new Uint8Array()), v.putFileEmpty);
  assert.equal(encAppendChunk(C, v.longPath, 7, toBytes('0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021')), v.appendChunk);
  assert.equal(encRemoveFile(C, 'index.html'), v.removeFile);
  assert.equal(encSetFallback(C, 'index.html'), v.setFallback);
  assert.equal(encBind('1.2.275.tape', C, 3), v.bind);
  assert.equal(encOpen(C, 12n), v.open);
  assert.equal(encIsLive('1.2.275.tape', C), v.isLive);
  assert.equal(encReadRange(C, 'big.bin', 98304, 98304), v.readRange);
  assert.equal(encFileInfo(C, 'index.html'), v.fileInfo);
  assert.equal(encRead(C, 'index.html'), v.read);
  assert.equal(encPathsRange(C, 200, 200), v.pathsRange);
  assert.equal(encAccountOf(C, 12n), v.accountOf);
  assert.equal(encCanEdit(C, C), v.canEdit);
});

test('return data encoded by cast decodes, and short data is refused', () => {
  assert.deepEqual(decFileInfo(v.fileInfoReturn), { size: 60000, contentType: 'application/octet-stream', sha256: H, updatedAt: 1791145036, chunkCount: 3 });
  assert.deepEqual(decStringArray(v.stringArrayReturn), ['index.html', 'assets/app.js', v.longPath, '']);
  assert.deepEqual([...decBytesValue(v.bytesReturn)], [0x00, 0xff, 0x10]);
  assert.equal(decStringValue(v.stringReturn), 'index.html');
  assert.throws(() => decStringValue(v.stringReturn.slice(0, 100)), /too short/);
  assert.throws(() => decFileInfo('0x'), /too short/);
});
