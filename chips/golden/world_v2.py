"""Settle-level model of kernel v2 in the test world of contracts/core-v2.

Two halves:

  * World: the IGNIX test doubles with a USD₮0 quote (contracts/core-v2/test/mocks/MockIgnixV2.sol)
    and kernel v1's MockToken and MockPair, arithmetic for arithmetic. A curve buy, a sell, the
    graduation, a V2 swap, a vault claim: each moves exactly the base units the Solidity moves.
  * KernelV2Sim: contracts/core-v2/src/KernelV2.sol `settle`, step for step, on that world, with the
    routing and the input codes of kernel_model_v2.py and the buy sizing of kernel_model.py.

gen_vectors_v2.py drives both with random event sequences and writes the expected record of every
settle; contracts/core-v2/test/golden/DiffSettlesV2.t.sol replays the same events on the real
KernelV2 and the Solidity doubles and compares every record, every book and every balance.

Integers only.
"""
from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

import kernel_model as km
import kernel_model_v2 as km2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "model"))

BPS = 10_000
SAT128 = km.AMOUNT_MAX
TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18

# record flags (core/interfaces/IKernelV1.sol RecordFlags)
F_FALLBACK, F_SEALED, F_CLAIM_FAILED, F_CURVE_READ_FAILED = 1, 2, 4, 8
F_BUY_SKIPPED, F_BUY_FAILED, F_GRADUATED, F_BUY_SHRUNK = 16, 32, 64, 128

KERNEL, VAULT, MANAGER, PAIR, DEAD, PAYEE, PAYER, WHALE = (
    "kernel", "vault", "manager", "pair", "dead", "payee", "payer", "whale")


class Revert(Exception):
    pass


def ceil_div(a: int, b: int) -> int:
    return 0 if a == 0 else (a - 1) // b + 1


def sub0(a: int, b: int) -> int:
    return a - b if a > b else 0


# ============================================================================ world

class Ledger:
    """An ERC-20 balance table: USD₮0 (MockUSDT0, no fee) or the project token (MockToken)."""

    def __init__(self):
        self.bal: Dict[str, int] = {}

    def of(self, a: str) -> int:
        return self.bal.get(a, 0)

    def _sub(self, a: str, x: int):
        if self.of(a) < x:
            raise Revert("balance")
        self.bal[a] = self.of(a) - x

    def _add(self, a: str, x: int):
        self.bal[a] = self.of(a) + x


class Usdt(Ledger):
    def mint(self, to: str, x: int):
        self._add(to, x)

    def move(self, frm: str, to: str, x: int):
        self._sub(frm, x)
        self._add(to, x)


class Token(Ledger):
    """MockToken: CurveOnly before graduation, fee-on-transfer on the pair after it."""

    def __init__(self, tax_buy: int, tax_sell: int):
        super().__init__()
        self.bal[MANAGER] = TOTAL_SUPPLY
        self.exempt = {MANAGER, VAULT}
        self.unlocked = False
        self.pair: Optional[str] = None
        self.tax_buy, self.tax_sell = tax_buy, tax_sell

    def move(self, frm: str, to: str, x: int) -> int:
        """Returns what `to` received."""
        if not self.unlocked and frm != MANAGER and to != MANAGER:
            raise Revert("CurveOnly")
        self._sub(frm, x)
        tax = 0
        if self.unlocked and self.pair is not None and frm not in self.exempt and to not in self.exempt:
            if frm == PAIR:
                tax = x * self.tax_buy // BPS
            elif to == PAIR:
                tax = x * self.tax_sell // BPS
        if tax:
            self._add(VAULT, tax)
        self._add(to, x - tax)
        return x - tax


@dataclass
class Curve:
    buy_fee: int = 100
    sell_fee: int = 100
    tax_buy: int = 300
    tax_sell: int = 300
    v_quote: int = 0
    v_token: int = 0
    sold: int = 0
    collected: int = 0
    sellable: int = 0
    reserve: int = 0


