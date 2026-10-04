// One JSON object per line on stdout. Secrets are scrubbed from every line before it is written.

export type Level = 'debug' | 'info' | 'warn' | 'error';
export type Fields = Record<string, unknown>;

export interface Logger {
  debug(event: string, fields?: Fields): void;
  info(event: string, fields?: Fields): void;
  warn(event: string, fields?: Fields): void;
  error(event: string, fields?: Fields): void;
}

/** A literal to remove from every log line, and what to print instead. */
export interface Redaction {
  needle: string;
  replacement: string;
}

export interface LoggerOptions {
  level?: Level;
  write?: (line: string) => void;
  now?: () => Date;
  redactions?: readonly Redaction[];
}

const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export const isLevel = (v: string): v is Level => v === 'debug' || v === 'info' || v === 'warn' || v === 'error';

const escapeRegExp = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** JSON.stringify that survives bigint (decimal string) and Error (name and message only, never the stack). */
export function toJson(value: unknown): string {
  return JSON.stringify(value, (_key, v: unknown) => {
    if (typeof v === 'bigint') return v.toString();
    if (v instanceof Error) return { name: v.name, message: v.message };
    return v;
  });
}

/**
 * Redactions for a private key: the 64 hex characters with or without the 0x prefix, in any letter case.
 * The key is never passed to the logger on purpose; this is the net under that rule.
 */
export function keyRedactions(key: string | null): Redaction[] {
  if (!key) return [];
  const bare = key.startsWith('0x') || key.startsWith('0X') ? key.slice(2) : key;
  if (bare.length < 16) return [];
  return [{ needle: bare, replacement: '[redacted-key]' }];
}

/** Redactions for RPC URLs, which often carry an API key in the path or the query string. */
export function urlRedactions(urls: readonly string[]): Redaction[] {
  const out: Redaction[] = [];
  for (const u of urls) {
    let host = 'rpc';
    try {
      host = new URL(u).host;
    } catch {
      // keep the generic label
    }
    out.push({ needle: u, replacement: host });
    const trimmed = u.replace(/\/+$/, '');
    if (trimmed !== u) out.push({ needle: trimmed, replacement: host });
  }
  // Longest first, so that a URL is replaced before any shorter URL that is its prefix.
  return out.sort((a, b) => b.needle.length - a.needle.length);
}

export function createLogger(options: LoggerOptions = {}): Logger {
  const min = ORDER[options.level ?? 'info'];
  const write = options.write ?? ((line: string) => void process.stdout.write(line + '\n'));
  const now = options.now ?? (() => new Date());
  const patterns = (options.redactions ?? [])
    .filter((r) => r.needle.length > 0)
    .map((r) => ({ re: new RegExp(`(?:0x)?${escapeRegExp(r.needle)}`, 'gi'), replacement: r.replacement }));

  const emit = (level: Level, event: string, fields?: Fields): void => {
    if (ORDER[level] < min) return;
    // `message` duplicates `event` because Railway's log view keys on `message` and `level`.
    let line = toJson({ ts: now().toISOString(), level, event, message: event, ...fields });
    for (const p of patterns) line = line.replace(p.re, p.replacement);
    write(line);
  };

  return {
    debug: (event, fields) => emit('debug', event, fields),
    info: (event, fields) => emit('info', event, fields),
    warn: (event, fields) => emit('warn', event, fields),
    error: (event, fields) => emit('error', event, fields),
  };
}
