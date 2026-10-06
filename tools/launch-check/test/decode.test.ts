// The createToken decoder, proven on real mainnet launches (fixtures fetched by fixtures/fetch.ts).
// Offline: every expected value below was read from X Layer by that script and is stored next to this file.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { keccak256 } from '../../../packages/chain/src/keccak.ts';
import {
  CREATE_TOKEN_SELECTOR,
  CREATE_TOKEN_SIGNATURE,
  DecodeError,
  MANAGER,
  canonicalDifference,
  decodeCreateToken,
  decodeRecipient,
  encodeCreateToken,
  launchDigest,
  selectorOf,
  type CreateTokenCall,
} from '../decode.ts';
import { bytesToHex, hexToBytes, strip0x, word } from '../hex.ts';
import { recoverFromSignature } from '../secp256k1.ts';
import { launch, params } from './helpers.ts';

const fixture = (name: string): any => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
const ob = fixture('ob-launch.json');
const corpus = fixture('directed-launches.json');

const words = (ret: string): bigint[] => {
  const h = strip0x(ret);
  const out: bigint[] = [];
  for (let i = 0; i < h.length; i += 64) out.push(BigInt('0x' + h.slice(i, i + 64)));
  return out;
};
const addr = (w: bigint): string => '0x' + w.toString(16).padStart(40, '0');
/** A `string` returned by an eth_call. */
const retString = (ret: string): string => {
  const h = strip0x(ret);
  const at = Number(BigInt('0x' + h.slice(0, 64)));
  const len = Number(BigInt('0x' + h.slice(at * 2, at * 2 + 64)));
  return new TextDecoder().decode(hexToBytes(h.slice(at * 2 + 64, at * 2 + 64 + len * 2)));
};
const topic = (signature: string): string => bytesToHex(keccak256(new TextEncoder().encode(signature)));

test('the createToken selector is the first four bytes of keccak256 of its signature', () => {
  assert.equal(selectorOf(CREATE_TOKEN_SIGNATURE), '0xef44bdf2');
  assert.equal(CREATE_TOKEN_SELECTOR, '0xef44bdf2');
});