class World:
    """MockManagerV2 + MockVaultV2 + MockRouterV2 + MockPair + MockUSDT0 + MockToken."""

    def __init__(self, tax_bps: int, graduation: int):
        self.usdt = Usdt()
        self.token = Token(tax_bps, tax_bps)
        c = TOTAL_SUPPLY * 8000 // BPS
        d = TOTAL_SUPPLY - c
        tt = c * c // (c - d)
        e = graduation * (tt - c) // c
        self.curve = Curve(tax_buy=tax_bps, tax_sell=tax_bps, v_quote=e, v_token=tt, sellable=c, reserve=d)
        self.graduated = False
        self.r_tok = 0
        self.r_usd = 0
        self.buy_paused = False
        self.vault_paused = False

    # ---- manager
    def curve_buy(self, payer: str, recipient: str, amount_in: int, min_out: int) -> int:
        if self.buy_paused:
            raise Revert("Paused")
        if self.graduated:
            raise Revert("Graduated_")
        t = self.curve
        self.usdt.move(payer, MANAGER, amount_in)          # pullExact (no fee)
        fee_bps = t.buy_fee + t.tax_buy
        net = amount_in - amount_in * fee_bps // BPS
        left = t.sellable - t.sold
        out = t.v_token - ceil_div(t.v_quote * t.v_token, t.v_quote + net)
        refund = 0
        if out >= left:
            out = left
            net = ceil_div(t.v_quote * left, t.v_token - left)
            gross_needed = ceil_div(net * BPS, BPS - fee_bps)
            if gross_needed < amount_in:
                refund = amount_in - gross_needed
                amount_in = gross_needed
        if out < min_out:
            raise Revert("Slippage")
        if out == 0:
            raise Revert("SoldOut")
        tax = amount_in * t.tax_buy // BPS
        t.v_quote += net
        t.v_token -= out
        t.sold += out
        t.collected += net
        self.token.move(MANAGER, recipient, out)
        if tax:
            self.usdt.move(MANAGER, VAULT, tax)
        if t.sold == t.sellable:
            self._graduate()
        if refund:
            self.usdt.move(MANAGER, recipient, refund)
        return out

    def curve_sell(self, seller: str, token_in: int) -> int:
        if self.graduated:
            raise Revert("Graduated_")
        t = self.curve
        self.token.move(seller, MANAGER, token_in)
        gross = t.v_quote - ceil_div(t.v_quote * t.v_token, t.v_token + token_in)
        p_fee = gross * t.sell_fee // BPS
        j_fee = gross * t.tax_sell // BPS
        net = gross - p_fee - j_fee
        t.v_quote -= gross
        t.v_token += token_in
        t.sold -= token_in
        t.collected -= gross
        self.usdt.move(MANAGER, seller, net)
        if j_fee:
            self.usdt.move(MANAGER, VAULT, j_fee)
        return net

    def cost_to_graduate(self) -> int:
        t = self.curve
        left = t.sellable - t.sold
        if left == 0:
            return 0
        fee_bps = t.buy_fee + t.tax_buy
        net = ceil_div(t.v_quote * left, t.v_token - left)
        return ceil_div(net * BPS, BPS - fee_bps)

    def _graduate(self):
        t = self.curve
        self.graduated = True
        self.token.unlocked = True
        self.token.move(MANAGER, PAIR, t.reserve)
        self.usdt.move(MANAGER, PAIR, t.collected)
        self._sync()
        self.token.pair = PAIR

    def _sync(self):
        self.r_tok = self.token.of(PAIR)
        self.r_usd = self.usdt.of(PAIR)

    # ---- router (MockRouterV2) and pair (MockPair)
    def swap(self, frm: str, quote_in: bool, amount_in: int, to: str, min_out: int) -> int:
        """swapExactTokensForTokensSupportingFeeOnTransferTokens. Returns what `to` received."""
        if not self.graduated:
            raise Revert("no pair")
        if quote_in:
            before = self.token.of(to)
            self.usdt.move(frm, PAIR, amount_in)
            r_in, r_out = self.r_usd, self.r_tok
            amount_input = self.usdt.of(PAIR) - r_in
        else:
            before = self.usdt.of(to)
            self.token.move(frm, PAIR, amount_in)
            r_in, r_out = self.r_tok, self.r_usd
            amount_input = self.token.of(PAIR) - r_in
        f = amount_input * 997
        out = f * r_out // (r_in * 1000 + f)
        if out == 0:
            raise Revert("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT")
        if out >= r_out:
            raise Revert("UniswapV2: INSUFFICIENT_LIQUIDITY")
        if quote_in:
            self.token.move(PAIR, to, out)
        else:
            self.usdt.move(PAIR, to, out)
        self._sync()
        got = (self.token.of(to) if quote_in else self.usdt.of(to)) - before
        if got < min_out:
            raise Revert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT")
        return got

    # ---- vault (MockVaultV2)
    def claim(self, asset: str) -> int:
        if self.vault_paused:
            raise Revert("Paused")
        if asset == "usdt":
            amt = self.usdt.of(VAULT)
            if amt == 0:
                raise Revert("NothingToClaim")
            self.usdt.move(VAULT, KERNEL, amt)
        else:
            amt = self.token.of(VAULT) if self.token.pair is not None else 0
            if amt == 0:
                raise Revert("NothingToClaim")
            self.token.move(VAULT, KERNEL, amt)
        return amt

    def ledger(self, asset: str) -> Ledger:
        return self.usdt if asset == "usdt" else self.token


