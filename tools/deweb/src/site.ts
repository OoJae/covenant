// A site directory as the DeWEB registry stores it: paths, content types, SHA-256 and 24,000-byte chunks.
// The same rules are implemented in Solidity in sim/src/SitePublisher.sol; test/plan-vs-fork.test.ts
// checks that both produce byte-identical calldata.

import { createHash } from 'node:crypto';
import { lstatSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/** `SiteRegistry.CHUNK_MAX`: the most bytes one putFile or appendChunk may carry. */
export const CHUNK_MAX = 24_000;
/** `SiteRegistry.CHUNKS_MAX`: the most chunks one file may have (8,400,000 bytes). */
export const CHUNKS_MAX = 350;
/** Above this size the gateway reads a file with `readRange` in segments of this many bytes. */
export const RANGE_BYTES = 98_304;

export interface SiteFile {
  /** Relative to the site directory, `/` separators, no leading slash. */
  path: string;
  contentType: string;
  /** 0x-prefixed lower-case SHA-256 of the bytes. */
  sha256: string;
  data: Uint8Array;
}

/**
 * Content type by file extension (case-insensitive). Keep in step with `contentTypeOf` in
 * sim/src/SitePublisher.sol. The gateway keeps only letters, digits and `_ . + / ; = -` and space of
 * what is declared, and adds `; charset=utf-8` itself to text types that lack it.
 */
export const CONTENT_TYPES: Readonly<Record<string, string>> = {
  html: 'text/html; charset=utf-8',
  htm: 'text/html; charset=utf-8',
  js: 'text/javascript; charset=utf-8',
  mjs: 'text/javascript; charset=utf-8',
  css: 'text/css; charset=utf-8',
  json: 'application/json; charset=utf-8',
  map: 'application/json; charset=utf-8',
  webmanifest: 'application/manifest+json; charset=utf-8',
  txt: 'text/plain; charset=utf-8',
  xml: 'application/xml; charset=utf-8',
  svg: 'image/svg+xml',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  avif: 'image/avif',
  ico: 'image/x-icon',
  woff2: 'font/woff2',
  woff: 'font/woff',
  ttf: 'font/ttf',
  otf: 'font/otf',
  wasm: 'application/wasm',
  pdf: 'application/pdf',
  mp4: 'video/mp4',
  webm: 'video/webm',
  mp3: 'audio/mpeg',
};
export const DEFAULT_CONTENT_TYPE = 'application/octet-stream';

/** Lower-cased text after the last `.` of the file name; empty when there is none. */
export function extensionOf(path: string): string {
  const name = path.slice(path.lastIndexOf('/') + 1);
  const dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.slice(dot + 1).replace(/[A-Z]/g, (c) => c.toLowerCase());
}

export function contentTypeOf(path: string): string {
  const ext = extensionOf(path);
  return Object.hasOwn(CONTENT_TYPES, ext) ? CONTENT_TYPES[ext] : DEFAULT_CONTENT_TYPE;
}

/** True when the extension is not in the table, so the file is declared as `application/octet-stream`. */
export const isUnknownType = (path: string): boolean => !Object.hasOwn(CONTENT_TYPES, extensionOf(path));

/**
 * What the gateway does to a declared content type before it becomes a response header
 * (TAP-10 section 7.1 step 6, TapeKit `safeContentType` and `withCharset`).
 */
export function servedContentType(declared: string): string {
  const s = declared.replace(/[^\w.+/;=\- ]/g, '').slice(0, 100);
  const safe = /^[\w.+-]+\/[\w.+-]+/.test(s) ? s : DEFAULT_CONTENT_TYPE;
  return /^(text\/|application\/(javascript|json|xml))/i.test(safe) && !/charset=/i.test(safe) ? safe + '; charset=utf-8' : safe;
}

/**
 * A path the registry can store and the gateway can serve: printable ASCII, no backslash, and not one of
 * the gateway's own paths (`/sw.js`, `/.tape/...`), which are never read from the chain.
 */
export function checkPath(path: string): void {
  if (path.length === 0 || path.length > 512) throw new Error(`bad path length: ${JSON.stringify(path)}`);
  for (let i = 0; i < path.length; i++) {
    const c = path.charCodeAt(i);
    if (c < 0x20 || c > 0x7e || c === 0x5c) throw new Error(`path is not plain ASCII: ${JSON.stringify(path)}`);
  }
  if (path === 'sw.js' || path.startsWith('.tape/')) throw new Error(`path is reserved by the gateway: ${path}`);
}

/** Number of chunks a file of `length` bytes occupies (an empty file still has one chunk). */
export const chunkCountOf = (length: number): number => (length === 0 ? 1 : Math.ceil(length / CHUNK_MAX));

/** The file's bytes in chunks of at most 24,000. */
export function chunksOf(data: Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (let c = 0; c < chunkCountOf(data.length); c++) out.push(data.subarray(c * CHUNK_MAX, (c + 1) * CHUNK_MAX));
  return out;
}

export const sha256Hex = (data: Uint8Array): string => '0x' + createHash('sha256').update(data).digest('hex');

const isHtml = (f: SiteFile): boolean => f.contentType.startsWith('text/html');

/** Byte order of two ASCII strings. */
const byBytes = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/** Publication order: files that are not HTML, then HTML files; each group sorted by path bytes. */
export function sortFiles(files: SiteFile[]): SiteFile[] {
  return [...files].sort((a, b) => Number(isHtml(a)) - Number(isHtml(b)) || byBytes(a.path, b.path));
}

/** Builds a `SiteFile` from a path and its bytes (used by `loadSite` and by tests). */
export function siteFile(path: string, data: Uint8Array): SiteFile {
  checkPath(path);
  if (data.length > CHUNK_MAX * CHUNKS_MAX) throw new Error(`file larger than 8,400,000 bytes: ${path}`);
  return { path, contentType: contentTypeOf(path), sha256: sha256Hex(data), data };
}

/**
 * Reads every file under `dir`, in publication order. `.DS_Store` files are left out; a symbolic link, a
 * path that is not plain ASCII, a file above 8,400,000 bytes or a missing `index.html` is an error.
 */
export function loadSite(dir: string): SiteFile[] {
  let stat;
  try {
    stat = lstatSync(dir);
  } catch {
    throw new Error(`not a directory: ${dir}`);
  }
  if (!stat.isDirectory()) throw new Error(`not a directory: ${dir}`);

  const files: SiteFile[] = [];
  const walk = (abs: string, rel: string, depth: number): void => {
    if (depth > 32) throw new Error('directory nesting deeper than 32');
    for (const entry of readdirSync(abs, { withFileTypes: true })) {
      const path = rel ? `${rel}/${entry.name}` : entry.name;
      const full = join(abs, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`symbolic link in the site: ${full}`);
      if (entry.isDirectory()) walk(full, path, depth + 1);
      else if (entry.isFile()) {
        if (entry.name === '.DS_Store') continue;
        files.push(siteFile(path, new Uint8Array(readFileSync(full))));
      } else throw new Error(`not a regular file: ${full}`);
    }
  };
  walk(dir, '', 1);
  if (files.length === 0) throw new Error(`no files in ${dir}`);
  if (!files.some((f) => f.path === 'index.html')) throw new Error('the site has no index.html at its root');
  return sortFiles(files);
}
