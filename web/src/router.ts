// Hash routes: the site is static files with no server, so the route lives after the '#'.

import { useEffect, useState } from 'preact/hooks';
import { isAddress } from './format.ts';

export type Route =
  | { page: 'landing' }
  | { page: 'processor'; processor: string }
  | { page: 'circuit'; processor: string; id: string }
  | { page: 'vault'; kernel: string }
  | { page: 'audit'; kernel: string; n: number }
  | { page: 'hostile' }
  | { page: 'judge' }
  | { page: 'trust' }
  | { page: 'notfound'; hash: string };

export function parseRoute(hash: string): Route {
  let parts: string[];
  try {
    parts = hash
      .replace(/^#\/?/, '')
      .split('/')
      .filter(Boolean)
      .map(decodeURIComponent);
  } catch {
    return { page: 'notfound', hash };
  }
  const [head, a, b] = parts;
  if (parts.length === 0) return { page: 'landing' };
  if (head === 'p' && parts.length === 2 && isAddress(a)) return { page: 'processor', processor: a };
  if (head === 'c' && parts.length === 3 && isAddress(a) && /^\d{1,20}$/.test(b)) {
    return { page: 'circuit', processor: a, id: BigInt(b).toString() };
  }
  if (head === 'k' && parts.length === 2 && isAddress(a)) return { page: 'vault', kernel: a };
  if (head === 'k' && parts.length === 3 && isAddress(a) && /^\d{1,9}$/.test(b) && Number(b) <= 0xffffffff) return { page: 'audit', kernel: a, n: Number(b) };
  if (head === 'hostile' && parts.length === 1) return { page: 'hostile' };
  if (head === 'judge' && parts.length === 1) return { page: 'judge' };
  if (head === 'trust' && parts.length === 1) return { page: 'trust' };
  return { page: 'notfound', hash };
}

export function useRoute(): Route {
  const [hash, setHash] = useState(location.hash);
  useEffect(() => {
    const onChange = (): void => {
      setHash(location.hash);
      scrollTo(0, 0);
    };
    addEventListener('hashchange', onChange);
    return () => removeEventListener('hashchange', onChange);
  }, []);
  return parseRoute(hash);
}

/** State of a promise started by a component; stale results are dropped. */
export interface Async<T> {
  data: T | undefined;
  error: Error | undefined;
  loading: boolean;
  reload: () => void;
}

export function useAsync<T>(start: () => Promise<T>, deps: readonly unknown[]): Async<T> {
  const [state, setState] = useState<{ data?: T; error?: Error; loading: boolean }>({ loading: true });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    setState({ loading: true });
    start().then(
      (data) => live && setState({ data, loading: false }),
      (e: unknown) => live && setState({ error: e instanceof Error ? e : new Error(String(e)), loading: false }),
    );
    return () => {
      live = false;
    };
  }, [...deps, attempt]);
  return { data: state.data, error: state.error, loading: state.loading, reload: () => setAttempt((n) => n + 1) };
}
