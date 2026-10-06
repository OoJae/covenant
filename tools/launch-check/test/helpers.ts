// Test helpers: a throwaway signer, a synthetic launch, and a JSON-RPC server that answers from tables.
//
// THE SIGNER IS NOT A REAL KEY. Its scalar is keccak256 of a fixed label, exactly like forge-std's
// makeAddrAndKey; it exists only so that a test can produce a "platform signature" for a mock Manager.
// The tools themselves cannot sign: the signing code lives here, under test/, and nowhere else.

import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { keccak256 } from '../../../packages/chain/src/keccak.ts';
import { TAPEOUT_FACTORY } from '../checks.ts';
import { MANAGER, encodeCreateToken, launchDigest, selectorOf, type CreateParams, type CreateTokenCall } from '../decode.ts';
import { addressWord, bytesToHex, strip0x, word } from '../hex.ts';
import { ENVELOPE_FIELDS, GLOBALS_FIELDS, encodeStruct, sealedFloorOf, stepFloorOf, type Envelope, type Globals } from '../kernel-abi.ts';
import { N, _internal, addressOfPoint } from '../secp256k1.ts';

const utf8 = new TextEncoder();
const { GX, GY, multiply, affine, inv, mod, bytesToBig, bigTo32 } = _internal;

export interface TestSigner {
  address: string;
  /** 65-byte r || s || v signature (0x hex) of a 32-byte hash. */
  sign(hash: Uint8Array): string;
}

export function testSigner(label: string): TestSigner {
  const d = (bytesToBig(keccak256(utf8.encode(label))) % (N - 1n)) + 1n;
  const pub = affine(multiply([GX, GY, 1n], d));
  if (!pub) throw new Error('testSigner: bad scalar');
  return {
    address: addressOfPoint(pub.x, pub.y),
    sign(hash: Uint8Array): string {
      const z = bytesToBig(hash);
      const seed = new Uint8Array(64);
      seed.set(bigTo32(d), 0);
      seed.set(hash, 32);
      const k = (bytesToBig(keccak256(seed)) % (N - 1n)) + 1n;
      const R = affine(multiply([GX, GY, 1n], k));
      if (!R) throw new Error('testSigner: bad nonce');
      const r = mod(R.x, N);
      let s = mod(inv(k, N) * (z + r * d), N);
      let parity = Number(R.y & 1n);
      if (s > N / 2n) {
        s = N - s;
        parity ^= 1;
      }
      return bytesToHex([...bigTo32(r), ...bigTo32(s), 27 + parity]);
    },
  };
}

export const PLATFORM = testSigner('launch-check tests: mock platform signer (not a real key)');

export const LAUNCHER = '0x84ce7bae1b788c7ad985d57721ca428b401ae34d';
export const KERNEL = '0x00000000000000000000000000000000c0fe0001';
export const CIRCUITS = '0x00000000000000000000000000000000c0fe0002';
export const TRANSISTORS = '0x00000000000000000000000000000000c0fe0003';
export const REGISTRY = '0xce65471a6c6950e17f4b527b20b0af8a8f905311';
export const DIRECTED_FACTORY = '0x48509800895d5735fdc93367ae925579eeff24ae';
export const LAUNCH_FACTORY = '0x5fe101caed11883ee133eb3ffd013f0cd27bb9d3';
export const POOL_FEE = 3000n;
export const CHIP_ID = 7n;
export const KERNEL_FACTORY = '0x00000000000000000000000000000000c0fe0005';
export const FAB = '0x00000000000000000000000000000000c0fe0006';
export const SEALED_VM = '0x00000000000000000000000000000000c0fe0007';

const hexOf = (s: string): string => bytesToHex(utf8.encode(s));

export function params(over: Partial<CreateParams> = {}): CreateParams {
  const base: CreateParams = {
    name: 'Covenant Reference',
    symbol: 'CVREF',
    metadataURI: 'https://api.ignix.bot/v1/ignix/meta/0x0000000000000000000000000000000000000000',
    nameHex: '',
    symbolHex: '',
    metadataURIHex: '',
    textOk: true,
    salt: '0x' + '11'.repeat(32),
    quote: '0x0000000000000000000000000000000000000000',
    graduation: 85n * 10n ** 18n,
    buyFeeBps: 100,
    sellFeeBps: 100,
    taxBuyBps: 300,
    taxSellBps: 300,
    snipeStartBps: 0,
    snipeMins: 0,
    listingFee: 0n,
    firstBuy: 0n,
    founderBps: 0,
    founderSecs: 0,
    founderRoot: '0x' + '00'.repeat(32),
  };
  const p = { ...base, ...over };
  if (over.nameHex === undefined) p.nameHex = hexOf(p.name);
  if (over.symbolHex === undefined) p.symbolHex = hexOf(p.symbol);
  if (over.metadataURIHex === undefined) p.metadataURIHex = hexOf(p.metadataURI);
  return p;
}

