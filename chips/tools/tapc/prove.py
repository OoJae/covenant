"""Proofs over every state and every input.

A chip core is a pure combinational function core(s, x) -> (ns, y), and so is one beat of a TAP-20 netlist
(tapc.unpack). Every claim below is therefore one combinational query with s and x free: no unrolling, no
bounded depth, no sampling.

  (a) equiv_yosys     RTL core == netlist bytes, by a Yosys miter and the built-in SAT pass (MiniSat):
                      `miter -equiv` + `sat -prove trigger 0`.
  (b) prove_properties  a named 1-bit output of a small wrapper module is 1 for every (s, x):
                      `sat -prove <signal> 1`. The wrapper instantiates the unpacked netlist (and/or the RTL).
  (c) the z3 path, independent of (a) and (b):
        equiv_z3          the netlist formula is built straight from the TAP-20 bytes (no unpack, no miter,
                          no MiniSat) and compared with the word-level SMT-LIB that Yosys writes for the RTL
                          (no techmap, no ABC);
        check_z3          Python predicates over a Z3Circuit, again built straight from the bytes;
        equiv_netlists_z3 two netlists against each other.

What is shared between the two paths: the Verilog front end of Yosys (read_verilog, proc, flatten). What is
not: the netlist decoding, the encoding of the problem and the solver.

RTL must be fully defined: an `x` (don't care) in the RTL is read as 0 by both paths.
"""
from __future__ import annotations

import os
import re
import shutil
import time
from dataclasses import dataclass, field
from typing import Callable, Optional, Sequence

from . import yosys
from .netlist import LATCH, NAND, Netlist, check
from .sim import int_to_bytes
from .unpack import to_verilog

PROVED, FAILED, TIMEOUT, ERROR = "proved", "failed", "timeout", "error"


@dataclass
class ProofResult:
    name: str
    status: str                       # proved | failed | timeout | error
    engine: str                       # "yosys-sat" | "z3"
    seconds: float
    counterexample: dict = field(default_factory=dict)   # signal -> integer value (bit i of the vector = bit i)
    detail: str = ""
    log: str = ""                     # path of the log file, when there is one

    @property
    def ok(self) -> bool:
        return self.status == PROVED

    def line(self) -> str:
        s = f"{self.status.upper():8s} {self.name}  [{self.engine}, {self.seconds:.2f} s]"
        if self.counterexample:
            s += "  counterexample: " + ", ".join(f"{k}=0x{v:x}" for k, v in sorted(self.counterexample.items()))
        if self.detail and self.status != PROVED:
            s += f"  ({self.detail})"
        return s

    def as_dict(self) -> dict:
        return {"name": self.name, "status": self.status, "engine": self.engine,
                "seconds": round(self.seconds, 3),
                "counterexample": {k: hex(v) for k, v in sorted(self.counterexample.items())},
                "detail": self.detail}


class ProofError(RuntimeError):
    pass


# ------------------------------------------------------------------------------------------------ helpers

def _elaborate(local: Sequence[str], top: str) -> list:
    """Yosys commands that read the sources and reduce `top` to plain combinational cells.

    `proc -norom` keeps case tables as multiplexers. Without it `proc` turns them into ROM cells ($memrd_v2),
    which the SAT pass cannot model at all and which the SMT-LIB backend models as an unconstrained array (a
    spurious counterexample). `memory` then maps any memory the source itself declares to logic.
    """
    return [f"read_verilog -sv {' '.join(local)}", f"hierarchy -check -top {top}", "proc -norom", "flatten",
            "memory", "opt_clean",
            # a core is a pure function: any storage element or free constant left here is an error
            "select -assert-none " + " ".join("t:" + t for t in _STATEFUL_CELLS)]


def _failure_detail(log: str, what: str) -> str:
    """A readable reason from a Yosys log that stopped early."""
    if "Assertion failed: selection is not empty" in log:
        m = re.search(r"Selection contains:\s*\n\s*(\S+)", log)
        return ("the design is not combinational after elaboration: it contains a register, latch, memory or "
                "free constant" + (f" ({m.group(1)})" if m else ""))
    tail = " | ".join(log.strip().splitlines()[-4:])
    return f"{what}: {tail}"


