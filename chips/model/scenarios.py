"""Scenario runner: the Flow Governor model inside a simulated kernel v1 (chips/INTERFACE.md, revision 2).

    python chips/model/scenarios.py                 # every scenario, the behaviour checks and the cadence test
    python chips/model/scenarios.py steady -v       # per-epoch table of one scenario
    python chips/model/scenarios.py --list
    python chips/model/scenarios.py --cadence       # the cadence-equivalence test only
    python chips/model/scenarios.py --compare       # every scenario under the idealised kernel and under revision 2
    python chips/model/scenarios.py --dump DIR      # write every per-epoch table and trace (JSON) to DIR

    --ideal        the idealised kernel: no echo, every decided buy executes in full (the runner before revision 2)
    --no-echo      revision 2 without the echo        --no-limits    revision 2 without execution limits

Amounts are integers (wei of OKB before graduation, token base units after).

The kernel side is chips/golden/kernel_model.py and nothing else: `route_tax(..., graduated=...)` for the clamps,
`dt_code` for DT (epochs since the last PERSISTED step), `fallback_word` when the evaluator has failed past the
grace period, `prog_code` / `lock_code` for the two spot readings, `curve_buy`, `impact_cap` and `v2_net_out` for
the size of the buy legs. What this file adds is the world around the kernel:

  * the token's vault (tax waits there until a settle claims it);
  * the IGNIX bonding curve of the reference token, moved by the scenario's outside trades and by the kernel's
    own buys (CurveTrading.buy, mirrored in integers);
  * the echo: the kernel's own curve buy pays the buy tax like anyone else, into the kernel's own vault, and that
    tax is inflow in the next settle. After graduation the router buy that spends the native pot pays its tax in
    tokens, which is inflow of the token regime;
  * graduation: an outside buyer takes the rest of the curve at the scenario's `grad_epoch`; the pair opens with
    the 200,000,000 reserved tokens against the quote the curve raised; the kernel's OKB reserve and the residual
    OKB tax become the native pot; TAXCUM, the reserve and the allowance total restart.

How a scenario's numbers become trades. `flows[i]` is the tax, in the regime asset, that outside trading pays
during epoch i + 1. By default that trading is round trips (a buy and the sale of the same tokens inside the
epoch), which leave the curve where it was. `net_buy` (percent) is the share of an epoch's tax that comes from
one-way buys instead; those move the curve. The tax credited to the vault is always the scenario's number, so
the same flow can be run under every kernel mode. A scenario graduates only at its `grad_epoch`: before it,
one-way buys are capped at the largest buy that does not sell the curve out, and so are the kernel's own buys
(the kernel never graduates a token).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402

OKB = 10 ** 18
BPS = km.BPS
REF = fg.PARAMS["reference"]

# record flags (chips/INTERFACE.md section 10)
F_FALLBACK, F_SEALED, F_CLAIM_FAILED, F_CURVE_READ, F_BUY_SKIPPED, F_BUY_FAILED, F_GRADUATED, F_BUY_SHRUNK = (
    1, 2, 4, 8, 16, 32, 64, 128)
FLAG_NAMES = [(F_FALLBACK, "fallback"), (F_BUY_SKIPPED, "skipped"), (F_BUY_FAILED, "failed"),
              (F_BUY_SHRUNK, "shrunk"), (F_GRADUATED, "grad")]


@dataclass(frozen=True)
class Mode:
    """Which of the two market effects the simulated kernel has."""
    echo: bool = True      # the tax of the kernel's own buys returns through the vault as inflow
    limits: bool = True    # buys are sized on a simulated curve / pair; what does not execute stays in the reserve

    @property
    def label(self) -> str:
        return {(True, True): "revision 2", (False, False): "idealised", (True, False): "echo only",
                (False, True): "limits only"}[(self.echo, self.limits)]


REV2 = Mode(True, True)
IDEAL = Mode(False, False)
MODE = REV2                      # what run() uses when no mode is given; main() changes it from the flags


# ----------------------------------------------------------------------------- the market around the kernel
@dataclass
class Curve:
    """The IGNIX bonding curve of one token (contracts/vendor/ignix-xlayer, CurveTrading and CurveMath)."""
    v_quote: int
    v_token: int
    sold: int
    sellable: int
    collected: int
    pair_supply: int
    buy_fee: int
    sell_fee: int
    tax_buy: int
    tax_sell: int

    @classmethod
    def fresh(cls, ref: dict = REF) -> "Curve":
        C, D, G = int(ref["curveSupply"]), int(ref["pairSupply"]), int(ref["graduationQuote"])
        T = C * C // (C - D)
        E = G * (T - C) // C
        return cls(E, T, 0, C, 0, D, ref["curveBuyFeeBps"], ref["curveSellFeeBps"], ref["taxBuyBps"], ref["taxSellBps"])

    def max_buy(self) -> int:
        """Largest gross buy that leaves at least one base unit of token on the curve."""
        return km.max_non_graduating_buy(self.v_quote, self.v_token, self.sold, self.sellable, self.buy_fee, self.tax_buy)

    def cost_to_sell_out(self) -> int:
        left = self.sellable - self.sold
        if left == 0:
            return 0
        net = km.ceil_div(self.v_quote * left, self.v_token - left)
        return km.ceil_div(net * BPS, BPS - self.buy_fee - self.tax_buy)

    def buy(self, quote_in: int) -> Tuple[int, int, int, bool]:
        """CurveTrading.buy without an anti-snipe surcharge: (quote spent, tokens out, tax to the vault, sold out).
        A buy that reaches the end of the curve is capped there and the rest is refunded."""
        fee_bps = self.buy_fee + self.tax_buy
        net = quote_in - quote_in * fee_bps // BPS
        left = self.sellable - self.sold
        out = self.v_token - km.ceil_div(self.v_quote * self.v_token, self.v_quote + net)
        if out >= left:
            out = left
            net = km.ceil_div(self.v_quote * left, self.v_token - left)
            gross_needed = km.ceil_div(net * BPS, BPS - fee_bps)
            if gross_needed < quote_in:
                quote_in = gross_needed
        else:                                           # a buy that stays on the curve: the kernel model's own quote
            assert out == km.curve_out(self.v_quote, self.v_token, self.buy_fee, self.tax_buy, quote_in)
        if out == 0:
            return 0, 0, 0, False                       # the Manager reverts SoldOut: nothing happens
        tax = quote_in * self.tax_buy // BPS
        self.v_quote += net
        self.v_token -= out
        self.sold += out
        self.collected += net
        return quote_in, out, tax, self.sold == self.sellable


@dataclass
class Pair:
    """The Uniswap V2 pair the token graduates to: WOKB against the token, 0.3% fee, taxed by the token."""
    r_quote: int
    r_token: int

    def buy(self, amount_in: int, tax_buy: int) -> Tuple[int, int, int]:
        """A buy of the taxed token with `amount_in` of quote: (gross tokens out of the pair, tax, net received)."""
        in_fee = amount_in * 997
        gross = in_fee * self.r_token // (self.r_quote * 1000 + in_fee)
        tax = gross * min(tax_buy, BPS) // BPS
        assert gross - tax == km.v2_net_out(amount_in, self.r_quote, self.r_token, tax_buy)
        self.r_quote += amount_in
        self.r_token -= gross
        return gross, tax, gross - tax


class Market:
    """Everything outside the kernel: the vault, the curve and, after graduation, the pair."""

    def __init__(self, ref: dict = REF, simulate: bool = True):
        self.ref = ref
        self.curve: Optional[Curve] = Curve.fresh(ref) if simulate else None
        self.pair: Optional[Pair] = None
        self.graduated = False                 # the token reports a pair
        self.vault_q = 0                       # native OKB tax waiting in the vault
        self.vault_q_echo = 0                  # the part of it paid by the kernel's own buys
        self.vault_t = 0                       # token tax waiting in the vault (after graduation)
        self.vault_t_echo = 0
        self.outside_q = 0                     # tax paid by outside trades on the curve
        self.outside_t = 0                     # tax paid by outside trades on the pair, in tokens
        self.lump_q = 0                        # tax of the buy that graduated the token

    def trade(self, tax: int, net_buy: int = 0) -> None:
        """Outside trading of one epoch that pays `tax` in the regime asset."""
        if tax == 0:
            return
        if self.graduated:
            self.vault_t += tax
            self.outside_t += tax
            return
        self.vault_q += tax
        self.outside_q += tax
        if self.curve is not None and net_buy:
            gross = (tax * net_buy // 100) * BPS // self.curve.tax_buy
            gross = min(gross, self.curve.max_buy())           # a scenario graduates only at its grad_epoch
            if gross:
                self.curve.buy(gross)

    def kernel_tax(self, tax: int, token: bool) -> None:
        if token:
            self.vault_t += tax
            self.vault_t_echo += tax
        else:
            self.vault_q += tax
            self.vault_q_echo += tax

    def claim(self, token: bool) -> Tuple[int, int]:
        """vault.claim: (everything waiting in the asset, the part of it that is echo)."""
        if token:
            out, self.vault_t, self.vault_t_echo = (self.vault_t, self.vault_t_echo), 0, 0
        else:
            out, self.vault_q, self.vault_q_echo = (self.vault_q, self.vault_q_echo), 0, 0
        return out

    def graduate(self) -> None:
        """An outside buyer takes the rest of the curve. Its tax lands in the vault as native OKB, the pair
        opens with the reserved tokens against the quote the curve raised."""
        if self.graduated:
            return
        if self.curve is not None:
            _, _, tax, sold_out = self.curve.buy(self.curve.cost_to_sell_out())
            assert sold_out and self.curve.max_buy() == 0
            self.vault_q += tax
            self.lump_q += tax
            self.pair = Pair(self.curve.collected, self.curve.pair_supply)
        self.graduated = True


# ----------------------------------------------------------------------------- one settle, one row
@dataclass
class Row:
    epoch: int
    dt: int
    inflow: int
    x: int
    y: int
    s_before: int
    s_after: int
    o: Dict[str, int]
    st: Dict[str, int]
    routed: km.Routed
    reserve_before: int
    reserve_after: int
    cum: int
    grad: int
    buy_executed: int
    flags: int = 0                 # record flags of INTERFACE section 10
    echo: int = 0                  # the part of `inflow` that is tax of the kernel's own earlier buys
    tokens_out: int = 0
    native_in: int = 0             # OKB spent by the post-graduation router buy

    @property
    def buy_decided(self) -> int:
        return self.routed.buy_decided


@dataclass
class Trace:
    name: str
    rows: List[Row] = field(default_factory=list)
    total_in: int = 0              # inflow recognised by the settles (echo included; both regimes added up)
    total_allow: int = 0
    total_buy: int = 0             # buyExecuted added up
    max_clamp: int = 0
    epochs: int = 0
    kernel: Optional["Kernel"] = None
    mode: Mode = REV2

    def add(self, row: Row) -> None:
        self.rows.append(row)
        self.total_in += row.inflow
        self.total_allow += row.routed.allow
        self.total_buy += row.buy_executed
        self.max_clamp |= row.routed.clamp

    def modes(self) -> List[int]:
        return [r.o["MODE"] for r in self.rows]


class Kernel:
    """Kernel v1 as far as a chip can tell: books, input word, step or fallback word, clamps, buy legs.

    The order of one settle is that of INTERFACE sections 8 and 9: regime latch, claims, books by balance,
    input word, evaluator, clamps, effects, legs.
    """

    def __init__(self, step: Callable = fg.step, env: Optional[km.Envelope] = None, exec_frac=None,
                 mode: Optional[Mode] = None, buy_blocked: Optional[Callable[[int], bool]] = None,
                 step_fails: Optional[Callable[[int], bool]] = None, ref: dict = REF,
                 fallback_epochs: Optional[int] = None, fb_allow: Optional[int] = None):
        self.step = step
        self.env = env or fg.envelope()
        self.mode = mode or MODE
        self.fallback_epochs = fg.ENV["fallbackEpochs"] if fallback_epochs is None else fallback_epochs
        self.fb_allow = fg.ENV["fbAllow"] if fb_allow is None else fb_allow
        self.ref = ref
        self.market = Market(ref, simulate=self.mode.limits)
        self.exec_frac = exec_frac            # without limits: f(epoch) -> 0..256, the share of a decided buy that executes
        self.buy_blocked = buy_blocked        # with limits: f(epoch) -> True while the Manager refuses buys (flag 16)
        self.step_fails = step_fails          # f(epoch) -> True while neither evaluator answers
        # kernel storage
        self.state = 0
        self.last_epoch = 0                   # epoch of the last settle
        self.last_step_epoch = 0              # epoch of the last persisted step (0 = bind)
        self.graduated = False                # the latch
        self.cum = 0
        self.reserve = 0
        self.allow_paid = 0
        # balances
        self.bal_q = 0                        # native OKB held
        self.credit_q = 0                     # unwithdrawn pull credits in OKB (the allowance)
        self.bal_t = 0                        # project tokens held
        self.locked = 0                       # of which bought on the curve
        self.burned = 0                       # tokens this kernel sent or bought to 0xdEaD
        # totals for the summaries
        self.q_inflow = self.q_allow = self.q_exec = self.q_echo = 0
        self.t_inflow = self.t_exec = self.t_echo = 0
        self.q_reserve_at_grad = 0
        self.pot_in = self.pot_spent = self.pot_tokens = 0
        self.n_shrunk = self.n_skipped = self.n_fallback = 0
        self.reverted: List[int] = []         # epochs at which settle() reverted (evaluator failure in the grace period)
        self.curve_end_epoch: Optional[int] = None

    # outside trading of one epoch (kept under its old name for callers that only feed tax)
    def accrue(self, amount: int, net_buy: int = 0) -> None:
        self.market.trade(amount, net_buy)

    def graduate(self) -> None:
        self.market.graduate()

    def settle(self, epoch: int) -> Optional[Row]:
        """One settle() call. Returns None when the call reverts (INTERFACE 8.4)."""
        if epoch <= self.last_epoch:
            raise ValueError("one settle per epoch")
        m, env, mode = self.market, self.env, self.mode
        step_ok = not (self.step_fails is not None and self.step_fails(epoch))
        if not step_ok and epoch - self.last_step_epoch < self.fallback_epochs:
            self.reverted.append(epoch)                     # nothing moves; the tax waits in the vault
            return None
        flags = 0

        # 1. regime: latched in the first settle in which the token reports a pair
        grad = self.graduated
        if not grad and m.graduated:
            grad = self.graduated = True
            self.q_reserve_at_grad = self.reserve           # no longer tracked: it is part of the native pot
            self.reserve = 0
            self.cum = 0
            self.allow_paid = 0
        if grad:
            flags |= F_GRADUATED

        # 2. claims: native OKB always, the project token once graduated
        got_q, echo_q = m.claim(False)
        self.bal_q += got_q
        echo = echo_q
        if grad:
            self.pot_in += got_q
            got_t, echo = m.claim(True)
            self.bal_t += got_t

        # 3. books by balance (INTERFACE 8.1)
        free = km.sat128((self.bal_t - self.locked) if grad else (self.bal_q - self.credit_q))
        reserve0 = min(self.reserve, free)
        inflow = free - reserve0
        cum = km.sat128(self.cum + inflow)

        # 4. the input word
        dt = km.dt_code(epoch, self.last_step_epoch)
        if m.curve is not None:
            prog = km.prog_code(m.curve.sold, m.curve.sellable, grad)
            lock = km.lock_code(self.locked + self.burned, int(self.ref["totalSupply"]))
        else:
            prog, lock = (255 if grad else 0), 0
        x = km.pack_input({"TAX": km.lg8(inflow), "TAXCUM": km.lg8(cum), "RES": km.lg8(reserve0),
                           "PROG": prog, "LOCK": lock, "DT": dt, "GRAD": 1 if grad else 0})

        # 5. the evaluator, or the fallback word once the grace period is over
        s0 = self.state
        if step_ok:
            ns, y = self.step(s0, x)
        else:
            ns, y = s0, km.fallback_word(env, self.fb_allow)
            flags |= F_FALLBACK
            self.n_fallback += 1

        # 6. clamps
        r = km.route_tax(env, y, inflow, reserve0, cum, self.allow_paid, graduated=grad)

        # 7. effects
        if step_ok:
            self.state = ns
            self.last_step_epoch = epoch
        self.last_epoch = epoch
        self.cum = cum
        self.allow_paid = km.sat128(self.allow_paid + r.allow)
        self.reserve = reserve0 + inflow - r.allow
        self.credit_q += r.allow                            # a pull credit; r.allow is 0 once graduated

        # 8. legs
        executed = tokens_out = native_in = 0
        if r.buy_decided:
            if not mode.limits:
                executed = r.buy_decided
                if self.exec_frac is not None:
                    executed = r.buy_decided * self.exec_frac(epoch) // 256
                if executed < r.buy_decided:
                    flags |= F_BUY_FAILED
                if grad:
                    self.bal_t -= executed
                    self.burned += executed
                else:
                    self.bal_q -= executed
                    if mode.echo:
                        m.kernel_tax(executed * self.ref["taxBuyBps"] // BPS, token=False)
                        self.q_echo += executed * self.ref["taxBuyBps"] // BPS
            elif grad:
                executed = tokens_out = r.buy_decided       # the burn leg: an untaxed transfer to 0xdEaD
                self.bal_t -= executed
                self.burned += executed
            elif self.buy_blocked is not None and self.buy_blocked(epoch):
                flags |= F_BUY_SKIPPED                      # anti-snipe window, founder round or BUY pause
            else:
                c = m.curve
                amount, out, shrunk = km.curve_buy(r.buy_decided, c.v_quote, c.v_token, c.sold, c.sellable,
                                                   c.buy_fee, c.sell_fee, c.tax_buy, c.tax_sell, env.capT)
                if shrunk:
                    flags |= F_BUY_SHRUNK
                if amount == 0:
                    flags |= F_BUY_SKIPPED
                    if c.max_buy() == 0 and self.curve_end_epoch is None:
                        self.curve_end_epoch = epoch
                else:
                    spent, got, tax, sold_out = c.buy(amount)
                    assert (spent, got) == (amount, out) and not sold_out, "the kernel never graduates the curve"
                    executed, tokens_out = amount, got
                    self.bal_q -= amount
                    self.bal_t += got
                    self.locked += got
                    if mode.echo:
                        m.kernel_tax(tax, token=False)
                        self.q_echo += tax
            self.reserve -= executed
        if grad and mode.limits:
            pot = self.bal_q - self.credit_q                # residual OKB tax and the OKB reserve left at graduation
            if pot > 0:
                p, c = m.pair, m.curve
                cap = km.impact_cap(p.r_quote, km.V2_ROUND_TRIP_FEE_BPS, c.tax_buy, c.tax_sell, env.capT)
                amt = min(pot, cap)
                if pot > cap:
                    flags |= F_BUY_SHRUNK
                min_out = km.v2_net_out(amt, p.r_quote, p.r_token, c.tax_buy) * 9900 // BPS
                if amt == 0 or min_out == 0:
                    flags |= F_BUY_SKIPPED
                else:
                    _, tax, net = p.buy(amt, c.tax_buy)
                    self.bal_q -= amt
                    self.burned += net
                    tokens_out += net
                    native_in = amt
                    self.pot_spent += amt
                    self.pot_tokens += net
                    if mode.echo:
                        m.kernel_tax(tax, token=True)       # the router buy is taxed in tokens, into the same vault
                        self.t_echo += tax

        if grad:
            self.t_inflow += inflow
            self.t_exec += executed
        else:
            self.q_inflow += inflow
            self.q_allow += r.allow
            self.q_exec += executed
        self.n_shrunk += 1 if flags & F_BUY_SHRUNK else 0
        self.n_skipped += 1 if flags & F_BUY_SKIPPED else 0
        return Row(epoch, dt, inflow, x, y, s0, ns, km.unpack_output(y), fg.unpack_state(ns), r,
                   reserve0, self.reserve, cum, 1 if grad else 0, executed, flags, min(echo, inflow),
                   tokens_out, native_in)


def run(name: str, flows: Sequence[int], settle_at: Optional[Callable[[int], bool]] = None,
        grad_epoch: Optional[int] = None, step: Callable = fg.step, exec_frac=None,
        env: Optional[km.Envelope] = None, mode: Optional[Mode] = None, net_buy=0,
        buy_blocked: Optional[Callable[[int], bool]] = None,
        step_fails: Optional[Callable[[int], bool]] = None) -> Trace:
    """flows[i] is the tax that outside trading pays during epoch i+1. settle_at(e) says whether a settle is
    sent at the end of epoch e (default: every epoch). The last epoch always settles. net_buy is a percentage
    or one percentage per epoch."""
    mode = mode or MODE
    k = Kernel(step, env, exec_frac, mode, buy_blocked, step_fails)
    t = Trace(name, kernel=k, mode=mode, epochs=len(flows))
    n = len(flows)
    for e in range(1, n + 1):
        if grad_epoch is not None and e == grad_epoch:
            k.market.graduate()
        k.market.trade(flows[e - 1], net_buy[e - 1] if isinstance(net_buy, (list, tuple)) else net_buy)
        if settle_at is None or settle_at(e) or e == n:
            row = k.settle(e)
            if row is not None:
                t.add(row)
    return t


# ----------------------------------------------------------------------------- printing
def fmt_amt(v: int) -> str:
    if v == 0:
        return "0"
    return f"{v:.3e}"


def kflags_str(flags: int) -> str:
    return ",".join(n for b, n in FLAG_NAMES if flags & b and b != F_GRADUATED) or "-"


def table(t: Trace, limit: Optional[int] = None) -> str:
    hdr = (f"{'ep':>4} {'dt':>2} {'inflow':>10} {'echo':>9} {'TAX':>4} {'RES':>4} {'mode':>6} {'T':>1} "
           f"{'buy':>3} {'alw':>3} {'res':>3} {'REL':>3} {'CEIL':>4} | {'A':>6} {'PK':>4} {'dd':>3} "
           f"{'LV':>2} {'W':>1} {'S':>1} {'CD':>2} {'TR':>2} | {'allow':>10} {'decided':>10} {'bought':>10} "
           f"{'reserve':>10} {'clamp':>5} {'kernel':>8} flags")
    lines = [hdr, "-" * len(hdr)]
    rows = t.rows if limit is None else t.rows[:limit]
    for r in rows:
        o, st = r.o, r.st
        fb = bool(r.flags & F_FALLBACK)                      # no chip answer: the telemetry columns mean nothing
        lines.append(
            f"{r.epoch:>4} {r.dt:>2} {fmt_amt(r.inflow):>10} {fmt_amt(r.echo):>9} {(r.x & 1023):>4} "
            f"{((r.x >> 40) & 1023):>4} "
            f"{'(none)' if fb else fg.MODE_NAMES[o['MODE']]:>6} {'-' if fb else o['TIER']:>1} "
            f"{o['T_BUY']:>3} {o['T_ALLOW']:>3} {o['T_RES']:>3} "
            f"{o['REL']:>3} {o['CEIL']:>4} | {st['A'] / 4:>6.2f} {st['PK']:>4} {o['AUX']:>3} "
            f"{st['LIVE']:>2} {st['WARM']:>1} {st['SUR']:>1} {st['CD']:>2} {st['TR']:>2} | "
            f"{fmt_amt(r.routed.allow):>10} {fmt_amt(r.buy_decided):>10} {fmt_amt(r.buy_executed):>10} "
            f"{fmt_amt(r.reserve_after):>10} {r.routed.clamp:>5} {kflags_str(r.flags):>8} "
            f"{'fallback word' if r.flags & F_FALLBACK else fg.flags_str(o['FLAGS'])}")
    return "\n".join(lines)


def _pct(a: int, b: int) -> float:
    return 100.0 * a / b if b else 0.0


def summary(t: Trace) -> Dict[str, object]:
    """Totals of one run. Percentages are of the tax that outside trading paid (the echo is the kernel's own
    money coming round again, so it is netted out of `bought`)."""
    k, m = t.kernel, t.kernel.market
    hist = [0] * 8
    for r in t.rows:
        if not r.flags & F_FALLBACK:
            hist[r.o["MODE"]] += 1
    q_rows = [r for r in t.rows if not r.grad]
    t_rows = [r for r in t.rows if r.grad]
    grad = k.graduated
    q_epochs = (t_rows[0].epoch - 1) if t_rows else t.epochs
    q_net = k.q_exec - k.q_echo
    q_left = m.outside_q - k.q_allow - q_net             # reserve + whatever still waits in the vault (or went to the pot)
    # after graduation the OKB that was not routed on the curve is the native pot, which the kernel buys with
    # on its own (without execution limits there is no pair to buy on: the pot counts as spent)
    pot_spent = (k.pot_spent if t.mode.limits else k.q_reserve_at_grad + k.pot_in) if grad else 0
    q = {"outside": m.outside_q, "echo": k.q_echo, "allow": k.q_allow, "bought": k.q_exec, "boughtNet": q_net,
         "boughtAll": q_net + pot_spent,
         "left": q_left, "reserveEnd": k.q_reserve_at_grad if grad else k.reserve,
         "allowPct": _pct(k.q_allow, m.outside_q), "boughtPct": _pct(q_net, m.outside_q),
         "leftPct": _pct(q_left, m.outside_q), "echoPct": _pct(k.q_echo, m.outside_q),
         "maxReserveEpochs": (max((r.reserve_after for r in q_rows), default=0) * q_epochs / m.outside_q)
         if m.outside_q else 0.0}
    out = {
        "mode": t.mode.label, "settles": len(t.rows), "epochs": t.epochs,
        "modes": {fg.MODE_NAMES[i]: hist[i] for i in range(5) if hist[i]},
        "tier_end": next((r.o["TIER"] for r in reversed(t.rows) if not r.flags & F_FALLBACK), 0),
        "clamp": t.max_clamp, "graduated": grad,
        "buysShrunk": k.n_shrunk, "buysSkipped": k.n_skipped, "fallbackSettles": k.n_fallback,
        "revertedSettles": len(k.reverted), "curveEndEpoch": k.curve_end_epoch, "quote": q,
    }
    if grad:
        t_in = m.outside_t + k.t_echo
        t_epochs = t.epochs - q_epochs
        out["token"] = {
            "outside": m.outside_t, "echo": k.t_echo, "burned": k.t_exec, "reserveEnd": k.reserve,
            "left": t_in - k.t_exec, "boughtPct": _pct(k.t_exec, t_in), "leftPct": _pct(t_in - k.t_exec, t_in),
            "echoPct": _pct(k.t_echo, t_in),
            "maxReserveEpochs": (max((r.reserve_after for r in t_rows), default=0) * t_epochs / t_in) if t_in else 0.0}
        out["pot"] = {"in": k.q_reserve_at_grad + k.pot_in, "graduationTax": m.lump_q, "spent": k.pot_spent,
                      "left": k.bal_q - k.credit_q, "tokensBought": k.pot_tokens,
                      "buys": sum(1 for r in t_rows if r.native_in)}
        main = {"in": t_in, "allow": 0, "bought": k.t_exec, "reserve_end": k.reserve, "allow_pct": 0.0,
                "bought_pct": out["token"]["boughtPct"], "reserve_end_pct": out["token"]["leftPct"],
                "max_reserve_epochs": out["token"]["maxReserveEpochs"], "echo_pct": out["token"]["echoPct"]}
    else:
        main = {"in": m.outside_q, "allow": k.q_allow, "bought": q_net, "reserve_end": k.reserve,
                "allow_pct": q["allowPct"], "bought_pct": q["boughtPct"], "reserve_end_pct": q["leftPct"],
                "max_reserve_epochs": q["maxReserveEpochs"], "echo_pct": q["echoPct"]}
    out.update(main)
    return out


def summary_line(t: Trace) -> str:
    s = summary(t)
    line = (f"{t.name:<22} ep {s['epochs']:>4} settles {s['settles']:>4}  in {fmt_amt(s['in']):>9}  "
            f"allow {s['allow_pct']:5.1f}%  bought {s['bought_pct']:5.1f}%  left {s['reserve_end_pct']:5.1f}%  "
            f"maxRes {s['max_reserve_epochs']:5.1f} ep  tier {s['tier_end']}  clamp {s['clamp']}  {s['modes']}")
    extra = []
    if t.mode.echo:
        extra.append(f"echo {s['echo_pct']:.1f}%")
    if s["buysShrunk"] or s["buysSkipped"]:
        extra.append(f"buys shrunk {s['buysShrunk']} skipped {s['buysSkipped']}")
    if s["curveEndEpoch"]:
        extra.append(f"curve end reached at epoch {s['curveEndEpoch']}")
    if s["fallbackSettles"] or s["revertedSettles"]:
        extra.append(f"reverted {s['revertedSettles']} fallback {s['fallbackSettles']}")
    if extra:
        line += "  [" + "; ".join(extra) + "]"
    if s["graduated"]:
        q = s["quote"]
        line += (f"\n{'':<22} on the curve: in {fmt_amt(q['outside']):>9}  allow {q['allowPct']:5.1f}%  "
                 f"bought {q['boughtPct']:5.1f}%  to the pot {q['leftPct']:5.1f}%  maxRes {q['maxReserveEpochs']:5.1f} ep")
        if "pot" in s and t.mode.limits:
            p = s["pot"]
            line += (f"\n{'':<22} native pot: {fmt_amt(p['in'])} wei in ({fmt_amt(p['graduationTax'])} is the tax of the "
                     f"graduating buy), {fmt_amt(p['spent'])} spent in {p['buys']} router buys, {fmt_amt(p['left'])} left")
    return line


# ----------------------------------------------------------------------------- flows
def const(v: int, n: int) -> List[int]:
    return [int(v)] * n


def lognormal(rng: random.Random, median: float, sigma: float, n: int, p_zero: float = 0.0) -> List[int]:
    return [0 if rng.random() < p_zero else int(median * rng.lognormvariate(0.0, sigma)) for _ in range(n)]


def scenarios() -> Dict[str, dict]:
    """name -> dict(flows=..., settle_at=..., grad_epoch=..., net_buy=..., buy_blocked=..., step_fails=...,
    exec_frac=..., note=...)."""
    S: Dict[str, dict] = {}
    f0 = 5 * 10 ** 15                         # 0.005 OKB of tax per epoch: about $20 of volume per epoch at 3%

    S["steady"] = dict(flows=const(f0, 400),
                       note="Constant inflow. The reserve must settle at a bounded level (leak = inflow share).")
    S["steady-small"] = dict(flows=const(25 * 10 ** 13, 400),
                             note="A $1 buy every epoch (2.5e14 wei of tax).")
    S["steady-large"] = dict(flows=const(2 * OKB, 400),
                             note="2 OKB of tax per epoch (about 67 OKB of volume per epoch): far more than the "
                                  "reference curve can absorb. Shows the kernel's buy cap and the end of the curve.")
    S["surge"] = dict(flows=const(f0, 60) + const(16 * f0, 8) + const(f0, 80),
                      note="16x surge for 8 epochs inside a steady flow.")
    S["ramp"] = dict(flows=const(f0, 40) + [int(f0 * 1.5 ** i) for i in range(1, 13)] + const(f0 * 130, 40),
                     note="Flow ramps up by 1.5x per epoch for 12 epochs and stays high.")
    S["drawdown"] = dict(flows=const(8 * f0, 60) + [int(8 * f0 * 0.9 ** i) for i in range(1, 60)] + const(f0 // 60, 80),
                         note="Slow bleed: 10% less tax every epoch.")
    S["crash"] = dict(flows=const(8 * f0, 60) + const(f0 // 8, 120),
                      note="Flow falls 64x in one epoch and stays there.")
    S["drought"] = dict(flows=const(f0, 60) + const(0, 160),
                        note="Steady flow, then nothing at all.")
    S["silence-return"] = dict(flows=const(f0, 60) + const(0, 200) + const(f0, 60),
                               note="Long silence, then the same ordinary volume returns. It must not be "
                                    "classed as a surge.")
    S["pause-return"] = dict(flows=const(f0, 40) + const(0, 5) + const(f0, 20) + const(0, 3) + const(f0, 20)
                             + const(0, 7) + const(f0, 20),
                             note="Short pauses of 5, 3 and 7 epochs between runs of the same volume.")
    rng = random.Random(7)
    S["dust"] = dict(flows=[25 * 10 ** 13 * rng.choice([1, 1, 1, 2, 4]) if rng.random() < 0.12 else 0
                            for _ in range(600)],
                     note="Sporadic $1-$4 buys, about one epoch in eight, zero in between.")
    rng = random.Random(8)
    S["subdust"] = dict(flows=[rng.choice([10 ** 11, 3 * 10 ** 12, 8 * 10 ** 12]) if rng.random() < 0.3 else 0
                               for _ in range(300)],
                        note="Inflows below the floor (1e11..8e12 wei). Nothing should be classed as live.")
    rng = random.Random(9)
    S["noisy"] = dict(flows=lognormal(rng, f0, 1.2, 600, p_zero=0.15),
                      note="Lognormal tax per epoch (sigma 1.2), 15% empty epochs: a small token with a few "
                           "trades per epoch.")
    rng = random.Random(10)
    S["noisy-dollars"] = dict(flows=lognormal(rng, 4 * 10 ** 14, 1.5, 800, p_zero=0.6), net_buy=50,
                              note="The reference token's likely life: median $1.6 buys, 60% empty epochs. Half "
                                   "of the tax comes from one-way buys, which move the curve.")
    S["launch"] = dict(flows=[int(OKB * 0.4 * 0.7 ** i) for i in range(40)] + lognormal(random.Random(11), 2 * 10 ** 15, 1.0, 300, 0.3),
                       net_buy=[100] * 40 + [0] * 300,
                       note="Launch spike decaying 30% per epoch (one-way buys: 43 OKB into the curve), then "
                            "ordinary noisy volume.")
    S["milestones"] = dict(flows=const(10 ** 15, 30) + const(10 ** 16, 30) + const(10 ** 17, 30) + const(10 ** 18, 30),
                           note="Cumulative tax crosses 0.009, 0.099 and 1.009 OKB: the allowance ratchet.")
    S["whale"] = dict(flows=const(f0, 40) + [3 * OKB] + const(f0, 60),
                      note="One epoch with 3 OKB of tax (100 OKB of volume): the allowance ceiling binds.")
    tok = 10 ** 22
    S["graduation"] = dict(flows=const(2 * 10 ** 16, 60) + const(tok, 60) + const(0, 40) + const(tok, 30),
                           grad_epoch=61, net_buy=50,
                           note="Graduates at epoch 61 (an outside buyer takes the rest of the curve): tax is then "
                                "1e22 token units (10,000 tokens) per epoch.")
    S["graduation-busy"] = dict(flows=const(2 * 10 ** 16, 30) + const(16 * 2 * 10 ** 16, 6)
                                + lognormal(random.Random(12), 3 * 10 ** 23, 1.2, 200, 0.1),
                                grad_epoch=37, net_buy=50,
                                note="Graduates in the middle of a surge (in BANK); token tax is noisy afterwards.")
    S["witness"] = dict(flows=[10 ** 16] + const(0, 30),
                        note="One epoch with 0.01 OKB of tax, then no outside trading. The shortest trace in which "
                             "one input word is answered with two different routes.")
    rng = random.Random(13)
    sched = set()
    e = 0
    while e < 700:
        e += rng.choice([1, 1, 1, 2, 3, 5, 9, 14, 15, 16, 22, 40])
        sched.add(e)
    S["hostile-timing"] = dict(flows=lognormal(random.Random(9), f0, 1.2, 600, p_zero=0.15),
                               settle_at=lambda ep, sched=sched: ep in sched,
                               note="The 'noisy' flow settled at irregular gaps of 1..40 epochs (DT saturates at 15).")
    S["failed-buys"] = dict(flows=const(f0, 120) + const(0, 120), exec_frac=lambda ep: 0 if ep % 3 else 128,
                            buy_blocked=lambda ep: ep % 3 != 0,
                            note="Two settles in three the Manager refuses the buy (BUY pause): the decided amount "
                                 "stays in the reserve and is offered again. (Idealised kernel: two buys in three "
                                 "fail and the third executes half.)")
    S["outage"] = dict(flows=const(f0, 240), step_fails=lambda ep: 100 <= ep < 140,
                       note="Neither evaluator answers from epoch 100 to 139. settle() reverts for 15 epochs (the "
                            "tax waits in the vault), then the fallback word routes until the evaluator is back.")
    return S


RUN_KEYS = ("settle_at", "grad_epoch", "exec_frac", "net_buy", "buy_blocked", "step_fails")


def run_named(name: str, mode: Optional[Mode] = None, **over) -> Trace:
    sc = dict(scenarios()[name])
    sc.update(over)
    return run(name, sc["flows"], mode=mode, **{k: sc[k] for k in RUN_KEYS if k in sc})


# ----------------------------------------------------------------------------- checks
def check_invariants(t: Trace) -> List[str]:
    """Checks that must hold on every row of every scenario."""
    bad = []
    env = fg.envelope()
    for r in t.rows:
        o = r.o
        fb = bool(r.flags & F_FALLBACK)
        if r.routed.clamp:
            bad.append(f"{t.name} ep {r.epoch}: clamp {r.routed.clamp}")
        if o["T_BUY"] + o["T_HOLD"] + o["T_ALLOW"] + o["T_RES"] != 256:
            bad.append(f"{t.name} ep {r.epoch}: T shares")
        if not fb and o["V_BUY"] + o["V_HOLD"] + o["V_ALLOW"] + o["V_RES"] != 256:
            bad.append(f"{t.name} ep {r.epoch}: V shares")
        if not (env.floorRel <= o["REL"] <= env.relMax):
            bad.append(f"{t.name} ep {r.epoch}: REL {o['REL']}")
        if r.routed.allow + r.routed.buy_share + r.routed.to_reserve != r.inflow:
            bad.append(f"{t.name} ep {r.epoch}: conservation")
        if r.reserve_after != r.reserve_before + r.inflow - r.routed.allow - r.buy_executed:
            bad.append(f"{t.name} ep {r.epoch}: reserve bookkeeping")
        if r.buy_executed > r.buy_decided:
            bad.append(f"{t.name} ep {r.epoch}: executed more than decided")
        if r.grad and r.routed.allow:
            bad.append(f"{t.name} ep {r.epoch}: allowance after graduation")
        if fb and r.s_after != r.s_before:
            bad.append(f"{t.name} ep {r.epoch}: a fallback settle changed the state")
    for a, b in zip(t.rows, t.rows[1:]):
        if b.o["TIER"] < a.o["TIER"] and not (a.flags | b.flags) & F_FALLBACK:
            bad.append(f"{t.name} ep {b.epoch}: tier decreased")
    return bad + check_books(t)


def check_books(t: Trace) -> List[str]:
    """Nothing is created or lost: every wei of tax is an allowance credit, a buy, the reserve, the native pot
    or still in the vault. Exact, in both regimes."""
    k, m = t.kernel, t.kernel.market
    bad = []

    def need(ok: bool, what: str):
        if not ok:
            bad.append(f"{t.name}: books: {what}")

    if not k.graduated:
        need(m.outside_q + k.q_echo == k.q_inflow + m.vault_q, "curve regime: tax paid = inflow recognised + vault")
        need(k.q_inflow == k.q_allow + k.q_exec + k.reserve, "curve regime: inflow = allowance + bought + reserve")
        need(k.bal_q == k.credit_q + k.reserve, "curve regime: balance = credits + reserve")
    else:
        need(k.q_inflow == k.q_allow + k.q_exec + k.q_reserve_at_grad, "curve regime: inflow = allowance + bought + reserve")
        need(m.outside_q + m.lump_q + k.q_echo == k.q_inflow + k.pot_in + m.vault_q,
             "native OKB: tax paid = inflow recognised + pot + vault")
        if t.mode.limits:
            need(k.q_reserve_at_grad + k.pot_in == k.pot_spent + (k.bal_q - k.credit_q), "native pot = spent + left")
        need(m.outside_t + k.t_echo == k.t_inflow + m.vault_t, "token regime: tax paid = inflow recognised + vault")
        need(k.t_inflow == k.t_exec + k.reserve, "token regime: inflow = burned + reserve")
        need(k.bal_t - k.locked == k.reserve, "token regime: balance = locked + reserve")
    return bad


def find_witness(t: Trace):
    """Two settles of one trace with the same input word and different routes."""
    seen: Dict[int, Row] = {}
    route_mask = (1 << 91) - 1                       # shares, REL, CEIL: everything the kernel acts on
    best = None
    for r in t.rows:
        q = seen.get(r.x)
        if q is not None and (q.y & route_mask) != (r.y & route_mask):
            cand = (q, r)
            if best is None or cand[1].epoch < best[1].epoch:
                best = cand
        seen.setdefault(r.x, r)
    return best


# ----------------------------------------------------------------------------- behaviour checks
def behaviour_checks(verbose: bool = True) -> bool:
    """Named, asserted findings. Each one is a sentence the judge guide relies on.

    They run on the kernel of the current mode (revision 2 unless a flag says otherwise). A statement about the
    chip and the kernel arithmetic at ANY scale cannot hold on a curve of fixed depth, so those few are run with
    execution limits off and say so in their name."""
    S = scenarios()
    out = []
    mode = MODE
    nolim = Mode(mode.echo, False)
    lim_note = " (execution limits off)" if mode.limits else ""
    P = fg.P

    def check(name: str, ok: bool, detail: str = ""):
        out.append((name, bool(ok), detail))

    # the simulated market is the real one: five numbers measured against the live IGNIX Manager and the live
    # Uniswap V2 router on a fork of X Layer (a fresh 3% curve graduating at 85 OKB)
    c = Curve.fresh()
    c1 = Curve.fresh()
    _, out1, tax1, _ = c1.buy(5 * 10 ** 17)
    c2 = Curve.fresh()
    spent2, _, _, sold_out2 = c2.buy(c2.cost_to_sell_out() + 10 * OKB)
    _, tax3, net3 = Pair(c2.collected, c2.pair_supply).buy(5 * 10 ** 17, c2.tax_buy)
    check("market model: a 0.5 OKB curve buy, the largest non-graduating buy, the cost of the whole curve (the "
          "excess is refunded), the 85 OKB / 200,000,000 token pair and a 0.5 OKB router buy all equal the fork "
          "measurements to the base unit",
          (c.v_quote, c.max_buy(), c.cost_to_sell_out()) == (28333333333333333333, 88541666666666666665, 88541666666666666667)
          and (out1, tax1) == (17769551133734382230654437, 15 * 10 ** 15)
          and (spent2, sold_out2, c2.collected, c2.pair_supply) == (88541666666666666667, True, 85 * OKB, 200_000_000 * OKB)
          and (net3, tax3) == (1131119259402211734708797, 34983069878418919630168))

    # the reserve is bounded under steady inflow: it settles at RC / LEAK = 32 epochs of inflow
    # (when the chip's own ceiling cuts the allowance, the cut part stays in the reserve too, so the level can
    # rise towards (RC + AL0) / LEAK = 56 epochs at very large flows; it is bounded all the same)
    for n in ("steady-small", "steady", "steady-large"):
        f = S[n]["flows"][0]
        big = n == "steady-large"
        t = run(n, const(f, 2000), mode=nolim if big else mode)
        res = [r.reserve_after / f for r in t.rows]
        bound = (P["RC"] + P["AL0"]) / P["LEAK"]
        check(f"{n}: reserve bounded under steady inflow{lim_note if big else ''} (settles at {res[-1]:.1f} epochs of "
              f"outside tax = {t.rows[-1].reserve_after / t.rows[-1].inflow:.1f} epochs of inflow; last 500 epochs "
              f"move it by {abs(res[-1] - res[-500]):.3f})",
              max(res) <= bound and abs(res[-1] - res[-500]) < 0.05 and t.max_clamp == 0)
        check(f"{n}: always CRUISE{lim_note if big else ''}", all(r.o["MODE"] == fg.CRUISE for r in t.rows))

    if mode.echo:
        t = run_named("steady")
        check("steady: the echo is exactly the buy tax of the kernel's own previous buy, and nothing else is added "
              "to outside tax",
              all(b.echo == a.buy_executed * REF["taxBuyBps"] // BPS and b.inflow == S["steady"]["flows"][0] + b.echo
                  for a, b in zip(t.rows, t.rows[1:])) and t.rows[0].echo == 0)
    if mode.limits:
        t = run_named("steady-large")
        k = t.kernel
        end = k.curve_end_epoch
        cur = k.market.curve
        shrunk = [r for r in t.rows if r.buy_executed]
        check(f"steady-large: 2 OKB of tax per epoch is more than the reference curve can take. Every buy is shrunk "
              f"to the kernel's cap ({min(r.buy_executed for r in shrunk) / OKB:.2f} to "
              f"{max(r.buy_executed for r in shrunk) / OKB:.2f} OKB) and the rest waits in the reserve; from epoch "
              f"{end} the curve is {cur.sellable - cur.sold} base units from its end and the kernel buys nothing "
              f"(it never graduates a token)",
              all(r.flags & F_BUY_SHRUNK and r.buy_executed < r.buy_decided for r in t.rows)
              and end is not None and cur.max_buy() == 0 and 1 <= cur.sellable - cur.sold < 10 ** 9 and not k.graduated
              and all(r.buy_executed == 0 and r.flags & F_BUY_SKIPPED for r in t.rows if r.epoch >= end)
              and all(r.buy_executed > 0 for r in t.rows if r.epoch < end - 1)
              and t.max_clamp == 0 and not check_books(t))

    # ordinary volume after a long silence is NOT a surge
    t = run_named("silence-return")
    back = [r for r in t.rows if r.epoch > 260]
    check("silence-return: no BANK epoch after the silence", all(r.o["MODE"] != fg.BANK for r in back))
    check("silence-return: the first settle after the silence re-seeds the average at the reading (warm flag, "
          "CRUISE), within one code of where it settles",
          back[0].o["FLAGS"] & 0x80 != 0 and back[0].o["MODE"] == fg.CRUISE
          and back[0].st["A"] == 4 * ((back[0].x & 1023) - P["FLOOR_Q"]) and back[0].st["PK"] == back[0].st["A"] // 4
          and abs(back[0].st["A"] - back[-1].st["A"]) <= 4)
    t = run_named("pause-return")
    check("pause-return: pauses of 3, 5 and 7 epochs never lead to BANK", all(r.o["MODE"] != fg.BANK for r in t.rows))
    # the same statement for every level and every pause length, on the bare chip: 40 epochs at one tax code,
    # a pause of k epochs, then 12 epochs at the same code again
    bad = 0
    n = 0
    for grad, floor in ((0, P["FLOOR_Q"]), (1, P["FLOOR_T"])):
        for tax in range(floor + 1, 1024, 3):
            xl = km.pack_input({"TAX": tax, "TAXCUM": 300, "RES": 700, "DT": 1, "GRAD": grad})
            xq = km.pack_input({"TAX": 0, "TAXCUM": 300, "RES": 700, "DT": 1, "GRAD": grad})
            s0 = 0
            for _ in range(40):
                s0, _ = fg.step(s0, xl)
            s = s0
            for k in range(1, 70):
                s, _ = fg.step(s, xq)                       # one more quiet epoch
                q = s
                n += 1
                for _ in range(12):
                    q, y = fg.step(q, xl)
                    if (y >> 91) & 7 == fg.BANK:
                        bad += 1
                        break
    check(f"pause sweep: {n} combinations of level (every third code above the floor, both regimes) and pause "
          f"(1..69 epochs): a return at the old level never enters BANK", bad == 0)

    # drought: the reserve is released in tranches with a cooldown, and nothing is stranded
    t = run_named("drought")
    peak = max(r.reserve_after for r in t.rows)
    check(f"drought: the reserve drains ({100 * t.rows[-1].reserve_after / peak:.2f}% of its peak is left after 160 quiet epochs)",
          t.rows[-1].reserve_after < peak // 100)
    rest = [r for r in t.rows if r.s_before >> 24 & 7 == fg.REST and (r.s_before >> 40 & 7) >= 1]
    check("drought: while cooling down the release is exactly the floor leak", all(r.o["REL"] == P["LEAK"] for r in rest) and len(rest) > 10)
    check("drought: DEFEND windows are 4 epochs, cooldowns 6",
          [fg.MODE_NAMES[r.o["MODE"]] for r in t.rows[65:76]] == ["DEFEND"] * 4 + ["REST"] * 6 + ["DEFEND"])

    # dust
    t = run_named("subdust")
    check("subdust: inflows below the floor never count as live flow", all(r.o["MODE"] == fg.IDLE for r in t.rows))
    t = run_named("dust")
    check("dust: sporadic $1-$4 buys are never banked as a surge for more than 4 epochs in a row",
          max((len(g) for g in "".join("B" if r.o["MODE"] == fg.BANK else "." for r in t.rows).split(".")), default=0) <= 4)

    # ratchet
    t = run_named("milestones")
    tiers = [r.o["TIER"] for r in t.rows]
    allow = {tier: next(r.o["T_ALLOW"] for r in t.rows if r.o["TIER"] == tier and r.o["MODE"] == fg.CRUISE) for tier in range(4)}
    check(f"milestones: tier steps 0,1,2,3 and the CRUISE allowance steps {allow}",
          sorted(set(tiers)) == [0, 1, 2, 3] and tiers == sorted(tiers)
          and [allow[i] for i in range(4)] == [P["AL0"], P["AL1"], P["AL2"], P["AL3"]])

    # ceiling
    t = run_named("whale")
    wh = max(t.rows, key=lambda r: r.inflow)
    check(f"whale: the allowance of the 3 OKB epoch is cut to exp8(CEIL) = {km.exp8(wh.o['CEIL']):.3e} wei by the chip's own "
          f"ceiling, no clamp", wh.routed.allow == km.exp8(wh.o["CEIL"]) and wh.routed.clamp == 0 and wh.o["MODE"] == fg.BANK)
    if mode.limits:
        check(f"whale: the buy decided in that epoch ({wh.buy_decided / OKB:.2f} OKB) is above the kernel's cap; "
              f"{wh.buy_executed / OKB:.3f} OKB executes and the rest stays in the reserve",
              wh.flags & F_BUY_SHRUNK and wh.buy_executed < wh.buy_decided
              and wh.reserve_after == wh.reserve_before + wh.inflow - wh.routed.allow - wh.buy_executed)

    # graduation
    t = run_named("graduation")
    k = t.kernel
    g = next(r for r in t.rows if r.grad)
    pre = [r for r in t.rows if not r.grad][-1]
    gx = km.unpack_fields(km.INPUT_FIELDS, g.x)
    check("graduation: averages re-seeded on the first token settle, tier kept, allowance zero from then on",
          g.o["FLAGS"] & 0x10 != 0 and g.o["FLAGS"] & 0x80 != 0 and g.o["TIER"] == pre.o["TIER"]
          and all(r.routed.allow == 0 and r.o["T_ALLOW"] == 0 for r in t.rows if r.grad))
    check("graduation: in the first graduated settle TAX equals TAXCUM, RES is 0 and GRAD is 1 (the regime restarts)",
          gx["TAX"] == gx["TAXCUM"] and gx["RES"] == 0 and gx["GRAD"] == 1 and gx["TAX"] > 0 and g.reserve_before == 0
          and g.cum == g.inflow)
    if mode.limits:
        pot = [r for r in t.rows if r.native_in]
        pair0 = Curve.fresh().pair_supply
        check(f"graduation: the OKB reserve left at graduation and the residual OKB tax (the tax of the graduating "
              f"buy included) are the native pot, {(k.q_reserve_at_grad + k.pot_in) / OKB:.3f} OKB here. The kernel "
              f"spends it in {len(pot)} capped router buys; their 3% token tax is {100 * k.t_echo / (k.t_echo + k.market.outside_t):.1f}% "
              f"of the token inflow of this run",
              k.pot_spent == k.q_reserve_at_grad + k.pot_in and k.bal_q == k.credit_q and len(pot) >= 1
              and pot[0].epoch == g.epoch and k.market.pair.r_token < pair0
              and all(r.native_in <= km.impact_cap(k.market.pair.r_quote, km.V2_ROUND_TRIP_FEE_BPS, 300, 300, k.env.capT)
                      for r in pot)
              and (not mode.echo or sum(r.echo for r in t.rows if r.grad) == k.t_echo))

    # scale: multiplying every amount by a power of two shifts every code by a multiple of 8, so the mode
    # sequence is identical as long as readings stay above the floor and the reserve above RESMIN
    base = S["surge"]["flows"]
    seqs = [[r.o["MODE"] for r in run("scale", [v << k for v in base], mode=nolim).rows] for k in (0, 4, 10)]
    check(f"scale{lim_note}: the surge scenario at x1, x16 and x1024 gives the same mode sequence",
          seqs[0] == seqs[1] == seqs[2])
    if mode.limits:
        runs = [run("scale", [v * num // den for v in base]) for num, den in ((1, 4), (1, 1), (4, 1))]
        check("scale: with execution limits on, the surge scenario at x1/4, x1 and x4 (no buy is shrunk) gives the "
              "same mode sequence too",
              all(tr.kernel.n_shrunk == 0 for tr in runs)
              and all([r.o["MODE"] for r in tr.rows] == [r.o["MODE"] for r in runs[0].rows] for tr in runs))

    # hostile timing
    t = run_named("hostile-timing")
    check("hostile-timing: irregular gaps of 1..40 epochs never set a clamp bit and never lower the tier",
          t.max_clamp == 0 and all(b.o["TIER"] >= a.o["TIER"] for a, b in zip(t.rows, t.rows[1:])))

    # buys that do not execute
    t = run_named("failed-buys")
    refused = [r for r in t.rows if r.epoch % 3 and r.buy_decided]
    check("failed-buys: what the buy leg does not execute stays in the reserve and is offered again"
          + (f" ({len(refused)} refused buys, flag 16 on each)" if mode.limits else ""),
          not check_books(t) and all(r.reserve_after == r.reserve_before + r.inflow - r.routed.allow - r.buy_executed
                                     for r in t.rows)
          and (not mode.limits or (len(refused) > 100 and all(r.buy_executed == 0 and r.flags & F_BUY_SKIPPED
                                                              for r in refused))))

    # evaluator failure: grace period, fallback word, recovery
    t = run_named("outage")
    k = t.kernel
    fb = [r for r in t.rows if r.flags & F_FALLBACK]
    before = [r for r in t.rows if r.epoch < 100][-1]
    after = [r for r in t.rows if r.epoch >= 140]
    n_fb, fba = fg.ENV["fallbackEpochs"], fg.ENV["fbAllow"]
    check(f"outage: while neither evaluator answers, settle() reverts for {n_fb - 1} epochs and the tax waits in the "
          f"vault; the first settle after that routes all {n_fb} epochs of it",
          k.reverted == list(range(100, 99 + n_fb)) and fb[0].epoch == 99 + n_fb
          and fb[0].inflow - fb[0].echo == n_fb * S["outage"]["flows"][0])
    check(f"outage: the fallback word routes {len(fb)} settles: {fba}/256 allowance, {256 - fba}/256 bought, half of "
          f"the reserve released, no clamp bit, state and DT origin untouched",
          len(fb) == 40 - (n_fb - 1)
          and all(r.o["T_ALLOW"] == fba and r.o["T_BUY"] == 256 - fba and r.o["REL"] == fg.ENV["relMax"]
                  and r.o["CEIL"] == km.LG8_MAX and r.routed.clamp == 0 and r.routed.allow == r.inflow * fba // 256
                  and r.s_before == r.s_after == before.s_after and r.dt == 15 for r in fb))
    back_cruise = next(r.epoch for r in after if all(q.o["MODE"] == fg.CRUISE for q in after if q.epoch >= r.epoch))
    check(f"outage: the first step after it has DT = 15 against one epoch of tax, so the rate is under-read once. "
          f"The tier is kept, no clamp fires, and after one DEFEND window the chip is in CRUISE again from epoch {back_cruise}",
          after[0].dt == 15 and after[0].s_before == before.s_after and after[0].o["TIER"] == before.o["TIER"]
          and after[1].dt == 1 and back_cruise <= 140 + 12 and t.max_clamp == 0)

    # conservation everywhere
    tot_ok = True
    for n in S:
        tot_ok &= not check_books(run_named(n))
    check("every scenario: tax paid = allowance + bought + reserve (+ native pot, + vault), to the base unit, in both regimes", tot_ok)

    ok = all(o for _, o, _ in out)
    if verbose:
        print("behaviour checks")
        for name, o, detail in out:
            print(f"  {'PASS' if o else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
        print("behaviour checks:", "PASS" if ok else "FAIL")
    return ok


# ----------------------------------------------------------------------------- cadence equivalence
# Definition (also in FLOW_GOVERNOR.md, "Cadence"). The reference keeper settles every epoch. Another
# keeper settles the same flow on a different schedule. A *common settle point* is an epoch at which
# both settle. The two are EQUIVALENT when all of the following hold:
#   E1  tier:   the allowance tier is identical at every common settle point, except that a milestone may be
#               passed one settle apart. Cumulative inflow includes the tax of the kernel's own buys (the echo),
#               and the two keepers have bought slightly different amounts by any given epoch, so one of them
#               can be a fraction of an epoch of inflow short of a milestone when the other has just passed it.
#               Asserted: never more than one tier apart, at most one such settle point per milestone, the same
#               tier at the end of the run. (Without the echo the tiers are identical everywhere.)
#   E2  clamps: neither run ever sets a clamp bit (exact);
#   E3  money:  at the end of the run the cumulative allowance differs by at most TOL_ALLOW points of
#               the tax outside trading paid, and the cumulative amount bought by at most TOL_BUY points;
#   E4  timing: at no fewer than TOL_MODE percent of the common settle points, the mode of the slower
#               keeper equals the mode of the reference keeper at some epoch within LAG epochs
#               (IDLE and CRUISE count as one mode: they route identically).
# E4 is only required on flows that are constant between changes (the DETERMINISTIC list) and for
# schedules that skip at most 3 epochs in a row; on noisy flows a slower keeper sees a smoother flow,
# so its BANK and DEFEND episodes legitimately differ and only E1..E3 are required.
#
# Three situations are outside the claim. They are measured and printed, not asserted:
#   * A spike shorter than the gap between settles (the SPIKE list: one epoch of tax 600 times the average)
#     cannot be seen as a spike by the slower keeper. There only E1, E2 and the allowance half of E3 are
#     required (everything not paid as allowance is bought eventually by both keepers; only the timing differs).
#   * A buy the kernel had to shrink. The kernel's buy cap is per settle, so when the decided buy is above
#     the cap a keeper who settles every k epochs executes up to k times less per epoch. The rest waits in the
#     reserve. The buy half of E3 is required only for pairs of runs in which no buy was shrunk or skipped.
#   * The pulse after graduation (the POT_PULSE list). The kernel spends the native pot through capped router
#     buys, one per settle, and their tax arrives as token inflow. How long that pulse lasts depends on the
#     number of settles, not of epochs, so E4 is not required there.
DETERMINISTIC = ["steady", "steady-small", "steady-large", "surge", "ramp", "drawdown", "crash", "drought",
                 "silence-return", "pause-return", "milestones", "graduation"]
NOISY = ["dust", "noisy", "noisy-dollars", "launch", "graduation-busy"]
SPIKE = ["whale"]
POT_PULSE = ["graduation"]
FAST = (2, 3, 4)
SLOW = (6, 8, 12)
TOL = {
    "fast": {"allow": 2.0, "buy": 6.0, "mode": 85.0},
    "slow": {"allow": 4.0, "buy": 10.0, "mode": None},
}


def _schedules():
    """name -> (class, factory(flows) -> settle_at)"""
    S = {}
    for k in FAST:
        S[f"every {k}"] = ("fast", lambda flows, k=k: (lambda e: e % k == 0), k + 2)
    for k in SLOW:
        S[f"every {k}"] = ("slow", lambda flows, k=k: (lambda e: e % k == 0), k + 2)

    def quiet_skip(flows, n=8):
        # settles whenever tax arrived in the epoch, otherwise every n-th epoch since its last settle
        last = [0]

        def f(e):
            if flows[e - 1] > 0 or e - last[0] >= n:
                last[0] = e
                return True
            return False
        return f
    S["skip quiet (8)"] = ("slow", quiet_skip, 10)

    def random_miss(flows, p=0.25, seed=5):
        rng = random.Random(seed)
        miss = [rng.random() < p for _ in flows]
        return lambda e: not miss[e - 1]
    S["miss 25%"] = ("fast", random_miss, 5)
    return S


def compare(name: str, settle_at, lag: int, mode: Optional[Mode] = None) -> Dict[str, object]:
    sdef = scenarios()[name]
    kw = {k: sdef[k] for k in RUN_KEYS if k in sdef and k != "settle_at"}
    base = run(name + "@1", sdef["flows"], None, mode=mode, **kw)
    by_epoch = {r.epoch: r for r in base.rows}
    t = run(name + "@x", sdef["flows"], settle_at, mode=mode, **kw)
    norm = lambda v: fg.CRUISE if v == fg.IDLE else v
    agree, common, tier_miss, tier_gap = 0, 0, 0, 0
    for r in t.rows:
        b = by_epoch.get(r.epoch)
        if b is None:
            continue
        common += 1
        if b.o["TIER"] != r.o["TIER"]:
            tier_miss += 1
            tier_gap = max(tier_gap, abs(b.o["TIER"] - r.o["TIER"]))
        near = {norm(by_epoch[e].o["MODE"]) for e in range(r.epoch - lag, r.epoch + lag + 1) if e in by_epoch}
        agree += norm(r.o["MODE"]) in near
    sb, st = summary(base), summary(t)
    qb, qt = sb["quote"], st["quote"]
    q_in = max(1, qb["outside"])
    allow = 100.0 * (qt["allow"] - qb["allow"]) / q_in                  # signed: positive = the slower keeper paid more
    buy = 100.0 * abs(qt["boughtAll"] - qb["boughtAll"]) / q_in if qb["outside"] else 0.0
    if "token" in sb:
        t_in = max(1, sb["token"]["outside"] + sb["token"]["echo"])
        buy = max(buy, 100.0 * abs(st["token"]["burned"] - sb["token"]["burned"]) / t_in)
    # a chip-decided buy that the kernel shrank or skipped (the router buys of the native pot do not count)
    limited = any(r.flags & (F_BUY_SHRUNK | F_BUY_SKIPPED) and not r.grad for r in base.rows + t.rows)
    return {"tier": tier_gap <= 1 and tier_miss <= 3 and sb["tier_end"] == st["tier_end"], "tier_miss": tier_miss,
            "clamp": base.max_clamp | t.max_clamp, "common": common, "mode": 100.0 * agree / max(1, common),
            "allow": abs(allow), "allow_signed": allow, "buy": buy, "settles": len(t.rows), "limited": limited}


def cadence_test(verbose: bool = True, mode: Optional[Mode] = None) -> bool:
    ok = True
    mode = mode or MODE
    S = scenarios()
    scheds = _schedules()
    worst = {}
    raised = lowered = 0.0
    tier_miss = limited = 0
    outside = []
    if verbose:
        print(f"cadence equivalence ({mode.label} kernel): reference keeper (every epoch) versus other schedules")
        print(f"{'scenario':<16} {'schedule':<15} {'settles':>7} {'tier':>5} {'mode agree%':>11} {'allow d':>8} {'bought d':>8} clamp")
    for n in DETERMINISTIC + NOISY + SPIKE:
        for sname, (cls, factory, lag) in scheds.items():
            c = compare(n, factory(S[n]["flows"]), lag, mode)
            tol = TOL[cls]
            pulse = n in POT_PULSE and mode.echo and mode.limits
            need_mode = tol["mode"] is not None and n in DETERMINISTIC and not pulse
            need_buy = n not in SPIKE and not c["limited"]
            good = (c["tier"] and c["clamp"] == 0 and c["allow"] <= tol["allow"]
                    and (not need_buy or c["buy"] <= tol["buy"])
                    and (not need_mode or c["mode"] >= tol["mode"]))
            ok &= good
            w = worst.setdefault(cls, {"allow": 0.0, "buy": 0.0, "mode": 100.0})
            w["allow"] = max(w["allow"], c["allow"])
            raised, lowered = max(raised, c["allow_signed"]), min(lowered, c["allow_signed"])
            tier_miss += c["tier_miss"]
            limited += 1 if c["limited"] else 0
            if need_buy:
                w["buy"] = max(w["buy"], c["buy"])
            if need_mode:
                w["mode"] = min(w["mode"], c["mode"])
            notes = []
            if c["tier_miss"]:
                notes.append(f"a milestone passed one settle apart ({c['tier_miss']} settle point)")
            if c["limited"] and n not in SPIKE:
                notes.append("buys shrunk by the kernel's cap: bought not asserted")
                outside.append((n, sname, "bought", c["buy"]))
            if pulse and tol["mode"] is not None:
                notes.append("pot pulse: mode agreement not asserted")
                outside.append((n, sname, "mode", c["mode"]))
            if n in SPIKE:
                outside.append((n, sname, "bought", c["buy"]))
            if verbose:
                print(f"{n:<16} {sname:<15} {c['settles']:>7} {str(c['tier']):>5} {c['mode']:>11.1f} "
                      f"{c['allow']:>8.2f} {c['buy']:>8.2f} {c['clamp']:>5}"
                      f"{'' if good else '   <-- outside tolerance'}{('   (' + '; '.join(notes) + ')') if notes else ''}")
    if verbose:
        for cls, w in worst.items():
            print(f"worst case, {cls} schedules: allowance {w['allow']:.2f} pts (limit {TOL[cls]['allow']}), "
                  f"bought {w['buy']:.2f} pts (limit {TOL[cls]['buy']})"
                  + (f", mode agreement on deterministic flows {w['mode']:.1f}% (limit {TOL[cls]['mode']})"
                     if TOL[cls]["mode"] is not None else ""))
        print(f"a slower keeper raised the allowance by at most {raised:.2f} pts and lowered it by at most {-lowered:.2f} pts")
        print(f"settle points at which the two tiers differ, over all runs: {tier_miss}")
        for what in ("bought", "mode"):
            vals = [v for _, _, k, v in outside if k == what]
            if vals:
                names = sorted({a for a, _, k, _ in outside if k == what})
                print(f"outside the claim, measured: {what} {'difference' if what == 'bought' else 'agreement'} "
                      f"{min(vals):.2f} to {max(vals):.2f} ({', '.join(names)})")
        print("cadence test:", "PASS" if ok else "FAIL")
    return ok


# ----------------------------------------------------------------------------- idealised versus revision 2
def compare_modes() -> None:
    """Every scenario under the idealised kernel and under revision 2, side by side."""
    print(f"{'scenario':<16} {'kernel':<11} {'allow%':>7} {'bought%':>8} {'left%':>7} {'maxRes':>7} {'echo%':>6} "
          f"{'IDLE':>5} {'CRUISE':>6} {'BANK':>5} {'DEFEND':>6} {'REST':>5} {'tier':>4}  notes")
    for n in scenarios():
        for mode in (IDEAL, REV2):
            t = run_named(n, mode=mode)
            s = summary(t)
            md = s["modes"]
            notes = []
            if s["buysShrunk"] or s["buysSkipped"]:
                notes.append(f"buys shrunk {s['buysShrunk']}, skipped {s['buysSkipped']}")
            if s["curveEndEpoch"]:
                notes.append(f"curve end at epoch {s['curveEndEpoch']}")
            if s["graduated"]:
                q = s["quote"]
                notes.append(f"curve regime: allow {q['allowPct']:.1f}% bought {q['boughtPct']:.1f}% "
                             f"to pot {q['leftPct']:.1f}%")
            print(f"{n:<16} {mode.label:<11} {s['allow_pct']:>7.2f} {s['bought_pct']:>8.2f} "
                  f"{s['reserve_end_pct']:>7.2f} {s['max_reserve_epochs']:>7.1f} {s['echo_pct']:>6.2f} "
                  f"{md.get('IDLE', 0):>5} {md.get('CRUISE', 0):>6} {md.get('BANK', 0):>5} {md.get('DEFEND', 0):>6} "
                  f"{md.get('REST', 0):>5} {s['tier_end']:>4}  {'; '.join(notes)}")


# ----------------------------------------------------------------------------- main
def main(argv=None) -> int:
    global MODE
    ap = argparse.ArgumentParser()
    ap.add_argument("name", nargs="?")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--cadence", action="store_true")
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--ideal", action="store_true", help="no echo and no execution limits")
    ap.add_argument("--no-echo", action="store_true")
    ap.add_argument("--no-limits", action="store_true")
    ap.add_argument("--dump")
    ap.add_argument("--limit", type=int)
    a = ap.parse_args(argv)
    MODE = Mode(echo=not (a.ideal or a.no_echo), limits=not (a.ideal or a.no_limits))
    S = scenarios()
    if a.list:
        for n, sc in S.items():
            print(f"{n:<18} {sc['note']}")
        return 0
    if a.compare:
        compare_modes()
        return 0
    print(f"kernel: {MODE.label}" + ("" if MODE == REV2 else "  (not what a real kernel does: for comparison only)"))
    if a.cadence:
        return 0 if cadence_test() else 1
    if a.name:
        t = run_named(a.name)
        print(S[a.name]["note"])
        print(table(t, a.limit))
        print(summary_line(t))
        w = find_witness(t)
        if w:
            print(f"witness: epochs {w[0].epoch} and {w[1].epoch} see the same input word and route differently")
        return 0
    bad: List[str] = []
    for n in S:
        t = run_named(n)
        print(summary_line(t))
        bad += check_invariants(t)
        if a.dump:
            os.makedirs(a.dump, exist_ok=True)
            with open(os.path.join(a.dump, f"{n}.txt"), "w") as f:
                f.write(S[n]["note"] + "\n" + table(t) + "\n" + summary_line(t) + "\n")
            with open(os.path.join(a.dump, f"{n}.trace.json"), "w") as f:
                json.dump({"name": n, "note": S[n]["note"],
                           "vectors": [{"epoch": r.epoch, "s": hex(r.s_before), "x": hex(r.x), "ns": hex(r.s_after),
                                        "y": hex(r.y)} for r in t.rows]}, f)
    print()
    okb = behaviour_checks()
    print()
    ok = cadence_test() and okb
    if bad:
        print("\nINVARIANT FAILURES:")
        for b in bad[:40]:
            print("  ", b)
    print("\nall scenario invariants hold" if not bad else f"\n{len(bad)} invariant failures")
    return 0 if (ok and not bad) else 1


if __name__ == "__main__":
    sys.exit(main())