test('real OB launch: every decoded field equals what the chain shows', () => {
  const tx = ob.transaction;
  assert.equal(tx.hash, '0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1');
  assert.equal(tx.to, MANAGER);
  assert.equal(ob.receipt.status, '0x1', 'the launch succeeded on mainnet');
  const c = decodeCreateToken(tx.input);
  const token = '0x995546dfdf93bef59c35742ab5f4762fbcb8eeee';

  // IgnixManager.tokens(token): the 16 words of FINDINGS.md section 5
  const t = words(ob.chain['IgnixManager.tokens(token)']);
  assert.equal(t.length, 16);
  assert.equal(addr(t[0]), tx.from, 'creator is the sender');
  assert.equal(BigInt(c.p.buyFeeBps), t[1]);
  assert.equal(BigInt(c.p.sellFeeBps), t[2]);
  assert.equal(BigInt(c.p.taxBuyBps), t[3]);
  assert.equal(BigInt(c.p.taxSellBps), t[4]);
  assert.equal(c.p.quote, addr(t[5]));
  assert.equal(BigInt(c.p.snipeStartBps), t[6]);
  assert.equal(BigInt(c.p.snipeMins), t[7]);
  assert.equal(t[8], BigInt(ob.block.timestamp), 'createdAt is the launch block time');
  assert.ok(BigInt(ob.block.timestamp) <= c.deadline, 'the launch block is not after the signed deadline');

  // the values themselves, as recorded in contracts/probes/FINDINGS.md section 1
  assert.equal(c.p.taxBuyBps, 100);
  assert.equal(c.p.taxSellBps, 100);
  assert.equal(c.p.snipeStartBps, 5000);
  assert.equal(c.p.snipeMins, 30);
  assert.equal(c.p.firstBuy, 400000000000000000n);
  assert.equal(c.p.listingFee, 0n);
  assert.equal(c.graduationProtectionSecs, 8_640_000n);
  assert.equal(c.templateId, 3);
  assert.equal(c.venue, 1);

  // the vault the launch created
  const vault = addr(words(ob.chain['IgnixManager.vaultOf(token)'])[0]);
  assert.equal(decodeRecipient(c.vaultData), addr(words(ob.chain['vault.RECIPIENT()'])[0]), 'vaultData is the vault RECIPIENT');
  assert.equal(addr(words(ob.chain['vault.TOKEN()'])[0]), token);
  assert.equal(c.p.quote, addr(words(ob.chain['vault.QUOTE()'])[0]));
  assert.equal(c.factory, addr(words(ob.chain['vault.FACTORY()'])[0]), 'the factory argument built the vault');
  assert.equal(c.factory, addr(words(ob.before['VaultRegistry.factoryOf(3)'])[0]), 'and was the registered template-3 factory');

  // the token
  assert.equal(c.p.name, retString(ob.chain['token.name()']));
  assert.equal(c.p.symbol, retString(ob.chain['token.symbol()']));
  assert.equal(c.graduationProtectionSecs, words(ob.chain['token.protectionDuration()'])[0]);

  // no founder round was opened
  assert.deepEqual(words(ob.chain['IgnixManager.founderRound(token)']), [0n, 0n, 0n, 0n]);
  assert.equal(c.p.founderBps, 0);
  assert.equal(c.p.founderSecs, 0);
  assert.equal(BigInt(c.p.founderRoot), 0n);

  // the TokenCreated event of the same transaction
  const created = ob.receipt.logs.find((l: any) => l.address === MANAGER && l.topics[0] === topic('TokenCreated(address,address,address,uint256,string,address,address,uint16)'));
  assert.ok(created, 'TokenCreated was emitted');
  assert.equal(addr(BigInt(created.topics[1])), token);
  assert.equal(addr(BigInt(created.topics[2])), tx.from);
  assert.equal(addr(BigInt(created.topics[3])), c.p.quote);
  const ev = words(created.data);
  assert.equal(ev[0], c.p.graduation, 'graduation');
  assert.equal(addr(ev[2]), vault, 'vault');
  assert.equal(ev[4], BigInt(c.templateId), 'templateId');
  const uriAt = Number(ev[1]) / 32;
  const uriLen = Number(ev[uriAt]);
  assert.equal(strip0x(created.data).slice((uriAt + 1) * 64, (uriAt + 1) * 64 + uriLen * 2), strip0x(c.p.metadataURIHex), 'metadataURI');

  // the first buy: a Trade event inside the creating transaction, for exactly firstBuy
  const trade = ob.receipt.logs.find((l: any) => l.address === MANAGER && l.topics[0] === topic('Trade(address,address,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint128)'));
  assert.ok(trade, 'a non-zero firstBuy trades inside createToken');
  assert.equal(addr(BigInt(trade.topics[2])), tx.from, 'the buyer is the creator');
  const tr = words(trade.data);
  assert.equal(tr[0], 1n, 'isBuy');
  assert.equal(tr[1], c.p.firstBuy, 'gross amount is firstBuy');
  assert.equal(tr[5], (c.p.firstBuy * BigInt(c.p.taxBuyBps)) / 10000n, 'tax paid into the vault from the creator\'s own money');
  assert.equal(BigInt(tx.value), c.p.listingFee + c.p.firstBuy, 'msg.value = listingFee + firstBuy');
});

test('real OB launch: the calldata is the canonical encoding of what it decodes to', () => {
  const c = decodeCreateToken(ob.transaction.input);
  assert.equal(encodeCreateToken(c), ob.transaction.input);
  assert.equal(canonicalDifference(ob.transaction.input, c), null);
});

const obContext = (sender: string) => ({
  chainId: BigInt(ob.chainId),
  manager: MANAGER,
  sender,
  poolFee: words(ob.before['IgnixManager.POOL_FEE()'])[0],
  launchFactory: addr(words(ob.before['IgnixManager.LAUNCH_FACTORY()'])[0]),
});
const obSigner = addr(words(ob.before['IgnixManager.signer()'])[0]);

test('real OB launch: the platform signature recovers to IgnixManager.signer() over the decoded fields', () => {
  const tx = ob.transaction;
  const c = decodeCreateToken(tx.input);
  const rec = recoverFromSignature(launchDigest(c, obContext(tx.from)), hexToBytes(c.sig));
  assert.equal(rec.problem, null);
  assert.equal(rec.signer, obSigner);
  assert.equal(obSigner, '0x6efa1fad18900b929fe6782fd3eabeac2563416a');
});

