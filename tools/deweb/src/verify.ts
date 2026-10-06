// The checks behind verify.ts. Each check answers with MATCH, MISMATCH (and the first difference) or
// NOT CHECKED (and why). A check that could not be performed is never reported as a match.

import { XLAYER, createReader, fallbackPathOf, fileInfoOf, listPaths, readFile, type Reader, type Target } from './chain.ts';
import type { FileInfo } from './abi.ts';
import { openGatewayPage, findBrowser, type GatewayPage, type OpenOptions, type Served } from './browser.ts';
import { chunkCountOf, servedContentType, sha256Hex, type SiteFile } from './site.ts';

export type Status = 'MATCH' | 'MISMATCH' | 'NOT CHECKED';

export interface Check {
  name: string;
  status: Status;
  /** What matched, the first difference, or why it was not checked. One sentence. */
  detail: string;
  /** Further facts worth printing under the check. */
  lines: string[];
}

const ZERO_HASH = '0x' + '0'.repeat(64);

export interface ChainFile {
  path: string;
  info: FileInfo;
  data: Uint8Array;
  /** SHA-256 of the bytes actually read. */
  sha256: string;
  /** As the gateway judges a file: `ok`, `no-hash` (no hash declared) or `incomplete` (size or hash differs). */
  state: 'ok' | 'no-hash' | 'incomplete';
}

export interface ChainSite {
  /** Paths in the registry's order. */
  paths: string[];
  fallback: string;
  files: ChainFile[];
}

/** Reads the whole site of a container from the chain: path list, fallback, and every file's bytes. */
export async function readChainSite(reader: Reader, container: string, onFile?: (path: string, bytes: number) => void): Promise<ChainSite> {
  const paths = await listPaths(reader, container);
  const fallback = await fallbackPathOf(reader, container);
  const files: ChainFile[] = [];
  for (const path of paths) {
    const info = await fileInfoOf(reader, container, path);
    const data = info.chunkCount === 0 ? new Uint8Array() : await readFile(reader, container, path, info.size);
    const sha256 = sha256Hex(data);
    const complete = data.length === info.size;
    const hashed = info.sha256 !== ZERO_HASH;
    files.push({ path, info, data, sha256, state: !complete || (hashed && info.sha256 !== sha256) ? 'incomplete' : hashed ? 'ok' : 'no-hash' });
    onFile?.(path, data.length);
  }
  return { paths, fallback, files };
}

const hex2 = (v: number): string => '0x' + v.toString(16).padStart(2, '0');

/** Where two byte strings first differ, in words; null when they are identical. */
export function firstDifference(a: Uint8Array, b: Uint8Array, nameA: string, nameB: string): string | null {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return `byte ${i.toLocaleString('en-US')} differs (${nameA} ${hex2(a[i])}, ${nameB} ${hex2(b[i])})`;
  }
  if (a.length !== b.length) {
    return `length differs (${nameA} ${a.length.toLocaleString('en-US')} bytes, ${nameB} ${b.length.toLocaleString('en-US')} bytes; identical up to the shorter one)`;
  }
  return null;
}

const bytesOf = (files: readonly { data: Uint8Array }[]): number => files.reduce((s, f) => s + f.data.length, 0);
const count = (n: number, what: string): string => `${n.toLocaleString('en-US')} ${what}${n === 1 ? '' : 's'}`;

/**
 * Every local file against the chain: present, same size, same declared content type and SHA-256, same chunk
 * count and the same bytes. A path that is on chain but not in the local build is a difference unless
 * `allowExtra` is set.
 */
