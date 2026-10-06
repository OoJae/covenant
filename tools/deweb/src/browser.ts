// A minimal driver for a headless Chromium-family browser over the DevTools protocol, with no npm
// dependency (Node's own WebSocket and child_process).
//
// Why a browser at all: the official gateway (tapekit.org) is a Service Worker gateway. Its server sends the
// same bootstrap page for every host and path; the site's files are read from the chain, verified and
// turned into responses inside the visitor's browser. A plain HTTP client therefore never sees the site.
// To compare "what is actually served" the request has to be made by a page the gateway's Service Worker
// controls. This module opens such a page and runs `fetch` inside it.
//
// The browser runs headless with a throw-away profile directory that is deleted afterwards. It does not
// touch the user's own browser profile.

import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';

/** A response as the page received it. */
export interface Served {
  url: string;
  status: number;
  /** Header names are lower case. */
  headers: Record<string, string>;
  body: Uint8Array;
}

/** A main-document response seen while the page loaded. */
export interface DocumentResponse {
  url: string;
  status: number;
  headers: Record<string, string>;
  fromServiceWorker: boolean;
}

export interface GatewayPage {
  /** The document responses of the navigation, in order: the bootstrap first, then what the worker served. */
  documents: DocumentResponse[];
  /** True when the gateway's Service Worker controls the page. */
  controlled: boolean;
  /** Errors the page logged while loading (console errors, uncaught exceptions, blocked requests). */
  problems: string[];
  /** `fetch(path)` from inside the page. Throws when the page's own policy forbids fetching. */
  fetch(path: string): Promise<Served>;
  /** Waits until `document.querySelector(css)` finds an element. False when it does not within `timeout` ms. */
  waitForSelector(css: string, timeout: number): Promise<boolean>;
  /** Evaluates a JavaScript expression in the page (a promise is awaited) and returns its value. */
  evaluate(expression: string): Promise<unknown>;
  close(): Promise<void>;
}

