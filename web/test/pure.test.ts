// The parts of the site that need neither a browser nor the network.

import { describe, expect, test } from 'vitest';
import addresses from '../src/addresses.json' with { type: 'json' };
import { EXAMPLES } from '../src/config.ts';
import { beatMethod, castFacts, castLine, packedFromHex } from '../src/data/circuit.ts';
import { cleanHex, fmtInt, fmtUnits, isAddress, parseTarget, shortAddress, shortHex, targetHash } from '../src/format.ts';
import { parseRoute } from '../src/router.ts';

const TRIVIUM = '0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a';

describe('addresses.json', () => {
  test('has exactly the agreed keys, so another team can write it by script', () => {
    expect(Object.keys(addresses).sort()).toEqual(['factory', 'probeCircuitId', 'processor', 'rpc']);
    expect(isAddress(addresses.factory)).toBe(true);
    expect(addresses.factory.toLowerCase()).toBe('0x1f09daefa827f02cbb40967cc91b259763760761');
    expect(addresses.rpc).toEqual(['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com']);
    const processor: string | null = addresses.processor;
    expect(processor === null || isAddress(processor)).toBe(true);
  });

  test('the examples offered while processor is null are well-formed', () => {
    expect(EXAMPLES.length).toBeGreaterThanOrEqual(2);
    for (const x of EXAMPLES) {
      expect(isAddress(x.processor)).toBe(true);
      expect(Number.isInteger(x.id) && x.id >= 1).toBe(true);
    }
    expect(EXAMPLES.map((x) => `${x.processor}/${x.id}`)).toContain(`${TRIVIUM}/1`);
    expect(EXAMPLES.map((x) => `${x.processor}/${x.id}`)).toContain('0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21/3');
  });
});

describe('routes', () => {
  test('the five pages', () => {
    expect(parseRoute('')).toEqual({ page: 'landing' });
    expect(parseRoute('#')).toEqual({ page: 'landing' });
    expect(parseRoute('#/')).toEqual({ page: 'landing' });
    expect(parseRoute(`#/p/${TRIVIUM}`)).toEqual({ page: 'processor', processor: TRIVIUM });
    expect(parseRoute(`#/c/${TRIVIUM}/1`)).toEqual({ page: 'circuit', processor: TRIVIUM, id: '1' });
    expect(parseRoute(`#/c/${TRIVIUM}/007`)).toEqual({ page: 'circuit', processor: TRIVIUM, id: '7' });
    expect(parseRoute('#/judge')).toEqual({ page: 'judge' });
    expect(parseRoute('#/trust')).toEqual({ page: 'trust' });
    expect(parseRoute('#/trust/')).toEqual({ page: 'trust' });
  });

  test('anything else is "not found", never an exception', () => {
    for (const h of ['#/p/0x123', '#/p/', `#/c/${TRIVIUM}`, `#/c/${TRIVIUM}/x`, `#/c/${TRIVIUM}/-1`, `#/c/${TRIVIUM}/1/2`, '#/judge/x', '#/%E0%A4%A', '#/whatever', `#/p/${TRIVIUM}/1`]) {
      expect(parseRoute(h)).toEqual({ page: 'notfound', hash: h });
    }
  });

  test('a circuit id as large as a u64 survives', () => {
    expect(parseRoute(`#/c/${TRIVIUM}/18446744073709551615`)).toEqual({ page: 'circuit', processor: TRIVIUM, id: '18446744073709551615' });
  });
});

describe('the open box', () => {
  test('an address alone opens the processor', () => {
    expect(parseTarget(TRIVIUM)).toEqual({ processor: TRIVIUM, id: null });
    expect(parseTarget(`  ${TRIVIUM}  `)).toEqual({ processor: TRIVIUM, id: null });
    expect(targetHash({ processor: TRIVIUM, id: null })).toBe(`#/p/${TRIVIUM}`);
  });

  test('an address followed by a number opens that circuit', () => {
    for (const text of [`${TRIVIUM} 1`, `${TRIVIUM}/1`, `${TRIVIUM}#1`, `${TRIVIUM}:1`, `${TRIVIUM}, 1`, `${TRIVIUM} circuit 1`, `${TRIVIUM} id=1`, `${TRIVIUM} #01`]) {
      expect(parseTarget(text), text).toEqual({ processor: TRIVIUM, id: '1' });
    }
    expect(targetHash({ processor: TRIVIUM, id: '3' })).toBe(`#/c/${TRIVIUM}/3`);
  });

  test('a pasted explorer link or site link works', () => {
    expect(parseTarget(`https://www.oklink.com/xlayer/address/${TRIVIUM}`)).toEqual({ processor: TRIVIUM, id: null });
    expect(parseTarget(`https://example.org/#/c/${TRIVIUM}/1`)).toEqual({ processor: TRIVIUM, id: '1' });
  });

  test('text without an address, or with a longer hex string, is refused', () => {
    expect(parseTarget('')).toBeNull();
    expect(parseTarget('hello')).toBeNull();
    expect(parseTarget('0x1234')).toBeNull();
    // a 32-byte hash is not an address
    expect(parseTarget('0x68c5f5d81225f000849f0ae9aaf594753a8a124f78dadc590a053811ea783960')).toBeNull();
  });

  test('trailing text that is not a circuit id is ignored rather than guessed at', () => {
    expect(parseTarget(`${TRIVIUM} and some words`)).toEqual({ processor: TRIVIUM, id: null });
    expect(parseTarget(`${TRIVIUM}?tab=1&x=2`)).toEqual({ processor: TRIVIUM, id: null });
  });
});