export function compareLocalWithChain(local: readonly SiteFile[], chain: ChainSite, allowExtra: boolean): Check {
  const name = 'Local build = chain';
  const lines: string[] = [];
  const onChain = new Map(chain.files.map((f) => [f.path, f]));
  const mismatch = (detail: string): Check => ({ name, status: 'MISMATCH', detail, lines });
  for (const f of local) {
    const c = onChain.get(f.path);
    if (!c || c.info.chunkCount === 0) return mismatch(`${f.path}: not on chain`);
    const d = firstDifference(f.data, c.data, 'local', 'chain');
    if (d) return mismatch(`${f.path}: ${d}`);
    if (c.info.size !== f.data.length) return mismatch(`${f.path}: size declared on chain is ${c.info.size.toLocaleString('en-US')} bytes, the local file has ${f.data.length.toLocaleString('en-US')}`);
    if (c.info.contentType !== f.contentType) return mismatch(`${f.path}: content type on chain is "${c.info.contentType}", expected "${f.contentType}"`);
    if (c.info.sha256 !== f.sha256) return mismatch(`${f.path}: SHA-256 declared on chain is ${c.info.sha256}, the local file's is ${f.sha256}`);
    if (c.info.chunkCount !== chunkCountOf(f.data.length)) return mismatch(`${f.path}: ${c.info.chunkCount} chunks on chain, expected ${chunkCountOf(f.data.length)}`);
    lines.push(`${f.path}: ${f.data.length.toLocaleString('en-US')} bytes, ${f.contentType}, sha256 ${f.sha256}`);
  }
  const localPaths = new Set(local.map((f) => f.path));
  const extra = chain.paths.filter((p) => !localPaths.has(p));
  if (extra.length) {
    if (!allowExtra) return mismatch(`on chain but not in the local build: ${extra[0]}${extra.length > 1 ? ` (and ${extra.length - 1} more)` : ''}`);
    lines.push(`on chain but not in the local build (allowed): ${extra.join(', ')}`);
  }
  return { name, status: 'MATCH', detail: `${count(local.length, 'file')}, ${bytesOf(local).toLocaleString('en-US')} bytes: size, content type, declared SHA-256, chunk count and every byte are identical`, lines };
}

/** What the gateway requires of every file: the bytes have the declared size and the declared SHA-256. */
export function checkSelfConsistent(chain: ChainSite): Check {
  const name = 'Chain bytes match their declared size and SHA-256';
  if (chain.files.length === 0) return { name, status: 'MISMATCH', detail: 'the container holds no file', lines: [] };
  for (const f of chain.files) {
    if (f.info.chunkCount === 0) return { name, status: 'MISMATCH', detail: `${f.path}: listed but has no chunks`, lines: [] };
    if (f.data.length !== f.info.size) return { name, status: 'MISMATCH', detail: `${f.path}: ${f.data.length} bytes read, ${f.info.size} declared (the gateway would refuse it as incomplete)`, lines: [] };
    if (f.info.sha256 === ZERO_HASH) return { name, status: 'MISMATCH', detail: `${f.path}: no SHA-256 declared (the gateway would show it as unverified)`, lines: [] };
    if (f.sha256 !== f.info.sha256) return { name, status: 'MISMATCH', detail: `${f.path}: the bytes hash to ${f.sha256}, declared ${f.info.sha256} (the gateway would refuse it)`, lines: [] };
  }
  return { name, status: 'MATCH', detail: `${count(chain.files.length, 'file')}, ${bytesOf(chain.files).toLocaleString('en-US')} bytes`, lines: [] };
}

/**
 * The gateway adopts a read only when two node operators agree. Reads the same site at the same block through
 * a node of the second operator and compares.
 */
export async function checkSecondOperator(url: string, block: number, container: string, chain: ChainSite): Promise<Check> {
  const host = new URL(url).host;
  const name = `A second node operator (${host}) returns the same site`;
  let other: ChainSite;
  try {
    other = await readChainSite(await createReader([url], block), container);
  } catch (e) {
    return { name, status: 'NOT CHECKED', detail: `${host} did not answer: ${(e as Error).message}`, lines: ['The official gateway needs this operator and OKX to agree; if it stays unreachable the gateway cannot show X Layer sites.'] };
  }
  if (other.paths.join('\n') !== chain.paths.join('\n')) return { name, status: 'MISMATCH', detail: `the path lists differ at block ${block}`, lines: [] };
  if (other.fallback !== chain.fallback) return { name, status: 'MISMATCH', detail: `the fallback paths differ at block ${block}`, lines: [] };
  for (let i = 0; i < chain.files.length; i++) {
    const a = chain.files[i];
    const b = other.files[i];
    if (JSON.stringify(a.info) !== JSON.stringify(b.info)) return { name, status: 'MISMATCH', detail: `${a.path}: fileInfo differs between the two operators`, lines: [] };
    const d = firstDifference(a.data, b.data, 'first operator', 'second operator');
    if (d) return { name, status: 'MISMATCH', detail: `${a.path}: ${d}`, lines: [] };
  }
  return { name, status: 'MATCH', detail: `identical path list, fallback, file records and bytes at block ${block.toLocaleString('en-US')}`, lines: [] };
}