_STATEFUL_CELLS = ("$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce", "$dffsr", "$dffsre", "$aldff",
                   "$aldffe", "$dlatch", "$adlatch", "$dlatchsr", "$sr", "$ff", "$mem", "$mem_v2", "$memrd",
                   "$memrd_v2", "$memwr", "$memwr_v2", "$meminit", "$meminit_v2", "$anyconst", "$anyseq",
                   "$allconst", "$allseq")


def _prepare(work: str, sources: Sequence[str]) -> list:
    """Copy sources into the working directory (Yosys runs there; see tapc.yosys). Returns local names."""
    os.makedirs(work, exist_ok=True)
    local = []
    for i, src in enumerate(sources):
        if not os.path.isfile(src):
            raise ProofError(f"no such source file: {src}")
        dst = f"src{i}_{os.path.basename(src)}"
        shutil.copyfile(src, os.path.join(work, dst))
        local.append(dst)
    return local


def _as_netlist(tap, n_in, n_out) -> Netlist:
    return tap if isinstance(tap, Netlist) else check(bytes(tap), n_in, n_out)


_SAT_OK = "SAT proof finished - no model found: SUCCESS!"
_SAT_FAIL = "SAT proof finished - model found: FAIL!"
_ROW = re.compile(r"^\s*(?:\d+\s+)?\\(\S+)\s+\S+\s+\S+\s+([01x_ ]+?)\s*$")


def _parse_sat_block(block: str) -> tuple:
    """(status, counterexample, detail) from one `sat` pass log."""
    if _SAT_OK in block:
        return PROVED, {}, ""
    if _SAT_FAIL in block:
        cex = {}
        for line in block.splitlines():
            m = _ROW.match(line)
            if m:
                bits = m.group(2).replace(" ", "").replace("_", "").replace("x", "0")
                if bits:
                    cex[m.group(1)] = int(bits, 2)
        return FAILED, cex, ""
    if "TIMEOUT" in block or "Interrupted SAT solver" in block:
        return TIMEOUT, {}, "SAT solver timed out"
    tail = " | ".join(block.strip().splitlines()[-3:])
    return ERROR, {}, f"no verdict in the Yosys log: {tail}"


_STAMP = re.compile(r"^\[(\d+\.\d+)\] ?", re.M)
GRACE = 30          # seconds allowed on top of a proof's timeout for starting Yosys and elaborating


def _blocks(log: str) -> dict:
    """Split a log on the TAPC-BEGIN / TAPC-END markers written by the scripts below.
    Returns {tag: (text, seconds)}; seconds is None when the log carries no timestamps."""
    out = {}
    for m in re.finditer(r"^(?:\[(\d+\.\d+)\] ?)?TAPC-BEGIN (\S+)\n(.*?)^(?:\[(\d+\.\d+)\] ?)?TAPC-END \2$",
                         log, re.S | re.M):
        secs = float(m.group(4)) - float(m.group(1)) if m.group(1) and m.group(4) else None
        out[m.group(2)] = (_STAMP.sub("", m.group(3)), secs)
    return out


def _begin_stamp(log: str, tag: str) -> Optional[float]:
    """Seconds into the Yosys run at which proof `tag` began; None if it never began."""
    m = re.search(rf"^(?:\[(\d+\.\d+)\] ?)?TAPC-BEGIN {re.escape(tag)}$", log, re.M)
    if m is None:
        return None
    return float(m.group(1)) if m.group(1) else 0.0


# ------------------------------------------------------------------------------------------------ (a) equivalence, Yosys

