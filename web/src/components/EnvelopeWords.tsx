// A kernel's envelope in the words a holder reads (chips/INTERFACE.md section 7; for a v2 kernel, the two readings
// chips/INTERFACE-V2.md section 7 changes: amounts in USD₮0, and ceilMax/floorMin in the chip's code space).

import type { Envelope } from '@covenant/chain/kernel';
import { amount, OKB_UNIT, pct256, shiftBand, V2_REFERENCE, type Unit } from '../kernel/chip.ts';
import { exp8s, LG8_MAX, lg8s, minAmountForCode } from '../kernel/model.ts';
import { fmtDuration, fmtInt, fmtUnits } from '../format.ts';
import { Address } from './common.tsx';

type Env = Pick<Envelope, 'epochLen' | 'capT' | 'allowCumBps' | 'ceilMax' | 'relMax' | 'floorRel' | 'floorMin' | 'fallbackEpochs' | 'fbAllow'> &
  Partial<Pick<Envelope, 'launcher' | 'allowancePayee' | 'buyEnabled'>>;

/**
 * `unit` is the curve's quote asset (OKB on kernel v1, USD₮0 on kernel v2) and `shift` the kernel's code shift in
 * bits (0 on kernel v1).
 */
export function EnvelopeWords({ e, payeeNote, unit = OKB_UNIT, shift = 0 }: { e: Env; payeeNote?: string; unit?: Unit; shift?: number }) {
  const v2 = shift > 0;
  const floorFrom = minAmountForCode(e.floorMin, shift);
  const tax = v2 ? `${unit.symbol} that arrives on the curve (tax, and revenue paid to the kernel)` : 'tax';
  return (
    <dl class="facts envelope">
      <dt>Epoch</dt>
      <dd>
        {fmtDuration(e.epochLen)} ({e.epochLen} s). At most one settle per epoch; anyone may call it.
      </dd>
      <dt>Allowance share</dt>
      <dd>
        At most <b>{pct256(e.capT)}</b> of each settle's {v2 ? 'inflow' : 'tax'} ({e.capT}/256, <span class="mono">capT</span>). Whatever a chip asks above that
        stays in the reserve.
      </dd>
      <dt>Allowance per settle</dt>
      <dd>
        {e.ceilMax >= LG8_MAX ? (
          'No per-settle ceiling.'
        ) : (
          <>
            At most <b>{amount(exp8s(e.ceilMax, shift), unit)}</b> (<span class="mono">ceilMax</span> = code {e.ceilMax}
            {v2 && (
              <>
                {' '}
                in the chip's code space: exp8({e.ceilMax}) &gt;&gt; {shift} = {fmtInt(exp8s(e.ceilMax, shift))} base units
              </>
            )}
            ).
          </>
        )}
      </dd>
      <dt>Allowance for life</dt>
      <dd>
        At most <b>{e.allowCumBps / 100}%</b> of all {tax} (<span class="mono">allowCumBps</span> {e.allowCumBps}), paid in {unit.symbol}. None at all
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
        At most <b>{pct256(e.relMax)}</b> of the reserve per settle (<span class="mono">relMax</span>), and at least {pct256(e.floorRel)}{' '}
        {floorFrom <= 1n ? 'whenever there is any reserve' : <>while the reserve is at least {amount(floorFrom, unit)}</>} (<span class="mono">floorRel</span>,{' '}
        <span class="mono">floorMin</span> = code {e.floorMin}
        {v2 ? ', compared with the shifted code' : ''}), so a reserve cannot be parked.
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

/**
 * How a v2 kernel shows USD₮0 to a chip written for wei of OKB (chips/INTERFACE-V2.md 4.1). Numbers that depend on
 * the shift are computed from the kernel's own `shift`; the reference rate is the one the shift was derived from.
 */
export function CodeShift({ shift, unit, ceilMax }: { shift: number; unit: Unit; ceilMax: number }) {
  const [lo, hi] = shiftBand(shift);
  const oneOkb = (10n ** 18n) >> BigInt(shift);
  const pts: [string, bigint][] = [
    [`1 ${unit.symbol}`, 10n ** BigInt(unit.decimals)],
    ['one $0.50 call', 5n * 10n ** BigInt(Math.max(0, unit.decimals - 1))],
    [`8,000 ${unit.symbol} (a whole curve)`, 8_000n * 10n ** BigInt(unit.decimals)],
  ];
  return (
    <div class="codeshift">
      <h3>
        How this kernel shows {unit.symbol} to its chip: a fixed shift of {shift} bits ({8 * shift} codes)
      </h3>
      <p>
        Chips read amounts as lg8 codes (an eighth of an octave per step) and the Flow Governor was written for wei of OKB, 18 decimals.{' '}
        {unit.symbol} has {unit.decimals}. On the curve this kernel shows every amount <i>x</i> as{' '}
        <span class="mono">
          lg8(x &lt;&lt; {shift}) = lg8(x) + {8 * shift}
        </span>
        : exactly the input word a kernel v1 would show for <i>x</i> · 2<sup>{shift}</sup> wei. So the chip's behaviour and its proofs, which are
        about codes, carry over unchanged, and every amount code coming back (the chip's CEIL, the envelope's ceilMax) is read as{' '}
        <span class="mono">exp8(code) &gt;&gt; {shift}</span>. Only a whole number of bits commutes with lg8 exactly, so the shift is a whole number
        of bits.
      </p>
      <ul class="small">
        <li>
          1 OKB of the chip's calibration reads as 10<sup>18</sup> / 2<sup>{shift}</sup> = <b>{fmtUnits(oneOkb, unit.decimals)} {unit.symbol}</b>.{' '}
          {shift} is the nearest whole shift for any OKB price from {lo.toFixed(1)} to {hi.toFixed(1)} {unit.symbol} per OKB
          {shift === V2_REFERENCE.shift && (
            <>
              ; it was derived from {V2_REFERENCE.rate} {unit.symbol} per OKB (the canonical Uniswap V3 {unit.symbol}/WOKB 0.05% pool at block{' '}
              {fmtInt(V2_REFERENCE.block)})
            </>
          )}
          . The shift is fixed in this kernel's code; no price is ever read by the kernel.
        </li>
        <li>
          Codes the chip sees: {pts.map(([label, x], i) => (
            <span key={label}>
              {i > 0 && ', '}
              {label} = <span class="mono">{lg8s(x, shift)}</span>
            </span>
          ))}
          . The envelope's ceilMax {ceilMax >= LG8_MAX ? '(none)' : <>{ceilMax} caps the allowance at {amount(exp8s(ceilMax, shift), unit)} per settle</>}.
        </li>
        <li>After graduation the regime asset is the project token (18 decimals, as on kernel v1) and the shift is 0.</li>
      </ul>
    </div>
  );
}
