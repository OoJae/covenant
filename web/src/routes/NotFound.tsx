// Any hash that is not a page: the cold Seal (every latch 0, a kernel before its first settle), one plain line
// about the addresses that are pages, and the way home.

import { Icon } from '../components/Icon.tsx';
import { Seal } from '../components/Seal.tsx';
import { PageHead } from './shared.tsx';

export function NotFound({ hash }: { hash: string }) {
  return (
    <article class="page page--404">
      <PageHead
        crumbs={
          <>
            <a href="#/">Covenant</a> / not found
          </>
        }
        title={
          <>
            Nothing at <em>this address</em>
          </>
        }
      />
      <section class="clause nf">
        <figure class="nf__seal silicon">
          <Seal hex="0x0000000000000000" size={176} label="The cold seal: every latch 0" />
          <figcaption class="micro">The cold seal · every latch 0 · 0x0000000000000000</figcaption>
        </figure>
        <div class="nf__text">
          <p>
            <span class="mono">{hash}</span> is not a page. A processor is <span class="mono">#/p/0x…</span>, a circuit{' '}
            <span class="mono">#/c/0x…/id</span>, a kernel <span class="mono">#/k/0x…</span> and one of its settles{' '}
            <span class="mono">#/k/0x…/n</span>.
          </p>
          <p>
            <a class="btn btn--primary press" href="#/">
              Back to the start
              <span class="btn__icon">
                <Icon name="arrow-right" />
              </span>
            </a>
          </p>
        </div>
      </section>
    </article>
  );
}