def equiv_yosys(sources: Sequence[str], top: str, tap, n_in: Optional[int] = None, n_out: Optional[int] = None,
                work: str = "build/prove", timeout: int = 1800, name: Optional[str] = None) -> ProofResult:
    """Prove RTL core `top` == TAP-20 netlist `tap` for every (s, x)."""
    nl = _as_netlist(tap, n_in, n_out)
    name = name or f"{top} == netlist"
    work = os.path.abspath(work)
    local = _prepare(work, sources)
    gate = "tapc_gate"
    with open(os.path.join(work, "gate.v"), "w", encoding="utf-8") as f:
        f.write(to_verilog(nl, module=gate))
    script = "\n".join(_elaborate(local, top) + [
        "read_verilog gate.v",
        # Two-sided: every output bit of the gate netlist must equal the RTL's. (-ignore_gold_x would let
        # an undriven RTL bit read as 0 and turn the check into "netlist >= RTL" wherever the RTL is not
        # constant; the RTL has no x, so the flag is not needed.)
        f"miter -equiv -flatten -make_outputs {top} {gate} tapc_miter",
        "hierarchy -top tapc_miter",
        "log TAPC-BEGIN equiv",
        f"sat -prove trigger 0 -show-inputs -show-outputs -timeout {int(timeout)} tapc_miter",
        "log TAPC-END equiv",
    ]) + "\n"
    t0 = time.perf_counter()
    run = yosys.run_script(script, work, tag="equiv", timeout=timeout + GRACE, check=False, timestamps=True)
    dt = time.perf_counter() - t0
    log_path = os.path.join(work, "equiv.log")
    hit = _blocks(run.log).get("equiv")
    if hit is None:
        if run.returncode == -9:
            return ProofResult(name, TIMEOUT, "yosys-sat", dt, {}, f"no verdict within {int(timeout)} s", log_path)
        return ProofResult(name, ERROR, "yosys-sat", dt, {},
                           _failure_detail(_STAMP.sub("", run.log), "yosys did not reach the SAT pass"), log_path)
    block = hit[0]
    # the miter must compare exactly the ports of the netlist: (ns, y), or y alone for a combinational chip
    want = {"in_x", "gate_y", "gold_y"} if nl.n_in else {"gate_y", "gold_y"}
    if nl.n_state:
        want |= {"in_s", "gate_ns", "gold_ns"}
    seen = set(re.findall(r"Import show expression: \\(\S+)", block))
    if not want <= seen:
        return ProofResult(name, ERROR, "yosys-sat", dt, {},
                           f"miter ports {sorted(seen)} do not cover {sorted(want)}; do the port lists match?",
                           log_path)
    status, cex, detail = _parse_sat_block(block)
    cex = {("s" if k == "in_s" else "x" if k == "in_x" else k): v for k, v in cex.items() if k != "trigger"}
    return ProofResult(name, status, "yosys-sat", dt, cex, detail, log_path)


# ------------------------------------------------------------------------------------------------ (b) properties, Yosys

def prove_properties(sources: Sequence[str], top: str, signals: Sequence[str] = ("ok",),
                     tap=None, n_in: Optional[int] = None, n_out: Optional[int] = None,
                     tap_module: Optional[str] = None, work: str = "build/prove", timeout: int = 1800,
                     engine: str = "yosys") -> list:
    """Prove that each named 1-bit output of wrapper module `top` is 1 for every value of its inputs.

    The wrapper has the free inputs (normally `s` and `x`) and instantiates whatever it talks about. When
    `tap` is given, the netlist is unpacked to a Verilog module named `tap_module` and added to the sources,
    so the wrapper can instantiate it:

        module p_flag(input [8:0] s, input [1:0] x, output ok);
          wire [8:0] ns; wire [9:0] y;
          probe_tap u(.s(s), .x(x), .ns(ns), .y(y));
          assign ok = !s[8] || ns[8];
        endmodule

    engine: "yosys" (built-in SAT) or "z3" (the same flattened wrapper written as SMT-LIB and given to z3).
    Returns one ProofResult per signal. `timeout` is per signal; a signal that exceeds it is reported as
    `timeout` and the remaining ones are proven in a fresh Yosys process.
    """
    work = os.path.abspath(work)
    local = _prepare(work, sources)
    if tap is not None:
        nl = _as_netlist(tap, n_in, n_out)
        with open(os.path.join(work, "gate.v"), "w", encoding="utf-8") as f:
            f.write(to_verilog(nl, module=tap_module or "chip_tap"))
        local.append("gate.v")
    head = _elaborate(local, top)
    if engine == "z3":
        return _properties_z3(head, top, signals, work, timeout)
    log_path = os.path.join(work, f"prop_{top}.log")
    results: dict = {}
    pending = list(enumerate(signals))
    while pending:
        lines = list(head)
        for i, sig in pending:
            lines += [f"log TAPC-BEGIN p{i}",
                      f"sat -prove {sig} 1 -show-inputs -timeout {int(timeout)} {top}",
                      f"log TAPC-END p{i}"]
        t0 = time.perf_counter()
        run = yosys.run_script("\n".join(lines) + "\n", work, tag=f"prop_{top}", timeout=timeout + GRACE,
                               check=False, timestamps=True)
        dt = time.perf_counter() - t0
        blocks = _blocks(run.log)
        share = dt / len(pending)
        for i, sig in pending:
            hit = blocks.get(f"p{i}")
            if hit is None:
                continue
            block, secs = hit
            secs = share if secs is None else secs
            if f"Import proof-constraint: \\{sig} = 1'1" not in block:
                results[i] = ProofResult(f"{top}.{sig}", ERROR, "yosys-sat", secs, {},
                                         f"{sig} is not a 1-bit signal of {top}", log_path)
                continue
            status, cex, detail = _parse_sat_block(block)
            results[i] = ProofResult(f"{top}.{sig}", status, "yosys-sat", secs, cex, detail, log_path)
        left = [(i, sig) for i, sig in pending if i not in results]
        if not left:
            break
        if run.returncode == -9:
            # The process was stopped. The proof in progress is a timeout only if it had its full time; if the
            # batch as a whole used up the budget, it simply goes round again. The ones behind it never started.
            decided_now = len(pending) - len(left)
            for i, sig in left:
                begun = _begin_stamp(run.log, f"p{i}")
                if begun is None:
                    continue
                if dt - begun >= timeout or decided_now == 0:
                    results[i] = ProofResult(f"{top}.{sig}", TIMEOUT, "yosys-sat", float(timeout), {},
                                             f"no verdict within {int(timeout)} s", log_path)
            if decided_now == 0 and not any(i in results for i, _ in left):
                i, sig = left[0]                      # nothing even started: elaboration itself is too slow
                results[i] = ProofResult(f"{top}.{sig}", TIMEOUT, "yosys-sat", dt, {},
                                         f"yosys did not start this proof within {int(timeout + GRACE)} s", log_path)
            pending = [(i, sig) for i, sig in left if i not in results]
            continue
        why = _failure_detail(_STAMP.sub("", run.log), "yosys did not reach this proof")
        for i, sig in left:
            results[i] = ProofResult(f"{top}.{sig}", ERROR, "yosys-sat", share, {}, why, log_path)
        break
    return [results[i] for i in range(len(signals))]