test('real OB launch: changing any one decoded field, or the sender, breaks the signature', () => {
  // This is what proves the fields the chain does not expose directly (salt, deadline, listingFee, founder
  // fields, venue): the signer is recovered only when every one of them is decoded exactly.
  const tx = ob.transaction;
  const base = decodeCreateToken(tx.input);
  const recover = (c: CreateTokenCall, sender: string = tx.from): string | null => recoverFromSignature(launchDigest(c, obContext(sender)), hexToBytes(c.sig)).signer;
  assert.equal(recover(base), obSigner);
  const variants: [string, CreateTokenCall][] = [
    ['name', { ...base, p: { ...base.p, nameHex: base.p.nameHex + '21' } }],
    ['symbol', { ...base, p: { ...base.p, symbolHex: '0x4f43' } }],
    ['metadataURI', { ...base, p: { ...base.p, metadataURIHex: base.p.metadataURIHex.slice(0, -2) } }],
    ['salt', { ...base, p: { ...base.p, salt: '0x' + (BigInt(base.p.salt) ^ 1n).toString(16).padStart(64, '0') } }],
    ['quote', { ...base, p: { ...base.p, quote: '0x0000000000000000000000000000000000000001' } }],
    ['graduation', { ...base, p: { ...base.p, graduation: base.p.graduation + 1n } }],
    ['buyFeeBps', { ...base, p: { ...base.p, buyFeeBps: 101 } }],
    ['sellFeeBps', { ...base, p: { ...base.p, sellFeeBps: 101 } }],
    ['taxBuyBps', { ...base, p: { ...base.p, taxBuyBps: 300 } }],
    ['taxSellBps', { ...base, p: { ...base.p, taxSellBps: 300 } }],
    ['snipeStartBps', { ...base, p: { ...base.p, snipeStartBps: 0 } }],
    ['snipeMins', { ...base, p: { ...base.p, snipeMins: 31 } }],
    ['listingFee', { ...base, p: { ...base.p, listingFee: 1n } }],
    ['firstBuy', { ...base, p: { ...base.p, firstBuy: 0n } }],
    ['founderBps', { ...base, p: { ...base.p, founderBps: 1 } }],
    ['founderSecs', { ...base, p: { ...base.p, founderSecs: 1 } }],
    ['founderRoot', { ...base, p: { ...base.p, founderRoot: '0x' + '00'.repeat(31) + '01' } }],
    ['templateId', { ...base, templateId: 0 }],
    ['vaultData', { ...base, vaultData: '0x' + '00'.repeat(31) + '01' }],
    ['deadline', { ...base, deadline: base.deadline + 1n }],
    ['factory', { ...base, factory: '0x0000000000000000000000000000000000000001' }],
    ['venue', { ...base, venue: 0 }],
    ['graduationProtectionSecs', { ...base, graduationProtectionSecs: 86400n }],
  ];
  for (const [field, c] of variants) assert.notEqual(recover(c), obSigner, `${field} is bound by the signature`);
  assert.notEqual(recover(base, '0x84ce7bae1b788c7ad985d57721ca428b401ae34d'), obSigner, 'the sender is bound by the signature');
});

test(`${corpus.count} real Directed launches: each decodes, re-encodes byte for byte and carries the platform signature`, () => {
  assert.ok(corpus.count >= 140, 'the corpus is the one fetched by fixtures/fetch.ts');
  const firstBuyZero: string[] = [];
  for (const l of corpus.launches) {
    const c = decodeCreateToken(l.input);
    assert.equal(encodeCreateToken(c), l.input, `${l.hash} re-encodes exactly`);
    assert.equal(c.templateId, 3, `${l.hash} is a Directed launch`);
    assert.equal(c.venue, 1);
    assert.equal(c.p.buyFeeBps, 100);
    assert.equal(c.p.sellFeeBps, 100);
    assert.ok(c.p.textOk);
    assert.match(decodeRecipient(c.vaultData), /^0x[0-9a-f]{40}$/);
    if (/^0x0{40}$/.test(c.p.quote)) assert.equal(BigInt(l.value), c.p.listingFee + c.p.firstBuy, `${l.hash}: msg.value = listingFee + firstBuy`);
    else assert.equal(BigInt(l.value), 0n, `${l.hash}: an ERC-20 quote sends no native value`);
    // POOL_FEE and LAUNCH_FACTORY did not change over the range of these launches, so one context serves all
    const rec = recoverFromSignature(launchDigest(c, obContext(l.from)), hexToBytes(c.sig));
    assert.equal(rec.signer, obSigner, `${l.hash}: signed by the platform signer over the decoded fields`);
    if (c.p.firstBuy === 0n && c.p.snipeStartBps === 0) firstBuyZero.push(l.hash);
  }
  // The platform does sign launches with firstBuy 0 and anti-snipe off (the reference token's shape).
  assert.ok(firstBuyZero.length >= 10, `${firstBuyZero.length} of these launches have firstBuy 0 and anti-snipe off`);
});