/** The conditions under which the official gateway shows a site at all (TAP-10 section 6.2). */
export function checkResolution(t: Target, now: number = Math.floor(Date.now() / 1000)): Check {
  const name = 'The gateway is allowed to show the site';
  const lines = [`container ${t.container}, on-chain name ${t.name}, holder ${t.holder}`];
  if (!t.implementationsAccepted) return { name, status: 'MISMATCH', detail: 'the SiteRegistry or DomainBinding implementation is not one the gateway accepts: it answers "store-changed" (HTTP 503)', lines };
  if (!t.opened) return { name, status: 'MISMATCH', detail: 'the container is not opened: the gateway answers "not-opened" (HTTP 404)', lines };
  if (!t.live) {
    const was = t.paidUntil ? `it expired ${new Date(t.paidUntil * 1000).toISOString()}` : 'it was never paid';
    return { name, status: 'MISMATCH', detail: `the name is not activated (${was}): the gateway answers "unpaid" (HTTP 402) until DomainBinding.bind is paid`, lines };
  }
  const days = ((t.paidUntil - now) / 86_400).toFixed(1);
  return { name, status: 'MATCH', detail: `opened, accepted implementations, name activated until ${new Date(t.paidUntil * 1000).toISOString()} (${days} days left)`, lines };
}

// ------------------------------------------------------------------ Content-Security-Policy

export interface CspNeed {
  what: string;
  /** The fetch directive that governs it. */
  directive: 'script-src' | 'style-src' | 'img-src' | 'connect-src';
  /** `self`, a scheme such as `data:`, or an absolute URL. */
  source: string;
}

/** What Covenant's site needs from a policy (web/dist: one module script, one imported chunk, one stylesheet, a data: icon, two RPC hosts). */
export const COVENANT_NEEDS: readonly CspNeed[] = [
  { what: 'the module script, loaded from the site itself', directive: 'script-src', source: 'self' },
  { what: 'the script chunk imported on demand, from the site itself', directive: 'script-src', source: 'self' },
  { what: 'the stylesheet, from the site itself', directive: 'style-src', source: 'self' },
  { what: 'the inline data: icon', directive: 'img-src', source: 'data:' },
  { what: 'fetch POST to https://rpc.xlayer.tech', directive: 'connect-src', source: 'https://rpc.xlayer.tech' },
  { what: 'fetch POST to https://xlayerrpc.okx.com', directive: 'connect-src', source: 'https://xlayerrpc.okx.com' },
];

/** Splits a policy into directives. A directive that appears twice keeps its first value, as browsers do. */
export function parseCsp(csp: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const part of csp.split(';')) {
    const [name, ...values] = part.trim().split(/\s+/);
    if (name && !out.has(name.toLowerCase())) out.set(name.toLowerCase(), values);
  }
  return out;
}

/**
 * Whether one policy allows one need. Covers what this project uses: `'self'`, `'none'`, `*`, scheme sources
 * and host sources. Returns the source expression that allows it.
 */