# ------------------------------------------------------------------------------------------------ (c) z3

def _z3():
    try:
        import z3
    except ImportError as e:      # pragma: no cover
        raise ProofError("z3-solver is not installed in this environment") from e
    return z3


class Z3Circuit:
    """One beat of a flat TAP-20 netlist as z3 terms, built straight from the bytes.

    s, x:   lists of z3 Bool constants (free): state before the beat and inputs, bit 0 first.
    ns, y:  lists of z3 Bool terms: state after the beat and outputs.
    """

    def __init__(self, tap, n_in: Optional[int] = None, n_out: Optional[int] = None, prefix: str = "",
                 s=None, x=None, manifest: Optional[dict] = None):
        z3 = _z3()
        nl = _as_netlist(tap, n_in, n_out)
        if not nl.is_flat:
            raise ProofError("the z3 path handles flat netlists only")
        self.netlist = nl
        self.manifest = manifest or {}
        self.s = list(s) if s is not None else [z3.Bool(f"{prefix}s{i}") for i in range(nl.n_state)]
        self.x = list(x) if x is not None else [z3.Bool(f"{prefix}x{i}") for i in range(nl.n_in)]
        if len(self.s) != nl.n_state or len(self.x) != nl.n_in:
            raise ProofError("s / x have the wrong length")
        sig = [z3.BoolVal(False), z3.BoolVal(True)] + self.x
        k = 0
        d_of = []
        Not, And = z3.Not, z3.And
        for e in nl.elements:
            if e.op == NAND:
                a, b = e.ins
                sig.append(Not(sig[a]) if a == b else Not(And(sig[a], sig[b])))
            elif e.op == LATCH:
                sig.append(self.s[k])
                d_of.append(e.ins[0])
                k += 1
        self.signals = sig
        self.ns = [sig[d] for d in d_of]
        self.y = sig[len(sig) - nl.n_out:]

    # -- conveniences for writing predicates
    @staticmethod
    def bv(bits):
        """Unsigned bit-vector from a list of Bool terms, bit 0 first."""
        z3 = _z3()
        bits = list(bits)
        if not bits:
            raise ProofError("empty bit list")
        one, zero = z3.BitVecVal(1, 1), z3.BitVecVal(0, 1)
        parts = [z3.If(b, one, zero) for b in reversed(bits)]
        return parts[0] if len(parts) == 1 else z3.Concat(*parts)

    def field(self, kind: str, name: str):
        """Bit-vector of a named field from the manifest. kind: 'x' (inputs), 'y' (outputs), 's' (state before)
        or 'ns' (state after)."""
        key = {"x": "inputs", "y": "outputs", "s": "state", "ns": "state"}[kind]
        for f in (self.manifest.get("fields") or {}).get(key, []):
            if f["name"] == name:
                lsb, w = int(f["lsb"]), int(f.get("width", 1))
                return self.bv(getattr(self, kind)[lsb:lsb + w])
        raise ProofError(f"no {key} field named {name!r} in the manifest")


