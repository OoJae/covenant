// The request body of both compile routes: {preset?: string, params?: object}.
//
// Both fields are optional. An empty body is a valid request for the default preset: OKX's marketplace
// self-check is a bare `curl -i -X POST <endpoint>` and must get the 402 challenge, not a validation error.

import { PRESET_RE } from './config.ts';

export interface CompileRequest {
  preset: string;
  params: Record<string, unknown>;
}

export type ParseResult =
  | { ok: true; request: CompileRequest }
  | { ok: false; code: 'invalid_json' | 'invalid_request'; message: string };

const MAX_DEPTH = 8;
const MAX_NODES = 500;

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Count the values in a JSON tree, refusing trees that are too deep or too large. */
function tooBig(value: unknown): string | null {
  let nodes = 0;
  const walk = (v: unknown, depth: number): string | null => {
    if (++nodes > MAX_NODES) return `params holds more than ${MAX_NODES} values`;
    if (depth > MAX_DEPTH) return `params is nested deeper than ${MAX_DEPTH} levels`;
    if (Array.isArray(v)) {
      for (const item of v) {
        const e = walk(item, depth + 1);
        if (e) return e;
      }
    } else if (isObject(v)) {
      for (const item of Object.values(v)) {
        const e = walk(item, depth + 1);
        if (e) return e;
      }
    }
    return null;
  };
  return walk(value, 0);
}

export function parseCompileRequest(text: string, defaultPreset: string): ParseResult {
  let body: unknown = {};
  if (text.trim() !== '') {
    try {
      body = JSON.parse(text);
    } catch {
      return { ok: false, code: 'invalid_json', message: 'The request body is not valid JSON.' };
    }
  }
  if (!isObject(body)) {
    return { ok: false, code: 'invalid_request', message: 'The request body must be a JSON object.' };
  }

  for (const key of Object.keys(body)) {
    if (key !== 'preset' && key !== 'params') {
      return { ok: false, code: 'invalid_request', message: `Unknown field "${key.slice(0, 40)}". Allowed fields: preset, params.` };
    }
  }

  let preset = defaultPreset;
  if (body['preset'] !== undefined && body['preset'] !== null && body['preset'] !== '') {
    if (typeof body['preset'] !== 'string' || !PRESET_RE.test(body['preset'])) {
      return {
        ok: false,
        code: 'invalid_request',
        message: 'preset must be a lowercase name: letters, digits, "-" and "_", at most 64 characters.',
      };
    }
    preset = body['preset'];
  }

  let params: unknown = body['params'] ?? {};
  // Clients that can only send flat strings (OKX's CLI with --param params=...) may pass the object as JSON text.
  if (typeof params === 'string') {
    if (params.trim() === '') params = {};
    else {
      try {
        params = JSON.parse(params);
      } catch {
        return { ok: false, code: 'invalid_request', message: 'params is a string but not JSON text of an object.' };
      }
    }
  }
  if (!isObject(params)) {
    return { ok: false, code: 'invalid_request', message: 'params must be a JSON object.' };
  }
  const big = tooBig(params);
  if (big) return { ok: false, code: 'invalid_request', message: big };

  return { ok: true, request: { preset, params } };
}

/** Machine-readable description of the inputs, attached to every 400 so a client can correct itself. */
export function parameterSpec(defaultPreset: string): Record<string, unknown> {
  return {
    required: [],
    parameters: {
      preset: {
        type: 'string',
        required: false,
        default: defaultPreset,
        description: 'Name of the vault chip preset to compile.',
      },
      params: {
        type: 'object',
        required: false,
        default: {},
        description: 'Parameters of the preset, as a JSON object. Omit it for the preset defaults.',
      },
    },
  };
}