# ============================================================================ chips

class ScriptChip:
    """ChipModel SCRIPT (contracts/core/test/mocks/MockTapeOut.sol): word[counter % k], counter + 1."""

    def __init__(self, n_state: int, words: List[int]):
        self.n, self.words = n_state, words

    def step(self, s: int, x: int) -> Tuple[int, int]:
        s &= (1 << self.n) - 1 if self.n < 256 else (1 << 256) - 1
        return (s + 1) & ((1 << self.n) - 1), self.words[s % len(self.words)]


class FlowGovernorChip:
    """The Flow Governor's bit-exact model (chips/model/flow_governor.py); the netlist chips/out/fg.hex."""

    n = 64

    def __init__(self):
        import flow_governor as fg
        self._step = fg.step

    def step(self, s: int, x: int) -> Tuple[int, int]:
        return self._step(s, x)


# ============================================================================ kernel

@dataclass
class EnvV2:
    capT: int
    capV: int
    allowCumBps: int
    ceilMax: int
    relMax: int
    floorRel: int
    floorMin: int
    epochLen: int
    fallbackEpochs: int
    fbAllow: int

    def km(self) -> km.Envelope:
        return km.Envelope(capT=self.capT, capV=self.capV, allowCumBps=self.allowCumBps, ceilMax=self.ceilMax,
                           relMax=self.relMax, floorRel=self.floorRel, floorMin=self.floorMin)


EVAL_OK, EVAL_TAPEOUT_DEAD, EVAL_BOTH_DEAD = 0, 1, 2