def _z3_check(name: str, assertions, model_bits: dict, timeout: int) -> ProofResult:
    """Valid iff `assertions` (the negated claim) are unsatisfiable."""
    z3 = _z3()
    solver = z3.Solver()
    solver.set("timeout", int(timeout) * 1000)
    for a in assertions:
        solver.add(a)
    t0 = time.perf_counter()
    r = solver.check()
    dt = time.perf_counter() - t0
    if r == z3.unsat:
        return ProofResult(name, PROVED, "z3", dt)
    if r == z3.sat:
        m = solver.model()
        cex = {}
        for key, bits in model_bits.items():
            v = 0
            for i, b in enumerate(bits):
                if z3.is_true(m.eval(b, model_completion=True)):
                    v |= 1 << i
            cex[key] = v
        return ProofResult(name, FAILED, "z3", dt, cex)
    return ProofResult(name, TIMEOUT, "z3", dt, {}, f"z3 returned unknown: {solver.reason_unknown()}")


def check_z3(tap, predicates, n_in: Optional[int] = None, n_out: Optional[int] = None,
             manifest: Optional[dict] = None, timeout: int = 1800) -> list:
    """Prove Python predicates over the netlist for every (s, x).

    predicates: {name: f} or [(name, f)], where f(c: Z3Circuit) returns a z3 Bool term that must be valid.
    """
    z3 = _z3()
    items = list(predicates.items()) if isinstance(predicates, dict) else list(predicates)
    c = Z3Circuit(tap, n_in, n_out, manifest=manifest)
    out = []
    for name, f in items:
        try:
            claim = f(c)
            if not z3.is_bool(claim):
                raise ProofError("the predicate must return a z3 Bool term")
            out.append(_z3_check(name, [z3.Not(claim)], {"s": c.s, "x": c.x}, timeout))
        except ProofError as e:
            out.append(ProofResult(name, ERROR, "z3", 0.0, {}, str(e)))
    return out


def equiv_netlists_z3(tap_a, tap_b, n_in: int, n_out: int, timeout: int = 1800, name: str = "netlist A == netlist B") -> ProofResult:
    """Two flat netlists with the same nIn, nOut and nState compute the same beat."""
    z3 = _z3()
    a = Z3Circuit(tap_a, n_in, n_out)
    b = Z3Circuit(tap_b, n_in, n_out, s=a.s, x=a.x)
    if a.netlist.n_state != b.netlist.n_state:
        return ProofResult(name, FAILED, "z3", 0.0, {}, "different nState")
    diff = [z3.Xor(p, q) for p, q in zip(a.ns + a.y, b.ns + b.y)]
    return _z3_check(name, [z3.Or(*diff)] if diff else [z3.BoolVal(False)], {"s": a.s, "x": a.x}, timeout)


def netlist_smt2(nl: Netlist, s_bit: Callable[[int], str], x_bit: Callable[[int], str], prefix: str = "tapc") -> tuple:
    """SMT-LIB text defining one Bool per NAND of a flat netlist. s_bit(i) / x_bit(i) give the SMT term of
    state bit i / input bit i. Returns (text, ns_terms, y_terms)."""
    if not nl.is_flat:
        raise ProofError("the z3 path handles flat netlists only")
    names = ["false", "true"] + [x_bit(i) for i in range(nl.n_in)]
    lines = []
    k = 0
    d_of = []
    for e in nl.elements:
        if e.op == NAND:
            nm = f"{prefix}_n{e.first_out}"
            a, b = names[e.ins[0]], names[e.ins[1]]
            lines.append(f"(define-fun {nm} () Bool (not (and {a} {b})))")
            names.append(nm)
        else:
            names.append(s_bit(k))
            d_of.append(e.ins[0])
            k += 1
    return "\n".join(lines) + "\n", [names[d] for d in d_of], names[len(names) - nl.n_out:]