export interface LaunchOptions {
  p?: Partial<CreateParams>;
  call?: Partial<Omit<CreateTokenCall, 'p' | 'sig'>>;
  /** The launcher the platform "signed" for. */
  sender?: string;
  signer?: TestSigner;
  now?: bigint;
  /** The Manager's POOL_FEE() and LAUNCH_FACTORY() the platform signs over (default: the values on X Layer). */
  poolFee?: bigint;
  launchFactory?: string;
}

/** A launch that satisfies every rule (first buy 0, anti-snipe off, recipient = KERNEL), signed by the mock platform. */
export function launch(o: LaunchOptions = {}): { call: CreateTokenCall; data: string } {
  const now = o.now ?? BigInt(Math.floor(Date.now() / 1000));
  const call: CreateTokenCall = {
    p: params(o.p),
    templateId: 3,
    vaultData: '0x' + addressWord(KERNEL),
    deadline: now + 1800n,
    factory: DIRECTED_FACTORY,
    venue: 1,
    graduationProtectionSecs: 8_640_000n,
    sig: '0x',
    ...o.call,
  };
  const digest = launchDigest(call, { chainId: 196, manager: MANAGER, sender: o.sender ?? LAUNCHER, poolFee: o.poolFee ?? POOL_FEE, launchFactory: o.launchFactory ?? LAUNCH_FACTORY });
  call.sig = (o.signer ?? PLATFORM).sign(digest);
  return { call, data: encodeCreateToken(call) };
}

export const ENVELOPE: Envelope = {
  launcher: LAUNCHER,
  epochLen: 900n,
  allowancePayee: '0x00000000000000000000000000000000c0fe0004',
  capT: 64n,
  capV: 0n,
  allowCumBps: 2500n,
  ceilMax: 1023n,
  relMax: 256n,
  floorRel: 8n,
  floorMin: 399n,
  fallbackEpochs: 96n,
  fbAllow: 0n,
  buyEnabled: true,
  sink: '0x0000000000000000000000000000000000000000',
};

export const GLOBALS: Globals = {
  manager: MANAGER,
  v2Router: '0x182a927119d56008d921126764bf884221b10f59',
  wokb: '0xe538905cf8410324e03a5a23c1c177a474d59b2b',
  factory: KERNEL_FACTORY,
  circuits: CIRCUITS,
  fab: FAB,
  sealedVM: SEALED_VM,
  beacon: '0xf70d1ed4f62cf3780157b0b421b7e2f45bd0991c',
  impl0: '0x977f217887e085d298cb3819cdad5a0ee35f29b2',
  impl0Hash: '0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30',
  snapshot: '0x00000000000000000000000000000000c0fe0008',
  netlistHash: '0x' + '22'.repeat(32),
  chipId: CHIP_ID,
  nState: 16n,
  gateCount: 1800n,
  netlistLen: 12000n,
  stepFloor: stepFloorOf(1800n, 16n), // 4,892,800
  sealedFloor: sealedFloorOf(1800n, 16n), // 403,200
};

// ───────────────────────────── a JSON-RPC server answering from tables ─────────────────────────────

export interface World {
  chainId: bigint;
  blockNumber: bigint;
  timestamp: bigint;
  /** address (lower case) -> runtime code hex */
  code: Map<string, string>;
  /** address (lower case) -> balance */
  balance: Map<string, bigint>;
  /** `${to}:${selector}` -> return data, or a function of the full calldata. `null` makes the call revert. */
  calls: Map<string, string | null | ((data: string) => string | null)>;
  /** Methods that fail with a JSON-RPC error. */
  broken: Set<string>;
  /** Every method name received, in order. */
  seen: string[];
}

const w32 = (v: bigint | number): string => '0x' + word(v);
const a32 = (a: string): string => '0x' + addressWord(a);