export function cspAllows(csp: string, need: CspNeed): { allowed: boolean; by: string } {
  const policy = parseCsp(csp);
  const list = policy.get(need.directive) ?? policy.get('default-src');
  if (!list) return { allowed: true, by: `no ${need.directive} and no default-src: unrestricted` };
  const directive = policy.has(need.directive) ? need.directive : 'default-src';
  const scheme = need.source === 'self' ? '' : need.source.slice(0, need.source.indexOf(':') + 1);
  for (const raw of list) {
    const s = raw.toLowerCase();
    if (s === "'none'") return { allowed: false, by: `${directive} 'none'` };
    if (need.source === 'self') {
      if (s === "'self'") return { allowed: true, by: `${directive} 'self'` };
      continue;
    }
    if (s === scheme) return { allowed: true, by: `${directive} ${raw}` };
    if (s === '*' && /^(https?|wss?):$/.test(scheme)) return { allowed: true, by: `${directive} *` };
    if (need.source.includes('//')) {
      const host = new URL(need.source).host;
      const bare = s.replace(/^[a-z][a-z0-9+.-]*:\/\//, '').replace(/[/:].*$/, '');
      const schemeOk = !s.includes('://') || s.startsWith(scheme + '//');
      if (schemeOk && (bare === host || (bare.startsWith('*.') && host.endsWith(bare.slice(1))))) return { allowed: true, by: `${directive} ${raw}` };
    }
  }
  return { allowed: false, by: `${directive} ${list.join(' ')}` };
}

// ------------------------------------------------------------------ the gateway

/** A plain HTTP GET of the gateway: what a client without a Service Worker receives. */
export async function describeGatewayHttp(url: string): Promise<string> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(20_000), redirect: 'manual' });
    const body = await r.text();
    const bootstrap = body.includes('/.tape/boot.js');
    return `plain HTTP GET ${url} -> ${r.status}, ${r.headers.get('content-type') ?? 'no content type'}, ${body.length.toLocaleString('en-US')} bytes: ${
      bootstrap ? "the gateway's bootstrap page (its server sends this for every path; site files are produced in the browser)" : 'NOT the bootstrap page'
    }`;
  } catch (e) {
    return `plain HTTP GET ${url} failed: ${(e as Error).message}`;
  }
}

const encodePath = (path: string): string => '/' + path.split('/').map(encodeURIComponent).join('/');

/**
 * The site's origin under a gateway. `gateway` is a domain (`tapekit.org` gives `https://<label>.tapekit.org`)
 * or, for a gateway run locally, a template such as `http://{label}.localhost:8096`.
 */
export function gatewayOrigin(t: Target, gateway: string = XLAYER.gateway): string {
  return gateway.includes('://') ? gateway.replace('{label}', t.host).replace(/\/+$/, '') : `https://${t.host}.${gateway}`;
}

export interface GatewayOptions extends OpenOptions {
  /** Gateway domain (default tapekit.org) or an origin template, see `gatewayOrigin`. */
  gateway?: string;
  /** After the page loaded, wait for this CSS selector: evidence that the site's script ran. */
  expectSelector?: string;
  /** Needs to check against the policy the gateway sends. */
  needs?: readonly CspNeed[];
  /** Local files, when a local build is being verified (compared with what the gateway serves, too). */
  local?: readonly SiteFile[];
}

/**
 * Opens the site through the gateway in a headless browser and compares every file the gateway's Service
 * Worker serves with the bytes read from the chain (and with the local build when given).
 */