def _smt2_ports(text: str) -> dict:
    """{port: width} from the `; yosys-smt2-input/output` comments."""
    return {m.group(2): int(m.group(3)) for m in re.finditer(r"; yosys-smt2-(input|output) (\S+) (\d+)", text)}


def _smt2_not_combinational(text: str) -> str:
    """Why this SMT-LIB model is not a pure function of its inputs ('' when it is). A register, a memory or an
    $anyconst would be a free variable in the query and could only produce spurious counterexamples."""
    for marker, what in (("yosys-smt2-register", "a register"), ("yosys-smt2-memory", "a memory"),
                         ("(Array ", "a memory"), ("yosys-smt2-anyconst", "$anyconst"),
                         ("yosys-smt2-anyseq", "$anyseq"), ("yosys-smt2-allconst", "$allconst")):
        if marker in text:
            return f"the design is not combinational after elaboration: it contains {what}"
    return ""


def _bit_term(mod: str, port: str, width: int, i: int) -> str:
    f = f"(|{mod}_n {port}| tapc_st)"
    return f if width == 1 else f"(= ((_ extract {i} {i}) {f}) #b1)"


def _model_int(z3, model, name: str) -> Optional[int]:
    for d in model.decls():
        if d.name() == name:
            v = model[d]
            if z3.is_bv_value(v):
                return v.as_long()
            if z3.is_true(v):
                return 1
            if z3.is_false(v):
                return 0
    return None


def _solve_smt2(name: str, text: str, timeout: int, widths: dict) -> ProofResult:
    z3 = _z3()
    solver = z3.Solver()
    solver.set("timeout", int(timeout) * 1000)
    t0 = time.perf_counter()
    try:
        solver.from_string(text)
        r = solver.check()
    except z3.Z3Exception as e:
        return ProofResult(name, ERROR, "z3", time.perf_counter() - t0, {}, f"z3: {e}")
    dt = time.perf_counter() - t0
    if r == z3.unsat:
        return ProofResult(name, PROVED, "z3", dt)
    if r == z3.sat:
        m = solver.model()
        cex = {}
        for port in widths:
            v = _model_int(z3, m, f"tapc_cex_{port}")
            if v is not None:
                cex[port] = v
        return ProofResult(name, FAILED, "z3", dt, cex)
    return ProofResult(name, TIMEOUT, "z3", dt, {}, f"z3 returned unknown: {solver.reason_unknown()}")


def _cex_consts(mod: str, ports: dict, names: Sequence[str]) -> str:
    """Named constants tied to the free inputs so a counterexample can be read back from the model."""
    out = []
    for p in names:
        w = ports[p]
        sort = "Bool" if w == 1 else f"(_ BitVec {w})"
        out.append(f"(declare-const tapc_cex_{p} {sort})")
        out.append(f"(assert (= tapc_cex_{p} (|{mod}_n {p}| tapc_st)))")
    return "\n".join(out) + "\n"


