// ecrecover and RLP, checked against public test vectors and against a real X Layer transaction.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { keccak256 } from '../../../packages/chain/src/keccak.ts';
import { bytesToHex, hexToBytes } from '../hex.ts';
import { authorizationHash, createAddress, intBytes, rlpEncode, signingHash } from '../rlp.ts';
import { N, _internal, addressOfPoint, recoverAddress, recoverFromSignature } from '../secp256k1.ts';
import { testSigner } from './helpers.ts';

const ob = JSON.parse(readFileSync(new URL('./fixtures/ob-launch.json', import.meta.url), 'utf8'));
const utf8 = new TextEncoder();

test('the generator point gives the well-known address of private key 1', () => {
  const g = _internal.affine(_internal.multiply([_internal.GX, _internal.GY, 1n], 1n));
  assert.ok(g);
  assert.equal(addressOfPoint(g.x, g.y), '0x7e5f4552091a69125d5dfcb7b8c2659029395bdf');
  const g2 = _internal.affine(_internal.multiply([_internal.GX, _internal.GY, 1n], 2n));
  assert.ok(g2);
  assert.equal(addressOfPoint(g2.x, g2.y), '0x2b5ad5c4795c026514f8317c7a215e218dccd6cf');
});

test('RLP matches the examples of the Ethereum specification', () => {
  const hex = (x: Parameters<typeof rlpEncode>[0]): string => bytesToHex(rlpEncode(x));
  assert.equal(hex(utf8.encode('dog')), '0x83646f67');
  assert.equal(hex([utf8.encode('cat'), utf8.encode('dog')]), '0xc88363617483646f67');
  assert.equal(hex(new Uint8Array(0)), '0x80');
  assert.equal(hex([]), '0xc0');
  assert.equal(hex(intBytes(0)), '0x80');
  assert.equal(hex(intBytes(15)), '0x0f');
  assert.equal(hex(intBytes(1024)), '0x820400');
  assert.equal(hex([[], [[]], [[], [[]]]]), '0xc7c0c1c0c3c0c1c0');
  assert.equal(hex(utf8.encode('Lorem ipsum dolor sit amet, consectetur adipisicing elit')), '0xb8384c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c6974');
});

test('CREATE addresses', () => {
  assert.equal(createAddress('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 0), '0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d');
  assert.equal(createAddress('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 1), '0x343c43a37d37dff08ae8c4a11544c718abb4fcf8');
  assert.equal(createAddress('0x6ac7ea33f8831ea9dcc53393aaa88b25a785dbf0', 2), '0xf778b86fa74e846c4f0a1fbd1335fe81c00a0c91');
});

test('the sender of the real OB launch transaction is recovered from its signature', () => {
  const tx = ob.transaction;
  assert.equal(tx.type, '0x2');
  const { hash, yParity } = signingHash(tx);
  assert.equal(recoverAddress(hash, BigInt(tx.r), BigInt(tx.s), yParity), tx.from);
  // and the transaction hash itself is keccak256 of the signed envelope
  const signed = rlpEncode([
    intBytes(tx.chainId),
    intBytes(tx.nonce),
    intBytes(tx.maxPriorityFeePerGas),
    intBytes(tx.maxFeePerGas),
    intBytes(tx.gas),
    hexToBytes(tx.to),
    intBytes(tx.value),
    hexToBytes(tx.input),
    [],
    intBytes(tx.yParity),
    intBytes(tx.r),
    intBytes(tx.s),
  ]);
  assert.equal(bytesToHex(keccak256(Uint8Array.of(2, ...signed))), tx.hash);
});

test('a throwaway test signer round-trips, and a wrong hash recovers someone else', () => {
  const s = testSigner('secp256k1 test: throwaway (not a real key)');
  for (let i = 0; i < 8; i++) {
    const hash = keccak256(utf8.encode(`message ${i}`));
    const sig = hexToBytes(s.sign(hash));
    assert.deepEqual(recoverFromSignature(hash, sig), { signer: s.address, problem: null });
    assert.notEqual(recoverFromSignature(keccak256(utf8.encode(`other ${i}`)), sig).signer, s.address);
  }
});

test('invalid signatures are refused the way OpenZeppelin ECDSA.recover refuses them', () => {
  const s = testSigner('secp256k1 test: throwaway (not a real key)');
  const hash = keccak256(utf8.encode('x'));
  const sig = hexToBytes(s.sign(hash));
  assert.match(String(recoverFromSignature(hash, sig.slice(0, 64)).problem), /64 bytes, not 65/);
  const badV = Uint8Array.from(sig);
  badV[64] = 1;
  assert.match(String(recoverFromSignature(hash, badV).problem), /v byte is 1/);
  // the high-s twin of a valid signature: same signer under raw ecrecover, refused by OpenZeppelin
  const r = _internal.bytesToBig(sig.slice(0, 32));
  const lowS = _internal.bytesToBig(sig.slice(32, 64));
  const high = Uint8Array.from([...sig.slice(0, 32), ..._internal.bigTo32(N - lowS), sig[64] === 27 ? 28 : 27]);
  assert.match(String(recoverFromSignature(hash, high).problem), /high s/);
  assert.equal(recoverAddress(hash, r, N - lowS, sig[64] === 27 ? 1 : 0), s.address, 'raw ecrecover accepts the twin');
  // out-of-range values
  assert.equal(recoverAddress(hash, 0n, lowS, 0), null);
  assert.equal(recoverAddress(hash, r, 0n, 0), null);
  assert.equal(recoverAddress(hash, N, lowS, 0), null);
  assert.equal(recoverAddress(hash, r, lowS, 2), null);
  assert.throws(() => recoverAddress(new Uint8Array(31), r, lowS, 0), /32 bytes/);
});

test('the EIP-7702 authorisation hash is keccak256(0x05 || rlp([chainId, address, nonce]))', () => {
  const a = { chainId: '0xc4', address: '0x00000000000000000000000000000000000000aa', nonce: '0x7', r: '0x1', s: '0x1' };
  const body = rlpEncode([intBytes(196), hexToBytes(a.address), intBytes(7)]);
  assert.deepEqual(authorizationHash(a), keccak256(Uint8Array.of(5, ...body)));
});
