// Pieces every page shares: the page head, and the loading and failure states of a page that reads the chain.

import type { ComponentChildren } from 'preact';
import { RevealLines } from '../components/RevealLines.tsx';
import { Seal } from '../components/Seal.tsx';
import { Icon } from '../components/Icon.tsx';
import { ADDR, CHAIN } from '../config.ts';

const COLD = '0x0000000000000000';

/**
 * The head of a page: where it sits (the crumbs hang in the clause gutter), the title in the display face, rising
 * by line once (the page's arrival), and the one-sentence lede. Anything else in `children` follows the lede.
 */
export function PageHead({ crumbs, title, lede, children }: { crumbs: ComponentChildren; title: ComponentChildren; lede?: ComponentChildren; children?: ComponentChildren }) {
  return (
    <header class="page-head">
      <p class="crumbs">{crumbs}</p>
      <RevealLines as="h1" class="page-title" stagger={70}>
        {title}
      </RevealLines>
      {lede && <p class="lede">{lede}</p>}
      {children}
    </header>
  );
}

/** While a page reads the chain: the Seal fills in level order, like a beat running through the die. */
export function Loading({ what }: { what: string }) {
  return (
    <div class="loading" role="status">
      <Seal hex={COLD} loading size={44} label="Reading" />
      <span>Reading {what}…</span>
    </div>
  );
}

export function Failure({ error, retry }: { error: Error | undefined; retry: () => void }) {
  // data/processor.ts's Missing, told by its name so this entry module does not pull in the processor loader.
  if (error?.name === 'Missing') {
    // The node answered; what was asked for does not exist. Trying again would not help.
    return (
      <div class="plate warn silicon" role="alert">
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
    <div class="plate bad silicon" role="alert">
      <div class="verdict">
        <strong>Could not read the chain</strong>
      </div>
      <p class="mono">{error ? error.message : 'unknown error'}</p>
      <p>
        The page talks only to {ADDR.rpc.map((u) => new URL(u).host).join(' and ')}. If both are unreachable or rate-limited, wait a
        moment and try again.
      </p>
      <button type="button" class="btn btn--secondary press" onClick={retry}>
        Try again
        <span class="btn__icon">
          <Icon name="arrow-right" />
        </span>
      </button>
    </div>
  );
}