def equiv_z3(sources: Sequence[str], top: str, tap, n_in: Optional[int] = None, n_out: Optional[int] = None,
             work: str = "build/prove", timeout: int = 1800, name: Optional[str] = None) -> ProofResult:
    """Prove RTL core `top` == TAP-20 netlist for every (s, x) with z3.

    RTL side: Yosys `write_smt2` after proc + flatten, i.e. word-level SMT-LIB (bvadd, ite, ...), never
    technology-mapped. Netlist side: one Bool definition per NAND, generated from the bytes.
    """
    nl = _as_netlist(tap, n_in, n_out)
    name = name or f"{top} == netlist"
    work = os.path.abspath(work)
    local = _prepare(work, sources)
    script = "\n".join(_elaborate(local, top) + ["write_smt2 rtl.smt2"]) + "\n"
    t0 = time.perf_counter()
    run = yosys.run_script(script, work, tag="smt2", timeout=timeout, check=False)
    smt_path = os.path.join(work, "rtl.smt2")
    if run.returncode != 0 or not os.path.exists(smt_path):
        return ProofResult(name, ERROR, "z3", time.perf_counter() - t0, {},
                           _failure_detail(run.log, "yosys write_smt2 failed"))
    with open(smt_path, "r", encoding="utf-8") as f:
        rtl = f.read()
    why = _smt2_not_combinational(rtl)
    if why:
        return ProofResult(name, ERROR, "z3", time.perf_counter() - t0, {}, why)
    ports = _smt2_ports(rtl)
    want = {"y": nl.n_out}
    if nl.n_in:
        want["x"] = nl.n_in
    if nl.n_state:
        want["s"] = nl.n_state
        want["ns"] = nl.n_state
    if ports != want:
        return ProofResult(name, ERROR, "z3", time.perf_counter() - t0, {},
                           f"RTL ports {ports} do not match the netlist {want}")
    gates, ns_terms, y_terms = netlist_smt2(nl, lambda i: _bit_term(top, "s", nl.n_state, i),
                                            lambda i: _bit_term(top, "x", nl.n_in, i))
    diffs = [f"(xor {t} {_bit_term(top, 'ns', nl.n_state, i)})" for i, t in enumerate(ns_terms)]
    diffs += [f"(xor {t} {_bit_term(top, 'y', nl.n_out, j)})" for j, t in enumerate(y_terms)]
    free = [p for p in ("s", "x") if p in ports]
    text = (rtl + f"(declare-const tapc_st |{top}_s|)\n" + gates + _cex_consts(top, ports, free)
            + f"(assert (or {' '.join(diffs)}))\n")
    with open(os.path.join(work, "equiv_z3.smt2"), "w", encoding="utf-8") as f:
        f.write(text + "(check-sat)\n")
    res = _solve_smt2(name, text, timeout, {p: ports[p] for p in free})
    res.seconds = time.perf_counter() - t0
    res.log = os.path.join(work, "equiv_z3.smt2")
    return res


def _properties_z3(head: list, top: str, signals: Sequence[str], work: str, timeout: int) -> list:
    t0 = time.perf_counter()
    run = yosys.run_script("\n".join(head + ["write_smt2 wrapper.smt2"]) + "\n", work, tag=f"smt2_{top}",
                           timeout=timeout, check=False)
    path = os.path.join(work, "wrapper.smt2")
    if run.returncode != 0 or not os.path.exists(path):
        why = _failure_detail(run.log, "yosys write_smt2 failed")
        return [ProofResult(f"{top}.{s}", ERROR, "z3", time.perf_counter() - t0, {}, why) for s in signals]
    with open(path, "r", encoding="utf-8") as f:
        smt = f.read()
    why = _smt2_not_combinational(smt)
    if why:
        return [ProofResult(f"{top}.{s}", ERROR, "z3", time.perf_counter() - t0, {}, why) for s in signals]
    ports = _smt2_ports(smt)
    inputs = [m.group(1) for m in re.finditer(r"; yosys-smt2-input (\S+) \d+", smt)]
    out = []
    for sig in signals:
        if ports.get(sig) != 1 or sig in inputs:
            out.append(ProofResult(f"{top}.{sig}", ERROR, "z3", 0.0, {}, f"{sig} is not a 1-bit output of {top}"))
            continue
        text = (smt + f"(declare-const tapc_st |{top}_s|)\n" + _cex_consts(top, ports, inputs)
                + f"(assert (not (|{top}_n {sig}| tapc_st)))\n")
        t1 = time.perf_counter()
        res = _solve_smt2(f"{top}.{sig}", text, timeout, {p: ports[p] for p in inputs})
        res.seconds = time.perf_counter() - t1
        out.append(res)
    return out


# ------------------------------------------------------------------------------------------------ everything at once

def wrapper_outputs(sources: Sequence[str], top: str, work: str = "build/prove", tap=None, n_in=None, n_out=None,
                    tap_module: Optional[str] = None) -> list:
    """Names of the 1-bit outputs of wrapper module `top`, in port order."""
    import json
    work = os.path.abspath(work)
    local = _prepare(work, sources)
    if tap is not None:
        with open(os.path.join(work, "gate.v"), "w", encoding="utf-8") as f:
            f.write(to_verilog(_as_netlist(tap, n_in, n_out), module=tap_module or "chip_tap"))
        local.append("gate.v")
    script = "\n".join([f"read_verilog -sv {' '.join(local)}", f"hierarchy -check -top {top}", "proc",
                        "write_json ports.json"]) + "\n"
    run = yosys.run_script(script, work, tag=f"ports_{top}", check=False)
    path = os.path.join(work, "ports.json")
    if run.returncode != 0 or not os.path.exists(path):
        tail = " | ".join(run.log.strip().splitlines()[-4:])
        raise ProofError(f"could not read the ports of {top}: {tail}")
    with open(path, "r", encoding="utf-8") as f:
        ports = json.load(f)["modules"][top]["ports"]
    return [n for n, p in ports.items() if p["direction"] == "output" and len(p["bits"]) == 1]


