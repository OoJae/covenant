// Loading and failure states shared by the pages that read the chain.

import { ADDR, CHAIN } from '../config.ts';
import { Missing } from '../data/processor.ts';

export function Loading({ what }: { what: string }) {
  return (
    <p class="loading" role="status">
      Reading {what}…
    </p>
  );
}

export function Failure({ error, retry }: { error: Error | undefined; retry: () => void }) {
  if (error instanceof Missing) {
    // The node answered; what was asked for does not exist. Trying again would not help.
    return (
      <div class="plate warn" role="alert">
        <div class="verdict">
          <strong>Not found on {CHAIN.name}</strong>
        </div>
        <p class="mono">{error.message}</p>
        <p>
          <a href="#/">Back to the start</a>
        </p>
      </div>
    );
  }
  return (
    <div class="plate bad" role="alert">
      <div class="verdict">
        <strong>Could not read the chain</strong>
      </div>
      <p class="mono">{error ? error.message : 'unknown error'}</p>
      <p>
        The page talks only to {ADDR.rpc.map((u) => new URL(u).host).join(' and ')}. If both are unreachable or rate-limited, wait a
        moment and try again.
      </p>
      <button type="button" onClick={retry}>
        Try again
      </button>
    </div>
  );
}
