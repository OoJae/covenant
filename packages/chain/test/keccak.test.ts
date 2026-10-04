import { describe, expect, test } from 'vitest';
import { getAddress, keccak256 as viemKeccak, toHex as viemToHex } from 'viem';
import { checksumAddress, keccak256, keccak256Hex } from '../src/keccak.ts';

const utf8 = (s: string): Uint8Array => new TextEncoder().encode(s);

describe('keccak256', () => {
  test('known answers', () => {
    expect(keccak256Hex(new Uint8Array(0))).toBe('0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470');
    expect(keccak256Hex(utf8('abc'))).toBe('0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45');
    expect(keccak256Hex(utf8('hello'))).toBe('0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8');
    expect(keccak256Hex(utf8('transfer(address,uint256)')).slice(0, 10)).toBe('0xa9059cbb');
    expect(keccak256(new Uint8Array(0)).length).toBe(32);
  });

  test('every length 0..600 against viem (crosses the 136-byte block boundary four times)', () => {
    let seed = 0xc0ffee;
    for (let n = 0; n <= 600; n++) {
      const data = new Uint8Array(n);
      for (let i = 0; i < n; i++) {
        seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
        data[i] = seed >>> 24;
      }
      expect(keccak256Hex(data)).toBe(viemKeccak(viemToHex(data)));
    }
  });

  test('a 40 KB input (netlist-sized)', () => {
    const data = new Uint8Array(40001);
    for (let i = 0; i < data.length; i++) data[i] = (i * 31 + (i >> 8)) & 255;
    expect(keccak256Hex(data)).toBe(viemKeccak(viemToHex(data)));
  });

  test('accepts a plain array as well as a Uint8Array', () => {
    expect(keccak256Hex([0x61, 0x62, 0x63])).toBe(keccak256Hex(utf8('abc')));
  });
});

describe('EIP-55 checksum', () => {
  test('matches viem getAddress', () => {
    const addrs = [
      '0x1f09daefa827f02cbb40967cc91b259763760761',
      '0xaa13ae45b0b2d52f210ad7ef12997113a0ebaf21',
      '0x933fc3aa0c387cb8b6b1d22a2ec3e2b5eecfdb5a',
      '0xca11bde05977b3631167028862be2a173976ca11',
      '0x0000000000000000000000000000000000000000',
      '0xffffffffffffffffffffffffffffffffffffffff',
    ];
    for (const a of addrs) {
      expect(checksumAddress(a)).toBe(getAddress(a));
      expect(checksumAddress(a.toUpperCase().replace('0X', '0x'))).toBe(getAddress(a));
    }
    expect(checksumAddress('0xaa13ae45b0b2d52f210ad7ef12997113a0ebaf21')).toBe('0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21');
  });
});