def prove_all(rtl: Sequence[str], top: str, tap, n_in: Optional[int] = None, n_out: Optional[int] = None,
              props_v: Optional[Sequence[str]] = None, props_top: Optional[str] = None,
              signals: Optional[Sequence[str]] = None, tap_module: Optional[str] = None,
              props_py: Optional[str] = None, manifest: Optional[dict] = None, work: str = "build/prove",
              timeout: int = 1800, engines: Sequence[str] = ("yosys", "z3")) -> list:
    """Everything for one chip: RTL == bytes (both engines), Verilog wrapper properties (both engines) and
    Python predicates (z3). Returns the list of ProofResult."""
    nl = _as_netlist(tap, n_in, n_out)
    out = []
    if "yosys" in engines:
        out.append(equiv_yosys(rtl, top, nl, work=os.path.join(work, "equiv_yosys"), timeout=timeout))
    if "z3" in engines:
        out.append(equiv_z3(rtl, top, nl, work=os.path.join(work, "equiv_z3"), timeout=timeout))
    if props_v:
        if not props_top:
            raise ProofError("props_top is required with props_v")
        sigs = list(signals) if signals else wrapper_outputs(props_v, props_top, os.path.join(work, "ports"), nl,
                                                             tap_module=tap_module)
        if not sigs:
            raise ProofError(f"{props_top} has no 1-bit output to prove")
        for eng in engines:
            out += prove_properties(props_v, props_top, sigs, tap=nl, tap_module=tap_module,
                                    work=os.path.join(work, f"prop_{eng}"), timeout=timeout, engine=eng)
    if props_py:
        out += check_z3(nl, load_predicates(props_py), manifest=manifest, timeout=timeout)
    return out


def report(nl: Netlist, results: Sequence[ProofResult], name: str = "", timings: bool = False) -> dict:
    """A proof report. Without `timings` it is a pure function of the netlist and the verdicts, so it can be
    committed next to the netlist."""
    from . import __version__
    from .netlist import keccak256
    try:
        z3v = _z3().get_version_string()
    except ProofError:
        z3v = None
    rows = []
    for r in results:
        row = {"name": r.name, "engine": r.engine, "status": r.status, "space": "every state and every input"}
        if timings:
            row["seconds"] = round(r.seconds, 3)
        if r.counterexample:
            row["counterexample"] = {k: hex(v) for k, v in sorted(r.counterexample.items())}
        if r.detail and not r.ok:
            row["detail"] = r.detail
        rows.append(row)
    return {
        "format": "tapc-proofs/1", "name": name,
        "keccak256": "0x" + keccak256(nl.data).hex(), "bytes": len(nl.data),
        "nIn": nl.n_in, "nOut": nl.n_out, "nState": nl.n_state, "nNand": nl.n_nand, "nLatch": nl.n_latch,
        "ok": bool(results) and all(r.ok for r in results),
        "tool": {"tapc": __version__, "yosys": yosys.short_version(), "z3": z3v},
        "proofs": rows,
    }


# ------------------------------------------------------------------------------------------------ replay

def counterexample_vectors(res: ProofResult, nl: Netlist) -> Optional[tuple]:
    """(state_bytes, input_bytes) of a counterexample, packed as `tapc sim` takes them."""
    if not res.counterexample:
        return None
    return (int_to_bytes(res.counterexample.get("s", 0), nl.n_state),
            int_to_bytes(res.counterexample.get("x", 0), nl.n_in))


def load_predicates(path: str) -> list:
    """Load `prop_*` functions from a Python file. Each takes a Z3Circuit and returns a z3 Bool term."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("tapc_props_" + re.sub(r"\W", "_", os.path.basename(path)), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    items = [(n[5:], getattr(mod, n)) for n in sorted(vars(mod)) if n.startswith("prop_") and callable(getattr(mod, n))]
    if not items:
        raise ProofError(f"{path} defines no prop_* function")
    return items
