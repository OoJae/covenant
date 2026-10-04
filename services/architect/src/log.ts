// One JSON object per line on stdout. Configured secret values are scrubbed from every line.

export type Level = 'debug' | 'info' | 'warn' | 'error';
export type Fields = Record<string, unknown>;

export interface Logger {
  debug(event: string, fields?: Fields): void;
  info(event: string, fields?: Fields): void;
  warn(event: string, fields?: Fields): void;
  error(event: string, fields?: Fields): void;
}

export interface LoggerOptions {
  level?: Level;
  write?: (line: string) => void;
  now?: () => Date;
  /** Literal values that must never appear in the output (API key, secret key, passphrase). */
  secrets?: readonly string[];
}

const ORDER: Record<Level, number> = { debug: 10, info: 20, warn: 30, error: 40 };

export const isLevel = (v: string): v is Level => v === 'debug' || v === 'info' || v === 'warn' || v === 'error';

const escapeRegExp = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function toJson(value: unknown): string {
  return JSON.stringify(value, (_key, v: unknown) => {
    if (typeof v === 'bigint') return v.toString();
    if (v instanceof Error) return { name: v.name, message: v.message };
    return v;
  });
}

export function createLogger(options: LoggerOptions = {}): Logger {
  const min = ORDER[options.level ?? 'info'];
  const write = options.write ?? ((line: string) => void process.stdout.write(line + '\n'));
  const now = options.now ?? (() => new Date());
  // Very short values are skipped: redacting them would shred ordinary text without protecting anything.
  const patterns = (options.secrets ?? []).filter((s) => s.length >= 6).map((s) => new RegExp(escapeRegExp(s), 'g'));

  const emit = (level: Level, event: string, fields?: Fields): void => {
    if (ORDER[level] < min) return;
    // `message` duplicates `event` because Railway's log view keys on `message` and `level`.
    let line = toJson({ ts: now().toISOString(), level, event, message: event, ...fields });
    for (const re of patterns) line = line.replace(re, '[redacted]');
    write(line);
  };

  return {
    debug: (event, fields) => emit('debug', event, fields),
    info: (event, fields) => emit('info', event, fields),
    warn: (event, fields) => emit('warn', event, fields),
    error: (event, fields) => emit('error', event, fields),
  };
}

export const silentLogger: Logger = { debug() {}, info() {}, warn() {}, error() {} };
