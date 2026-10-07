// Pieces every page shares: the page head, and the loading and failure states of a page that reads the chain.

import type { ComponentChildren } from 'preact';
import { useEffect, useState } from 'preact/hooks';
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

/**
 * While a page reads the chain: the Seal fills in level order, like a beat running through the die. `page`: it
 * stands in for a whole page, so its line is the page's h1 until the page arrives.
 */
export function Loading({ what, page = false }: { what: string; page?: boolean }) {
  const T = page ? 'h1' : 'span';
  // After SLOW_MS without an answer, say so: the node is slow, the page has not given up.
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    const t = setTimeout(() => setSlow(true), SLOW_MS);
    return () => clearTimeout(t);
  }, []);
  return (
    <div class="loading" role="status">
      <Seal hex={COLD} loading size={44} label="Reading" />
      <T class="loading__text">
        Reading {what}…{slow && <span class="loading__slow"> {CHAIN.name} is slow to answer; still asking.</span>}
      </T>
    </div>
  );
}

const SLOW_MS = 6000;

/** A read that failed, with a way to try again. `page`: it stands in for a whole page, so its verdict is the h1. */
export function Failure({ error, retry, page = false }: { error: Error | undefined; retry: () => void; page?: boolean }) {
  const V = page ? 'h1' : 'div';
  // data/processor.ts's Missing, told by its name so this entry module does not pull in the processor loader.
  if (error?.name === 'Missing') {
    // The node answered; what was asked for does not exist. Trying again would not help.
    return (
      <div class="plate warn silicon" role="alert">
        <V class="verdict">
          <strong>Not found on {CHAIN.name}</strong>
        </V>
        <p class="mono">{error.message}</p>
        <p>
          <a href="#/">Back to the start</a>
        </p>
      </div>
    );
  }
  return (
    <div class="plate bad silicon" role="alert">
      <V class="verdict">
        <strong>Could not read the chain</strong>
      </V>
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