/** A chain on which the synthetic launch of `launch()` passes every check. */
export function goodWorld(now: bigint = BigInt(Math.floor(Date.now() / 1000))): World {
  const world: World = {
    chainId: 196n,
    blockNumber: 72_400_000n,
    timestamp: now,
    code: new Map([
      [KERNEL, '0x' + '60'.repeat(45)],
      [CIRCUITS, '0x' + '60'.repeat(120)],
      [MANAGER, '0x' + '60'.repeat(200)],
    ]),
    balance: new Map([[LAUNCHER, 573n * 10n ** 15n]]),
    calls: new Map(),
    broken: new Set(),
    seen: [],
  };
  const set = (to: string, signature: string, ret: string | null | ((data: string) => string | null)): void => {
    world.calls.set(`${to}:${selectorOf(signature)}`, ret);
  };
  set(MANAGER, 'signer()', a32(PLATFORM.address));
  set(MANAGER, 'POOL_FEE()', w32(POOL_FEE));
  set(MANAGER, 'LAUNCH_FACTORY()', a32(LAUNCH_FACTORY));
  set(MANAGER, 'REGISTRY()', a32(REGISTRY));
  set(MANAGER, 'pausedUntil(uint256)', w32(0));
  set(REGISTRY, 'factoryOf(uint16)', (data) => (BigInt('0x' + strip0x(data).slice(8)) === 3n ? a32(DIRECTED_FACTORY) : a32('0x' + '00'.repeat(20))));
  set(KERNEL, 'token()', a32('0x' + '00'.repeat(20)));
  set(KERNEL, 'chipId()', w32(CHIP_ID));
  set(KERNEL, 'envelope()', encodeStruct(ENVELOPE_FIELDS, { ...ENVELOPE }));
  set(KERNEL, 'globals()', encodeStruct(GLOBALS_FIELDS, { ...GLOBALS }));
  set(TAPEOUT_FACTORY, 'isCPU(address)', (data) => w32(strip0x(data).slice(8 + 24) === strip0x(CIRCUITS) ? 1 : 0));
  set(CIRCUITS, 'transistors()', a32(TRANSISTORS));
  set(CIRCUITS, 'ownerOf(uint256)', (data) => (BigInt('0x' + strip0x(data).slice(8)) === CHIP_ID ? a32(KERNEL) : null));
  set(KERNEL_FACTORY, 'isKernel(address)', (data) => w32(strip0x(data).slice(8 + 24) === strip0x(KERNEL) ? 1 : 0));
  world.code.set(KERNEL_FACTORY, '0x' + '60'.repeat(80));
  return world;
}

export const setCall = (world: World, to: string, signature: string, ret: string | null | ((data: string) => string | null)): void => {
  world.calls.set(`${to.toLowerCase()}:${selectorOf(signature)}`, ret);
};

type RpcReq = { id: number; method: string; params: unknown[] };

function answer(world: World, req: RpcReq): Record<string, unknown> {
  world.seen.push(req.method);
  const ok = (result: unknown): Record<string, unknown> => ({ jsonrpc: '2.0', id: req.id, result });
  const err = (code: number, message: string, data?: string): Record<string, unknown> => ({ jsonrpc: '2.0', id: req.id, error: { code, message, data } });
  if (world.broken.has(req.method)) return err(-32000, `${req.method} is broken in this test`);
  switch (req.method) {
    case 'eth_chainId':
      return ok('0x' + world.chainId.toString(16));
    case 'eth_blockNumber':
      return ok('0x' + world.blockNumber.toString(16));
    case 'eth_getBlockByNumber':
      return ok({ number: '0x' + world.blockNumber.toString(16), timestamp: '0x' + world.timestamp.toString(16), hash: '0x' + 'ab'.repeat(32), transactions: [] });
    case 'eth_getCode':
      return ok(world.code.get(String(req.params[0]).toLowerCase()) ?? '0x');
    case 'eth_getBalance':
      return ok('0x' + (world.balance.get(String(req.params[0]).toLowerCase()) ?? 0n).toString(16));
    case 'eth_call': {
      const { to, data } = req.params[0] as { to: string; data: string };
      const key = `${to.toLowerCase()}:${data.slice(0, 10)}`;
      if (!world.calls.has(key)) return ok('0x'); // an address without code, or without that function
      const entry = world.calls.get(key);
      const ret = typeof entry === 'function' ? entry(data) : entry;
      return ret === null || ret === undefined ? err(3, 'execution reverted', '0x') : ok(ret);
    }
    default:
      return err(-32601, `method ${req.method} is not available in this test`);
  }
}

export interface MockRpc {
  url: string;
  close(): Promise<void>;
}

export async function serve(world: World): Promise<MockRpc> {
  const server: Server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const parsed = JSON.parse(body) as RpcReq | RpcReq[];
      const reply = Array.isArray(parsed) ? parsed.map((r) => answer(world, r)) : answer(world, parsed);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(reply));
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((r) => {
        server.closeAllConnections();
        server.close(() => r());
      }),
  };
}
