// A kernel's envelope in the words a holder reads (chips/INTERFACE.md section 7).

import type { Envelope } from '@covenant/chain/kernel';
import { okb, pct256 } from '../kernel/chip.ts';
import { exp8, LG8_MAX } from '../kernel/model.ts';
import { fmtDuration } from '../format.ts';
import { Address } from './common.tsx';

type Env = Pick<Envelope, 'epochLen' | 'capT' | 'allowCumBps' | 'ceilMax' | 'relMax' | 'floorRel' | 'floorMin' | 'fallbackEpochs' | 'fbAllow'> &
  Partial<Pick<Envelope, 'launcher' | 'allowancePayee' | 'buyEnabled'>>;

export function EnvelopeWords({ e, payeeNote }: { e: Env; payeeNote?: string }) {
  return (
    <dl class="facts envelope">
      <dt>Epoch</dt>
      <dd>
        {fmtDuration(e.epochLen)} ({e.epochLen} s). At most one settle per epoch; anyone may call it.
      </dd>
      <dt>Allowance share</dt>
      <dd>
        At most <b>{pct256(e.capT)}</b> of each settle's tax ({e.capT}/256, <span class="mono">capT</span>). Whatever a chip asks above that
        stays in the reserve.
      </dd>
      <dt>Allowance per settle</dt>
      <dd>
        {e.ceilMax >= LG8_MAX ? (
          'No per-settle ceiling.'
        ) : (
          <>
            At most <b>{okb(exp8(e.ceilMax))}</b> (<span class="mono">ceilMax</span> = code {e.ceilMax}).
          </>
        )}
      </dd>
      <dt>Allowance for life</dt>
      <dd>
        At most <b>{e.allowCumBps / 100}%</b> of all tax that ever arrives (<span class="mono">allowCumBps</span> {e.allowCumBps}). None at all
        after the token graduates.
      </dd>
      {e.allowancePayee && (
        <>
          <dt>Allowance goes to</dt>
          <dd>
            <Address value={e.allowancePayee} /> only, as a pull credit{payeeNote ? ` (${payeeNote})` : ''}.
          </dd>
        </>
      )}
      <dt>Everything else</dt>
      <dd>Is bought on the curve and locked (burned to 0xdEaD after graduation), or waits in the reserve until it is.</dd>
      <dt>Release</dt>
      <dd>
        At most <b>{pct256(e.relMax)}</b> of the reserve per settle (<span class="mono">relMax</span>), and at least {pct256(e.floorRel)} while
        the reserve is at least {okb(exp8(e.floorMin))} (<span class="mono">floorRel</span>, <span class="mono">floorMin</span>), so a
        reserve cannot be parked.
      </dd>
      <dt>If the chip stops answering</dt>
      <dd>
        After {e.fallbackEpochs} epochs ({fmtDuration(e.fallbackEpochs * e.epochLen)}) without a step, every settle applies a fixed word: buy{' '}
        {pct256(256 - e.fbAllow)}, allowance {pct256(e.fbAllow)}, release {pct256(e.relMax)}.
      </dd>
      {e.launcher && (
        <>
          <dt>Launcher</dt>
          <dd>
            <Address value={e.launcher} />. A token it created can be bound by anyone; a token another wallet created, only by the launcher itself.
          </dd>
        </>
      )}
    </dl>
  );
}