/** Where a Chromium-family browser is usually found. `DEWEB_BROWSER` or `CHROME_PATH` take precedence. */
export function findBrowser(explicit?: string): string | null {
  const candidates: string[] = [];
  if (explicit) candidates.push(explicit);
  for (const v of ['DEWEB_BROWSER', 'CHROME_PATH']) if (process.env[v]) candidates.push(process.env[v] as string);
  if (process.platform === 'darwin') {
    candidates.push(
      '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      '/Applications/Chromium.app/Contents/MacOS/Chromium',
      '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
      '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    );
    // a Chromium that Playwright downloaded, if any
    const cache = join(homedir(), 'Library/Caches/ms-playwright');
    if (existsSync(cache)) {
      for (const d of readdirSync(cache).filter((x) => /^chromium-\d+$/.test(x)).sort().reverse()) {
        for (const arch of ['chrome-mac-arm64', 'chrome-mac']) {
          candidates.push(join(cache, d, arch, 'Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing'), join(cache, d, arch, 'Chromium.app/Contents/MacOS/Chromium'));
        }
      }
    }
  } else if (process.platform === 'win32') {
    for (const base of [process.env['PROGRAMFILES'], process.env['PROGRAMFILES(X86)'], process.env['LOCALAPPDATA']]) {
      if (base) candidates.push(join(base, 'Google/Chrome/Application/chrome.exe'), join(base, 'Microsoft/Edge/Application/msedge.exe'));
    }
  } else {
    candidates.push('/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/microsoft-edge', '/snap/bin/chromium');
  }
  return candidates.find((c) => existsSync(c)) ?? null;
}

interface Pending {
  resolve(value: unknown): void;
  reject(reason: Error): void;
}
interface Message {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: { message?: string };
  sessionId?: string;
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const lowerKeys = (h: Record<string, unknown> | undefined): Record<string, string> =>
  Object.fromEntries(Object.entries(h ?? {}).map(([k, v]) => [k.toLowerCase(), String(v)]));

export interface OpenOptions {
  /** Path of the browser binary; found automatically when omitted. */
  executable?: string;
  /** Milliseconds to wait for the Service Worker to take control. Default 90,000. */
  timeout?: number;
  /** Extra command-line switches for the browser (tests use this to map host names to a local server). */
  extraArgs?: string[];
}

/**
 * Opens `url` in a headless browser, waits until the gateway's Service Worker controls the page (the
 * bootstrap page installs it and reloads), and returns a handle to fetch from inside the page.
 */
export async function openGatewayPage(url: string, opts: OpenOptions = {}): Promise<GatewayPage> {
  const executable = findBrowser(opts.executable);
  if (!executable) throw new Error('no Chromium-family browser found (pass --browser <path> or set DEWEB_BROWSER)');
  const timeout = opts.timeout ?? 90_000;
  const profile = mkdtempSync(join(tmpdir(), 'deweb-verify-'));
  let child: ChildProcess | undefined;
  let ws: WebSocket | undefined;

  const close = async (): Promise<void> => {
    try {
      ws?.close();
    } catch {
      // already closed
    }
    if (child && child.exitCode === null) {
      child.kill('SIGTERM');
      await Promise.race([new Promise((r) => child?.once('exit', r)), sleep(3000)]);
      if (child.exitCode === null) child.kill('SIGKILL');
    }
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 3 });
    } catch {
      // a browser that is slow to exit can still hold files; the directory is in the system's temp folder
    }
  };

  try {
    child = spawn(
      executable,
      [
        '--headless=new',
        '--remote-debugging-port=0',
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-sync',
        '--disable-component-update',
        '--disable-background-networking',
        '--mute-audio',
        ...(opts.extraArgs ?? []),
        'about:blank',
      ],
      { stdio: ['ignore', 'ignore', 'pipe'] },
    );
    const endpoint = await new Promise<string>((resolve, reject) => {
      let text = '';
      const timer = setTimeout(() => reject(new Error(`the browser did not open its DevTools port within 30 s: ${executable}`)), 30_000);
      child?.stderr?.on('data', (d: Buffer) => {
        text += d.toString();
        const m = /DevTools listening on (ws:\/\/\S+)/.exec(text);
        if (m) {
          clearTimeout(timer);
          resolve(m[1]);
        }
      });
      child?.once('exit', (code) => {
        clearTimeout(timer);
        reject(new Error(`the browser exited (code ${code}) before opening its DevTools port: ${executable}`));
      });
      child?.once('error', (e) => {
        clearTimeout(timer);
        reject(e);
      });
    });

    const socket = new WebSocket(endpoint);
    ws = socket;
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener('open', () => resolve(), { once: true });
      socket.addEventListener('error', () => reject(new Error('could not connect to the browser')), { once: true });
    });

    let nextId = 0;
    const pending = new Map<number, Pending>();
    const documents: DocumentResponse[] = [];
    const problems: string[] = [];
    const note = (s: string): void => {
      if (problems.length < 50 && !problems.includes(s)) problems.push(s);
    };
    socket.addEventListener('message', (ev: MessageEvent) => {
      const m = JSON.parse(String(ev.data)) as Message;
      if (m.id !== undefined) {
        const p = pending.get(m.id);
        pending.delete(m.id);
        if (m.error) p?.reject(new Error(m.error.message ?? 'DevTools error'));
        else p?.resolve(m.result);
        return;
      }
      const params = (m.params ?? {}) as Record<string, any>;
      if (m.method === 'Network.responseReceived' && params.type === 'Document') {
        documents.push({
          url: String(params.response?.url ?? ''),
          status: Number(params.response?.status ?? 0),
          headers: lowerKeys(params.response?.headers),
          fromServiceWorker: params.response?.fromServiceWorker === true,
        });
      } else if (m.method === 'Runtime.exceptionThrown') {
        note(`uncaught exception: ${String(params.exceptionDetails?.exception?.description ?? params.exceptionDetails?.text ?? '').slice(0, 300)}`);
      } else if (m.method === 'Log.entryAdded' && params.entry?.level === 'error') {
        note(`${params.entry.source}: ${String(params.entry.text).slice(0, 300)}${params.entry.url ? ` (${String(params.entry.url).slice(0, 200)})` : ''}`);
      } else if (m.method === 'Network.loadingFailed' && params.blockedReason) {
        note(`request blocked: ${params.blockedReason}`);
      }
    });
    const send = (method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<any> =>
      new Promise((resolve, reject) => {
        const id = ++nextId;
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params, sessionId }));
      });

    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    for (const domain of ['Page', 'Runtime', 'Network', 'Log']) await send(`${domain}.enable`, {}, sessionId);
    await send('Page.navigate', { url }, sessionId);

    const evaluate = async (expression: string): Promise<any> => {
      const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(String(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text ?? 'evaluation failed'));
      return r.result?.value;
    };

    // The bootstrap page registers the worker and reloads; execution contexts come and go meanwhile.
    const started = Date.now();
    let controlled = false;
    while (Date.now() - started < timeout) {
      try {
        const state = await evaluate(`navigator.serviceWorker && navigator.serviceWorker.controller ? document.readyState : ''`);
        if (state === 'complete') {
          controlled = true;
          break;
        }
      } catch {
        // the page is navigating
      }
      await sleep(500);
    }

    const fetchInPage = async (path: string): Promise<Served> => {
      const json = await evaluate(`(async () => {
        const r = await fetch(${JSON.stringify(path)}, { cache: 'no-store' });
        const b = new Uint8Array(await r.arrayBuffer());
        let s = '';
        for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
        return JSON.stringify({ url: r.url, status: r.status, headers: [...r.headers], body: btoa(s) });
      })()`);
      const o = JSON.parse(String(json)) as { url: string; status: number; headers: [string, string][]; body: string };
      return { url: o.url, status: o.status, headers: Object.fromEntries(o.headers.map(([k, v]) => [k.toLowerCase(), v])), body: new Uint8Array(Buffer.from(o.body, 'base64')) };
    };

    const waitForSelector = async (css: string, wait: number): Promise<boolean> => {
      const until = Date.now() + wait;
      for (;;) {
        try {
          if ((await evaluate(`document.querySelector(${JSON.stringify(css)}) !== null`)) === true) return true;
        } catch {
          // the page is navigating
        }
        if (Date.now() >= until) return false;
        await sleep(250);
      }
    };

    return { documents, controlled, problems, fetch: fetchInPage, waitForSelector, evaluate, close };
  } catch (e) {
    await close();
    throw e;
  }
}