export async function checkGateway(t: Target, chain: ChainSite, opts: GatewayOptions = {}): Promise<Check> {
  const origin = gatewayOrigin(t, opts.gateway);
  const name = `Chain = what the gateway serves (${new URL(origin).host}, in a browser)`;
  const lines: string[] = [];
  if (!findBrowser(opts.executable)) {
    return { name, status: 'NOT CHECKED', detail: 'no Chromium-family browser found on this machine (pass --browser <path>); the gateway produces site files only inside a browser', lines };
  }
  let page: GatewayPage;
  try {
    page = await openGatewayPage(`${origin}/`, opts);
  } catch (e) {
    return { name, status: 'NOT CHECKED', detail: `the browser could not be driven: ${(e as Error).message}`, lines };
  }
  try {
    if (!page.controlled) return { name, status: 'NOT CHECKED', detail: "the gateway's Service Worker did not take control of the page in time", lines };
    const doc = [...page.documents].reverse().find((d) => d.fromServiceWorker);
    if (!doc) return { name, status: 'NOT CHECKED', detail: 'no document was served by the Service Worker', lines };
    if (doc.status !== 200) {
      const why = doc.headers['x-tape-status'] ? ` (x-tape-status: ${doc.headers['x-tape-status']})` : '';
      const meaning: Record<number, string> = { 402: 'the name is not activated', 404: 'not found, or the container is not opened', 451: 'blocked by the gateway', 502: 'the gateway could not read the chain: its nodes did not answer or did not agree', 503: 'a contract implementation the gateway does not accept' };
      return { name, status: 'MISMATCH', detail: `/ is served as HTTP ${doc.status}${why} instead of the site: ${meaning[doc.status] ?? 'a gateway page'}`, lines };
    }

    const mismatch = (detail: string): Check => ({ name, status: 'MISMATCH', detail, lines });
    const local = new Map((opts.local ?? []).map((f) => [f.path, f]));
    let csp = '';
    for (const f of chain.files) {
      let r: Served;
      try {
        r = await page.fetch(encodePath(f.path));
      } catch (e) {
        return mismatch(`${f.path}: the page could not fetch it: ${(e as Error).message}`);
      }
      if (r.status !== 200) return mismatch(`${f.path}: served as HTTP ${r.status}`);
      const d = firstDifference(f.data, r.body, 'chain', 'gateway');
      if (d) return mismatch(`${f.path}: ${d}`);
      const l = local.get(f.path);
      const dl = l ? firstDifference(l.data, r.body, 'local', 'gateway') : null;
      if (dl) return mismatch(`${f.path}: ${dl}`);
      const type = servedContentType(f.info.contentType);
      if (r.headers['content-type'] !== type) return mismatch(`${f.path}: content-type header is "${r.headers['content-type']}", expected "${type}"`);
      if (r.headers['x-tape-sha256'] !== f.sha256) return mismatch(`${f.path}: x-tape-sha256 is ${r.headers['x-tape-sha256']}, the bytes hash to ${f.sha256}`);
      if (r.headers['x-tape-verified'] !== '1') return mismatch(`${f.path}: x-tape-verified is "${r.headers['x-tape-verified']}", expected "1"`);
      if (r.headers['x-tape-name'] !== t.name) return mismatch(`${f.path}: x-tape-name is "${r.headers['x-tape-name']}", expected "${t.name}"`);
      if ((r.headers['x-tape-container'] ?? '').toLowerCase() !== t.container.toLowerCase()) return mismatch(`${f.path}: x-tape-container is ${r.headers['x-tape-container']}, expected ${t.container}`);
      csp ||= r.headers['content-security-policy'] ?? '';
      lines.push(`${f.path}: 200, ${r.body.length.toLocaleString('en-US')} bytes identical, ${r.headers['content-type']}, x-tape-verified 1`);
    }

    // the root path, and paths that do not exist
    const index = chain.files.find((f) => f.path === 'index.html');
    if (index) {
      const root = await page.fetch('/');
      const d = root.status !== 200 ? `HTTP ${root.status}` : firstDifference(index.data, root.body, 'chain index.html', 'gateway /');
      if (d) return mismatch(`/: ${d}`);
      lines.push('/: serves index.html');
    }
    const probe = 'deweb-verify-' + Math.random().toString(16).slice(2, 10);
    const missingFile = await page.fetch(`/${probe}.png`);
    if (missingFile.status !== 404) return mismatch(`/${probe}.png (no such file): HTTP ${missingFile.status}, expected 404`);
    lines.push('an unknown path with an extension: 404');
    const missingRoute = await page.fetch(`/${probe}`);
    const fallback = chain.files.find((f) => f.path === chain.fallback);
    if (fallback) {
      const d = missingRoute.status !== 200 ? `HTTP ${missingRoute.status}` : firstDifference(fallback.data, missingRoute.body, `chain ${chain.fallback}`, 'gateway');
      if (d) return mismatch(`/${probe} (unknown path, fallback ${chain.fallback}): ${d}`);
      lines.push(`an unknown path without an extension: serves the fallback, ${chain.fallback}`);
    } else {
      if (missingRoute.status !== 404) return mismatch(`/${probe} (unknown path, no fallback set): HTTP ${missingRoute.status}, expected 404`);
      lines.push('an unknown path without an extension: 404 (no fallback is set)');
    }

    // the gateway's own account of the site
    try {
      const status = JSON.parse(new TextDecoder().decode((await page.fetch('/.tape/status?json=1')).body)) as Record<string, any>;
      lines.push(`gateway status page: version ${status.version}, status ${status.status}, read at block ${Number(status.block).toLocaleString('en-US')}, paid via ${status.paidVia}`);
      const off = [...(status.offchain ?? []), ...(status.external ?? []), ...(status.blocked ?? [])].map((x: any) => String(x.url));
      lines.push(off.length ? `gateway status page lists off-chain access: ${[...new Set(off)].join(', ')}` : 'gateway status page lists no off-chain reference or request');
      if (status.status !== 'ok') return mismatch(`the gateway's status page says "${status.status}"`);
    } catch (e) {
      lines.push(`gateway status page could not be read: ${(e as Error).message}`);
    }

    if (csp) {
      lines.push(`content-security-policy: ${csp}`);
      for (const need of opts.needs ?? []) {
        const a = cspAllows(csp, need);
        lines.push(`  ${a.allowed ? 'allowed' : 'REFUSED'}: ${need.what} (${a.by})`);
        if (!a.allowed) return mismatch(`the gateway's Content-Security-Policy refuses ${need.what}`);
      }
    }

    if (opts.expectSelector) {
      const found = await page.waitForSelector(opts.expectSelector, 20_000);
      if (!found) return mismatch(`the page did not render "${opts.expectSelector}" within 20 s (did the site's script run?)`);
      lines.push(`the page rendered "${opts.expectSelector}": the site's script ran under the gateway`);
    }
    const blocked = page.problems.filter((p) => /content security policy|refused to|blocked/i.test(p));
    if (blocked.length) return mismatch(`the browser reported: ${blocked[0]}`);
    // a 404 for the probes above is expected; anything else is worth showing
    const other = page.problems.filter((p) => !p.includes(probe) && !/favicon\.ico/.test(p));
    for (const p of other) lines.push(`browser console: ${p}`);

    return { name, status: 'MATCH', detail: `${count(chain.files.length, 'file')}, ${bytesOf(chain.files).toLocaleString('en-US')} bytes served byte for byte, with the declared content types, each marked verified by the gateway`, lines };
  } finally {
    await page.close();
  }
}