describe('formatting', () => {
  test('integers with thousands separators', () => {
    expect(fmtInt(0)).toBe('0');
    expect(fmtInt(999)).toBe('999');
    expect(fmtInt(1000)).toBe('1,000');
    expect(fmtInt(4863)).toBe('4,863');
    expect(fmtInt(67108864n)).toBe('67,108,864');
    expect(fmtInt(-1234567)).toBe('-1,234,567');
    expect(fmtInt(2n ** 64n)).toBe('18,446,744,073,709,551,616');
  });

  test('wei as OKB', () => {
    expect(fmtUnits(0n)).toBe('0');
    expect(fmtUnits(20000000000000n)).toBe('0.00002');
    expect(fmtUnits(10n ** 18n)).toBe('1');
    expect(fmtUnits(1234500000000000000000n)).toBe('1,234.5');
    expect(fmtUnits(1n)).toBe('0.000000000000000001');
    expect(fmtUnits(26000000000000000n)).toBe('0.026');
    expect(fmtUnits(1500000n, 6)).toBe('1.5');
  });

  test('shortening', () => {
    expect(shortAddress(TRIVIUM)).toBe('0x933F…Db5a');
    expect(shortHex('0x00')).toBe('0x00');
    expect(shortHex('0x' + 'ab'.repeat(40))).toBe('0xababababab…ababababab');
  });

  test('hex typed by a user', () => {
    expect(cleanHex('0xAbCd')).toBe('abcd');
    expect(cleanHex('ab cd_ef')).toBe('abcdef');
    expect(cleanHex('')).toBe('');
    expect(cleanHex('0x')).toBe('');
    expect(cleanHex('abc')).toBeNull();
    expect(cleanHex('zz')).toBeNull();
    // packed to exactly ceil(n / 8) bytes, padding bits cleared, missing bytes zero
    expect(Array.from(packedFromHex('ff', 3))).toEqual([0x07]);
    expect(Array.from(packedFromHex('', 9))).toEqual([0, 0]);
    expect(Array.from(packedFromHex('0102030405', 16))).toEqual([1, 2]);
  });
});

describe('the printed cast commands', () => {
  const state = Uint8Array.of(0x01, 0x02);
  const inputs = Uint8Array.of(0xff);

  test('step for a circuit with state, eval for one without', () => {
    expect(beatMethod(288)).toBe('step');
    expect(beatMethod(0)).toBe('eval');
    expect(castLine(TRIVIUM, 1n, 288, state, inputs, 'https://rpc.xlayer.tech')).toBe(
      `cast call ${TRIVIUM} "step(uint256,bytes,bytes)(bytes,bytes)" 1 0x0102 0xff --rpc-url https://rpc.xlayer.tech`,
    );
    expect(castLine(TRIVIUM, 7n, 0, new Uint8Array(0), inputs, 'https://rpc.xlayer.tech')).toBe(
      `cast call ${TRIVIUM} "eval(uint256,bytes)(bytes)" 7 0xff --rpc-url https://rpc.xlayer.tech`,
    );
    // no inputs at all is the empty byte string
    expect(castLine(TRIVIUM, 4n, 2, Uint8Array.of(1), new Uint8Array(0), 'u')).toBe(
      `cast call ${TRIVIUM} "step(uint256,bytes,bytes)(bytes,bytes)" 4 0x01 0x --rpc-url u`,
    );
  });

  test('facts: circuitInfo, netlist hash, owner', () => {
    const lines = castFacts(TRIVIUM, 1n, 'https://rpc.xlayer.tech').map((f) => f.line);
    expect(lines).toEqual([
      `cast call ${TRIVIUM} "circuitInfo(uint256)(uint32,uint32,uint32,uint32)" 1 --rpc-url https://rpc.xlayer.tech`,
      `cast call ${TRIVIUM} "netlist(uint256)(bytes)" 1 --rpc-url https://rpc.xlayer.tech | cast keccak`,
      `cast call ${TRIVIUM} "ownerOf(uint256)(address)" 1 --rpc-url https://rpc.xlayer.tech`,
    ]);
  });
});