@dataclass
class KernelV2Sim:
    env: EnvV2
    shift: int
    chip: object
    bind_time: int
    sealed_always: bool = False      # the chip only runs on the sealed evaluator (the Flow Governor world)
    last_epoch: int = 0
    last_step_epoch: int = 0
    count: int = 0
    graduated: bool = False
    state: int = 0
    reserve: int = 0
    cum_inflow: int = 0
    allow_paid_cum: int = 0
    locked: int = 0
    burned: int = 0
    token_supply: int = TOTAL_SUPPLY
    credits: Dict[Tuple[str, str], int] = field(default_factory=dict)
    total_credits: Dict[str, int] = field(default_factory=lambda: {"usdt": 0, "token": 0})
    eval_mode: int = EVAL_OK

    def _credit(self, payee: str, asset: str, x: int):
        self.credits[(payee, asset)] = self.credits.get((payee, asset), 0) + x
        self.total_credits[asset] += x

    def epoch_at(self, now: int) -> int:
        return min((now - self.bind_time) // self.env.epochLen, (1 << 32) - 1)

    def settle(self, w: World, now: int) -> dict:
        """One KernelV2.settle(). Raises Revert with the error name when the Solidity reverts."""
        e = self.env
        epoch = self.epoch_at(now)
        if epoch <= self.last_epoch:
            raise Revert("EpochNotElapsed")
        last_step = self.last_step_epoch
        if self.eval_mode == EVAL_BOTH_DEAD and epoch - last_step < e.fallbackEpochs:
            raise Revert("StepFailed")  # inside the grace period nothing moves, the claim included

        # 1. regime
        grad = self.graduated
        if not grad and w.token.pair is not None:
            grad = True
            self.graduated = True
            self.reserve = 0
            self.cum_inflow = 0
            self.allow_paid_cum = 0
        flags = F_GRADUATED if grad else 0
        asset = "token" if grad else "usdt"

        # 2. claims
        for a in (["usdt", "token"] if grad else ["usdt"]):
            held = w.ledger(a).of(VAULT)
            if held == 0:
                continue
            try:
                w.claim(a)
            except Revert:
                flags |= F_CLAIM_FAILED

        # 3. books
        owed = self.total_credits[asset] + (self.locked if grad else 0)
        free = min(SAT128, sub0(w.ledger(asset).of(KERNEL), owed))
        reserve0 = min(self.reserve, free)
        inflow = free - reserve0
        cum = min(SAT128, self.cum_inflow + inflow)

        # 4-5. curve read and input word
        c = w.curve
        s = 0 if grad else self.shift
        prog = km.prog_code(c.sold, c.sellable, grad)
        lock = km.lock_code(self.locked + self.burned, self.token_supply)
        dt = km.dt_code(epoch, last_step)
        x = km2.input_word_v2(inflow, cum, reserve0, prog, lock, dt, grad, self.shift)

        # 6. evaluator
        if self.eval_mode == EVAL_BOTH_DEAD:
            step_ok = False
        else:
            step_ok = True
            ns, out_word = self.chip.step(self.state, x)
            if self.eval_mode == EVAL_TAPEOUT_DEAD or self.sealed_always:
                flags |= F_SEALED
        if not step_ok:
            out_word = km.fallback_word(km.Envelope(capT=e.capT, relMax=e.relMax), e.fbAllow)
            ns = self.state
            flags |= F_FALLBACK

        # 7. route
        r = km2.route_tax_v2(e.km(), out_word, inflow, reserve0, cum, self.allow_paid_cum, grad, s)

        # 8. effects
        if step_ok:
            self.state = ns
            self.last_step_epoch = epoch
        self.last_epoch = epoch
        self.count += 1
        n = self.count
        self.cum_inflow = cum
        self.allow_paid_cum = min(SAT128, self.allow_paid_cum + r.allow)
        self.reserve = reserve0 + inflow - r.allow
        if r.allow:
            self._credit(PAYEE, asset, r.allow)

        # 9. legs (buys are always enabled: the factory refuses anything else)
        executed = tokens_out = quote_in = 0
        if r.buy_decided:
            if grad:
                w.token.move(KERNEL, DEAD, r.buy_decided)        # untaxed: neither side is the pair
                executed = tokens_out = r.buy_decided
                self.burned = min(SAT128, self.burned + r.buy_decided)
            else:
                amt, mout, shrunk = km.curve_buy(r.buy_decided, c.v_quote, c.v_token, c.sold, c.sellable,
                                                 c.buy_fee, c.sell_fee, c.tax_buy, c.tax_sell, e.capT)
                if shrunk:
                    flags |= F_BUY_SHRUNK
                if mout == 0:
                    flags |= F_BUY_SKIPPED
                elif w.buy_paused:
                    flags |= F_BUY_SKIPPED                       # the Manager's Paused() is a guard
                else:
                    got = w.curve_buy(KERNEL, KERNEL, amt, mout)
                    executed, tokens_out = amt, got
                    self.locked = min(SAT128, self.locked + got)
            self.reserve = sub0(self.reserve, executed)
        if grad:
            q0 = w.usdt.of(KERNEL)
            pot = sub0(q0, self.total_credits["usdt"])
            if pot:
                r_tok, r_usd = w.r_tok, w.r_usd
                if r_tok == 0 or r_usd == 0:
                    flags |= F_BUY_SKIPPED
                else:
                    cap = km.impact_cap(r_usd, km.V2_ROUND_TRIP_FEE_BPS, c.tax_buy, c.tax_sell, e.capT)
                    amt = min(SAT128, pot)
                    if amt > cap:
                        amt = cap
                        flags |= F_BUY_SHRUNK
                    min_out = km.v2_net_out(amt, r_usd, r_tok, c.tax_buy) * 9_900 // BPS
                    if amt == 0 or min_out == 0:
                        flags |= F_BUY_SKIPPED
                    else:
                        d0 = w.token.of(DEAD)
                        w.swap(KERNEL, True, amt, DEAD, min_out)
                        got = w.token.of(DEAD) - d0
                        quote_in = q0 - w.usdt.of(KERNEL)
                        tokens_out += got
                        self.burned = min(SAT128, self.burned + got)

        return {
            "n": n, "epoch": epoch, "time": now, "clampBits": r.clamp, "flags": flags,
            "inputs": x, "outputs": out_word, "stateAfter": self.state, "inflow": inflow,
            "reserveBefore": reserve0, "allow": r.allow, "buyDecided": r.buy_decided,
            "buyExecuted": executed, "tokensOut": tokens_out, "quoteIn": quote_in,
            "cumInflow": cum, "allowPaidCum": self.allow_paid_cum,
        }

    def withdraw(self, w: World, payee: str, asset: str) -> int:
        paid = self.credits.get((payee, asset), 0)
        if paid == 0:
            return 0
        self.credits[(payee, asset)] = 0
        self.total_credits[asset] -= paid
        w.ledger(asset).move(KERNEL, payee, paid)
        return paid

    def burn_locked(self, w: World) -> int:
        if not self.graduated:
            raise Revert("NotGraduated")
        amt = self.locked
        if amt == 0:
            return 0
        self.locked = 0
        w.token.move(KERNEL, DEAD, amt)
        self.burned = min(SAT128, self.burned + amt)
        return amt