test('the decoder refuses what the Solidity decoder refuses', () => {
  const { data } = launch();
  assert.throws(() => decodeCreateToken('0x9415aa2a' + data.slice(10)), DecodeError, 'another selector');
  assert.throws(() => decodeCreateToken(data.slice(0, 10 + 64 * 5)), DecodeError, 'shorter than the head');
  assert.throws(() => decodeCreateToken(data.slice(0, -64)), DecodeError, 'the signature runs past the end');
  assert.throws(() => decodeCreateToken(data.slice(0, 600)), DecodeError, 'cut in the middle');
  assert.throws(() => decodeCreateToken(data + 'zz'), DecodeError, 'not hex');
  assert.throws(() => decodeCreateToken('0xef44'), DecodeError, 'shorter than a selector');
  // a uint16 word with a bit above bit 15: Solidity reverts when it reads the field
  const args = data.slice(10);
  const dirtyTemplate = CREATE_TOKEN_SELECTOR + args.slice(0, 64) + word(0x10003) + args.slice(128);
  assert.throws(() => decodeCreateToken(dirtyTemplate), /templateId.*uint16/);
  const pAt = 8 * 64; // CreateParams starts right after the eight head words
  const firstBuyWord = pAt + 13 * 64;
  const taxWord = pAt + 8 * 64;
  const dirtyTax = CREATE_TOKEN_SELECTOR + args.slice(0, taxWord) + word(1n << 16n) + args.slice(taxWord + 64);
  assert.throws(() => decodeCreateToken(dirtyTax), /taxBuyBps.*uint16/);
  // an offset that points outside the calldata
  const badOffset = CREATE_TOKEN_SELECTOR + word(1n << 40n) + args.slice(64);
  assert.throws(() => decodeCreateToken(badOffset), /offset/);
  // a first buy written into the word is decoded as such (sanity for the positions used above)
  const withBuy = CREATE_TOKEN_SELECTOR + args.slice(0, firstBuyWord) + word(5n) + args.slice(firstBuyWord + 64);
  assert.equal(decodeCreateToken(withBuy).p.firstBuy, 5n);
});

test('hidden or non-canonical data is reported', () => {
  const { call, data } = launch();
  assert.equal(canonicalDifference(data, call), null);
  assert.equal(canonicalDifference(data.toUpperCase().replace('0X', '0x'), call), null, 'hex case does not matter');
  assert.match(String(canonicalDifference(data + 'deadbeef', call)), /4 extra byte/);
  // dirty padding after the 65-byte signature: Solidity ignores it, a human should not
  const dirty = data.slice(0, -2) + '01';
  assert.equal(decodeCreateToken(dirty).sig, call.sig, 'it still decodes to the same arguments');
  assert.match(String(canonicalDifference(dirty, decodeCreateToken(dirty))), /differs from the canonical encoding/);
});

test('encode and decode are inverse, including empty and non-ASCII strings', () => {
  for (const p of [params(), params({ name: '', symbol: '', metadataURI: '' }), params({ name: '智能时代市场', symbol: 'ÖKB✓', metadataURI: 'ipfs://' + 'x'.repeat(200) })]) {
    const call: CreateTokenCall = { p, templateId: 3, vaultData: '0x' + '00'.repeat(12) + 'ab'.repeat(20), deadline: 1791140000n, factory: '0x48509800895d5735fdc93367ae925579eeff24ae', venue: 1, graduationProtectionSecs: 8640000n, sig: '0x' + '5a'.repeat(65) };
    const back = decodeCreateToken(encodeCreateToken(call));
    assert.deepEqual(back, call);
  }
  const bad = params({ nameHex: '0xff' });
  const c = decodeCreateToken(encodeCreateToken({ p: bad, templateId: 3, vaultData: '0x', deadline: 1n, factory: '0x' + '00'.repeat(20), venue: 1, graduationProtectionSecs: 1n, sig: '0x' }));
  assert.equal(c.p.textOk, false, 'bytes that are not UTF-8 are flagged, not hidden');
});

test('decodeRecipient accepts exactly one address word', () => {
  assert.equal(decodeRecipient('0x000000000000000000000000c12fbf15df59800f39f2ebb34c9cbdce150ae404'), '0xc12fbf15df59800f39f2ebb34c9cbdce150ae404');
  assert.throws(() => decodeRecipient('0x'), /exactly 32/);
  assert.throws(() => decodeRecipient('0x' + '00'.repeat(64)), /exactly 32/);
  assert.throws(() => decodeRecipient('0x01' + '00'.repeat(31)), /above the 20 bytes/);
});