/** `12-2-231`, `12.2.231`, `12.2.231.tape`, `#12@2.231`, or a gateway URL: the circuit id and processor number on X Layer. */
export function parseSite(text: string): { circuitId: bigint; processorNumber: number } {
  // a display label starts with "#" (#12@2.231): keep it; anywhere else "#" starts a URL fragment
  const raw = text.trim().replace(/^(web\+)?tape:\/\//i, '').replace(/^https?:\/\//i, '');
  let s = raw.startsWith('#') ? raw : raw.split(/[/?#]/)[0];
  const label = /^([1-9][0-9]*)-([1-9][0-9]*)-(0|[1-9][0-9]*)(\..+)?$/.exec(s);
  s = s.replace(/\.tape$/i, '');
  const dotted = /^#?([1-9][0-9]*)[.@]([1-9][0-9]*)\.(0|[1-9][0-9]*)$/.exec(s);
  const m = label ?? dotted;
  if (!m) throw new Error(`not an X Layer site name: ${text} (expected <id>-2-<processor number>, <id>.2.<processor number>.tape or a gateway URL)`);
  if (Number(m[2]) !== XLAYER.areaCode) throw new Error(`area code ${m[2]} is not X Layer (2): ${text}`);
  return { circuitId: BigInt(m[1]), processorNumber: Number(m[3]) };
}

/**
 * MATCH only when every check that ran matched; a difference wins over an unperformed check. `omitted` names
 * the checks that were switched off on the command line, so the verdict says what it does not cover.
 */
export function verdictOf(checks: readonly Check[], omitted: readonly string[] = []): { status: Status; line: string; exitCode: number } {
  const left = omitted.length ? ` Left out on request: ${omitted.join('; ')}.` : '';
  const bad = checks.find((c) => c.status === 'MISMATCH');
  if (bad) return { status: 'MISMATCH', line: `MISMATCH: ${bad.name}: ${bad.detail}`, exitCode: 1 };
  const skipped = checks.filter((c) => c.status === 'NOT CHECKED');
  if (skipped.length) {
    const done = checks.filter((c) => c.status === 'MATCH').map((c) => c.name);
    return {
      status: 'NOT CHECKED',
      line: `NOT FULLY VERIFIED. No difference found${done.length ? ` in: ${done.join('; ')}` : ''}. Could not be checked: ${skipped.map((c) => `${c.name} (${c.detail})`).join('; ')}.${left}`,
      exitCode: 3,
    };
  }
  return { status: 'MATCH', line: `MATCH in every check that ran: ${checks.map((c) => c.name).join('; ')}.${left}`, exitCode: 0 };
}
