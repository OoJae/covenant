"""Covenant chip kit: design, build, prove, price, plan and rehearse your own vault chip, without the team.

    chips/kit/kit.sh new <name>                    a new chip directory from the Starter template
    chips/kit/kit.sh build <chip>                  synthesise to TAP-20, prove, write the pin manifest and its SHA-256
    chips/kit/kit.sh quote <chip>                  Fab.quote on X Layer (eth_call): transistors and OKB at today's prices
    chips/kit/kit.sh envelope <chip> --launcher A  write the envelope, check it against the factory's limits, and
                                                   find out for every state and input which clamps the chip can trigger
    chips/kit/kit.sh plan <chip> --launcher A      the exact cast commands the launcher signs, as a runnable script
    chips/kit/kit.sh fork <chip>                   all of it on a LOCAL anvil fork, from an impersonated outsider

<chip> is a chip directory holding chip.json, or the path of a kit config file (for example
chips/cells/glutton/glutton.kit.json). See docs/BUILD_YOUR_CHIP.md.

Read-only on the real chain: `quote` and `envelope` make eth_call requests and nothing else. Only `fork` sends
transactions, and only to an anvil node it started itself on 127.0.0.1. No command reads or asks for a key.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from decimal import Decimal
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
ROOT = os.path.dirname(CHIPS)
TAPS = os.path.join(ROOT, "docs", "taps", "assets")
for p in (os.path.join(CHIPS, "tools"), os.path.join(CHIPS, "golden"), TAPS):
    if p not in sys.path:
        sys.path.insert(0, p)

from tapc import chain  # noqa: E402
from tapc import netlist as N  # noqa: E402
import kernel_model as km  # noqa: E402
import pins_reference as PR  # noqa: E402

DEPLOYMENT = os.path.join(ROOT, "deployments", "xlayer.json")
PROFILE = os.path.join(TAPS, "covenant-v1.pins.json")
SCHEMA = os.path.join(TAPS, "pin-manifest.schema.json")
STARTER = os.path.join(CHIPS, "cells", "starter")
N_IN, N_OUT = km.IN_BITS, km.OUT_BITS
CONFIG_FORMAT = "covenant-kit/1"
NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,30}$")
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
ZERO = "0x" + "00" * 20
FIELD_KEYS = ("name", "offset", "width", "encoding", "mantissaBits", "min", "max", "scale", "values", "bits", "unit",
              "description")

# KernelFactory constants (contracts/core/src/KernelFactory.sol; chips/INTERFACE.md sections 2 and 7)
STEP_BASE, STEP_PER_GATE, STEP_PER_LATCH = 200_000, 2_600, 800
SEALED_BASE, SEALED_PER_NAND, SEALED_PER_LATCH = 40_000, 200, 400
MAX_FALLBACK_DELAY = MAX_HALF_LIFE = 30 * 86400
HALVING_SETTLES = 178
TANK_ALLOWANCE_BPS = 8500

ENV_FIELDS = (("launcher", "address"), ("epochLen", "uint32"), ("allowancePayee", "address"), ("capT", "uint16"),
              ("capV", "uint16"), ("allowCumBps", "uint16"), ("ceilMax", "uint16"), ("relMax", "uint16"),
              ("floorRel", "uint16"), ("floorMin", "uint16"), ("fallbackEpochs", "uint16"), ("fbAllow", "uint16"),
              ("buyEnabled", "bool"), ("sink", "address"))
ENV_TUPLE = "(" + ",".join(t for _, t in ENV_FIELDS) + ")"
REFERENCE_ENVELOPE = {"epochLen": 900, "capT": 48, "capV": 0, "allowCumBps": 1875, "ceilMax": 440, "relMax": 128,
                      "floorRel": 2, "floorMin": 1, "fallbackEpochs": 16, "fbAllow": 8, "buyEnabled": True,
                      "sink": ZERO}
CLAMP_NAMES = ((km.K1T, "K1T"), (km.K1V, "K1V"), (km.K2, "K2"), (km.K2C, "K2C"), (km.K2L, "K2L"), (km.K3, "K3"),
               (km.K5, "K5"), (km.K2V, "K2V"))


class KitError(RuntimeError):
    pass


def say(msg: str = "") -> None:
    print(msg, flush=True)


# ================================================================================================ small helpers

def sha256_file(path: str) -> str:
    with open(path, "rb") as f:
        return "0x" + hashlib.sha256(f.read()).hexdigest()


def okb(wei: int) -> str:
    if 0 < wei < 10 ** 12:
        return f"{wei:,} wei"
    return f"{Decimal(wei) / Decimal(10 ** 18):.6f}".rstrip("0").rstrip(".") + " OKB"


def keccak_hex(data: bytes) -> str:
    return "0x" + N.keccak256(data).hex()


def check_address(v: str, what: str) -> str:
    if not isinstance(v, str) or not ADDR_RE.match(v):
        raise KitError(f"{what} must be an address (0x and 40 hex digits), not {v!r}")
    return v


def check_salt(v: str) -> str:
    if not isinstance(v, str) or not re.match(r"^0x[0-9a-fA-F]{64}$", v):
        raise KitError(f"--salt must be 0x and 64 hex digits, not {v!r}")
    return v


def outsider_address() -> str:
    """A fresh address nobody holds a key for that we know of, used as the outsider on a fork."""
    return "0x" + N.keccak256(b"covenant kit outsider").hex()[-40:]


def rel(path: str) -> str:
    """A path for messages: relative to the repository when inside it, absolute otherwise."""
    path = os.path.abspath(path)
    return os.path.relpath(path, ROOT) if path.startswith(ROOT + os.sep) else path


def dump_json(path: str, doc) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(doc, indent=1) + "\n")


def load_deployment() -> dict:
    with open(DEPLOYMENT, "r", encoding="utf-8") as f:
        d = json.load(f)
    try:
        a = {
            "circuits": d["issuance"]["circuits"], "transistors": d["issuance"]["transistors"],
            "splitter": d["issuance"]["splitter"], "keeperTank": d["issuance"]["keeperTank"],
            "teamRegistry": d["issuance"]["teamRegistry"], "sealedVM": d["evaluator"]["sealedVM"],
            "fab": d["evaluator"]["fab"], "kernelFactory": d["core"]["kernelFactory"],
            "kernelImpl": d["core"]["kernelImpl"], "lens": d["core"]["lens"],
            "flagshipChipId": int(d["flagship"]["chipId"]),
        }
    except (KeyError, TypeError) as e:
        raise KitError(f"{DEPLOYMENT} does not record the Fab, the factory and the Lens yet ({e})")
    if d.get("chainId") != 196:
        raise KitError(f"{DEPLOYMENT} is not an X Layer deployment")
    return a


# ---- ABI (only static types, plus one `bytes`)

def w(v: int) -> bytes:
    return int(v).to_bytes(32, "big")


def waddr(a: str) -> bytes:
    return bytes(12) + bytes.fromhex(a[2:])


def call_data(sig: str, *words: bytes) -> bytes:
    return chain.selector(sig) + b"".join(words)


def enc_bytes_arg(data: bytes) -> bytes:
    return w(len(data)) + data + bytes(-len(data) % 32)


def enc_envelope(env: dict) -> bytes:
    out = b""
    for k, t in ENV_FIELDS:
        v = env[k]
        out += waddr(v) if t == "address" else w(1 if v is True else 0 if v is False else int(v))
    return out


def dec_words(data: bytes, n: int) -> list:
    if len(data) < 32 * n:
        raise KitError(f"short return data ({len(data)} bytes, {n} words expected)")
    return [int.from_bytes(data[32 * i:32 * i + 32], "big") for i in range(n)]


def dec_envelope(data: bytes) -> dict:
    ws = dec_words(data, len(ENV_FIELDS))
    env = {}
    for (k, t), v in zip(ENV_FIELDS, ws):
        env[k] = ("0x" + v.to_bytes(32, "big")[12:].hex()) if t == "address" else bool(v) if t == "bool" else v
    return env


def env_tuple_text(env: dict) -> str:
    parts = []
    for k, t in ENV_FIELDS:
        v = env[k]
        parts.append(("true" if v else "false") if t == "bool" else str(v))
    return "(" + ",".join(parts) + ")"


ERRORS = {chain.selector(s): s for s in (
    "BadEnvelope(uint8)", "BadChip(uint8)", "NotKernel()", "WrongValue(uint256,uint256)", "NotAChip(uint256)",
    "TapeoutMismatch()", "ChipExists(uint256)", "LeftOver()", "UnexpectedTokens()")}


def decode_revert(e: Exception) -> str:
    data = getattr(e, "data", None)
    if isinstance(data, dict):
        data = data.get("data")
    if isinstance(data, str) and data.startswith("0x") and len(data) >= 10:
        raw = bytes.fromhex(data[2:])
        sig = ERRORS.get(raw[:4])
        if sig:
            n = sig.count(",") + 1 if "()" not in sig else 0
            args = dec_words(raw[4:], n) if n else []
            return f"{sig.split('(')[0]}({', '.join(str(a) for a in args)})"
        return chain.revert_reason(raw)
    return str(e)


def rpc_for(urls) -> chain.Rpc:
    rpc = chain.Rpc(urls or list(chain.XLAYER_RPCS), retries=3, timeout=60)
    cid = rpc.chain_id()
    if cid != 196:
        raise KitError(f"{rpc.host} is chain {cid}, not X Layer (196)")
    return rpc


def uint_call(rpc: chain.Rpc, to: str, sig: str, *words: bytes) -> int:
    return dec_words(rpc.eth_call(to, call_data(sig, *words)), 1)[0]


# ================================================================================================ chip config

class Chip:
    def __init__(self, target: str, out: str | None = None):
        path = os.path.abspath(target)
        if os.path.isdir(path):
            path = os.path.join(path, "chip.json")
        if not os.path.isfile(path):
            raise KitError(f"no chip config at {path} (a chip directory holds chip.json; `kit.sh new <name>` makes one)")
        with open(path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        if cfg.get("kit") != CONFIG_FORMAT:
            raise KitError(f"{path}: \"kit\" must be {CONFIG_FORMAT!r}")
        self.config_path = path
        self.base = os.path.dirname(path)
        self.cfg = cfg
        self.name = cfg.get("name", "")
        if not NAME_RE.match(self.name):
            raise KitError(f"{path}: name must match {NAME_RE.pattern}")
        self.top = cfg.get("top") or f"{self.name}_core"
        self.sources = [os.path.join(self.base, s) for s in cfg.get("sources", [f"{self.name}_core.v"])]
        props = cfg.get("props") or {}
        self.props_sources = [os.path.join(self.base, s) for s in props.get("sources", [])]
        self.props_top = props.get("top")
        self.tap_module = props.get("tapModule") or f"{self.name}_tap"
        self.signals = props.get("signals")
        self.state = cfg.get("state") or []
        self.out = os.path.abspath(out) if out else os.path.join(self.base, "out")
        self.build_dir = os.path.join(self.base, "build", self.name)
        for s in self.sources + self.props_sources:
            if not os.path.isfile(s):
                raise KitError(f"{path}: source file {s} does not exist")
        if sum(int(f["width"]) for f in self.state) < 1:
            raise KitError(f"{path}: \"state\" must name the chip's latches (at least one: chips/INTERFACE.md section 2)")

    def path(self, ext: str) -> str:
        return os.path.join(self.out, f"{self.name}.{ext}")

    def tapc_pins(self) -> dict:
        """The tapc-pins/1 layout `tapc synth` names the map with: the interface words, and the chip's state."""
        return {"inputs": [{"name": n, "lsb": o, "width": wd} for n, o, wd in km.INPUT_FIELDS],
                "outputs": [{"name": n, "lsb": o, "width": wd} for n, o, wd in km.OUTPUT_FIELDS],
                "state": [{"name": f["name"], "lsb": int(f["offset"]), "width": int(f["width"])} for f in self.state]}

    def built(self) -> dict:
        p = self.path("build.json")
        if not os.path.isfile(p):
            raise KitError(f"{self.name} is not built yet ({p} is missing): run `kit.sh build` first")
        with open(p, "r", encoding="utf-8") as f:
            b = json.load(f)
        data = N.read_netlist_file(self.path("tap"))
        if keccak_hex(data) != b["netlist"]["keccak256"]:
            raise KitError(f"{self.path('tap')} changed since the build: run `kit.sh build` again")
        if sha256_file(self.path("tape-pins.json")) != b["manifest"]["sha256"]:
            raise KitError(f"{self.path('tape-pins.json')} changed since the build: run `kit.sh build` again")
        b["_data"] = data
        return b

    def envelope(self, launcher: str, payee: str | None, overrides: list | None = None) -> dict:
        env = dict(REFERENCE_ENVELOPE)
        env.update(self.cfg.get("envelope") or {})
        env["launcher"] = check_address(launcher, "--launcher")
        env["allowancePayee"] = check_address(payee or launcher, "--payee")
        env.setdefault("sink", ZERO)
        for item in overrides or []:
            k, _, v = item.partition("=")
            if k not in dict(ENV_FIELDS) or k in ("launcher", "allowancePayee"):
                raise KitError(f"--set {item}: unknown envelope field (use --launcher / --payee for the addresses)")
            t = dict(ENV_FIELDS)[k]
            if t == "address":
                env[k] = check_address(v, k)
            elif t == "bool":
                if v.lower() not in ("true", "false"):
                    raise KitError(f"--set {item}: {k} is true or false")
                env[k] = v.lower() == "true"
            else:
                try:
                    env[k] = int(v, 0)
                except ValueError:
                    raise KitError(f"--set {item}: {k} must be a whole number")
        unknown = set(env) - set(dict(ENV_FIELDS))
        check_address(env["sink"], "sink")
        if unknown:
            raise KitError(f"unknown envelope field(s) {sorted(unknown)}")
        # The ABI types, so that an envelope that passes the factory's rules here also encodes for `cast`: a
        # negative or fractional value would otherwise pass a `<=` rule and fail only when the plan script runs.
        for k, t in ENV_FIELDS:
            v = env[k]
            if t == "bool":
                if not isinstance(v, bool):
                    raise KitError(f"envelope field {k} must be true or false, not {v!r}")
            elif t.startswith("uint"):
                bits = int(t[4:])
                if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v < 1 << bits:
                    raise KitError(f"envelope field {k} must be a whole number from 0 to {(1 << bits) - 1} ({t}), "
                                   f"not {v!r}")
        return {k: env[k] for k, _ in ENV_FIELDS}


# ================================================================================================ new

def cmd_new(a) -> int:
    name = a.name
    if not NAME_RE.match(name) or name == "starter":
        raise KitError(f"name must match {NAME_RE.pattern} and not be 'starter'")
    dest = os.path.abspath(a.dir or os.path.join(CHIPS, "cells", name))
    if os.path.exists(dest):
        raise KitError(f"{dest} exists already; pick another name or --dir")
    title = name.replace("_", " ").title().replace(" ", "")
    os.makedirs(dest)
    made = []
    for src, dst in (("starter_core.v", f"{name}_core.v"), ("starter_props.v", f"{name}_props.v"),
                     ("chip.json", "chip.json")):
        with open(os.path.join(STARTER, src), "r", encoding="utf-8") as f:
            text = f.read()
        text = re.sub(r"\bstarter_", f"{name}_", text).replace("Starter", title)
        text = text.replace('"name": "starter"', f'"name": "{name}"')
        with open(os.path.join(dest, dst), "w", encoding="utf-8") as f:
            f.write(text)
        made.append(os.path.join(dest, dst))
    say(f"new chip '{name}' from the Starter template in {dest}:")
    for m in made:
        say(f"  {rel(m)}")
    say("Edit the core (keep the port list: s/ns are your latches, x is the 96-bit input word, y the 112-bit output")
    say("word of chips/INTERFACE.md sections 5 and 6), list your latches under \"state\" in chip.json, state what")
    say("you promise in the properties file, then:")
    say(f"  chips/kit/kit.sh build {os.path.relpath(dest, os.getcwd())}")
    return 0


# ================================================================================================ build

def pin_manifest(chip: Chip, netlist: bytes, n_state: int) -> bytes:
    """The circuit pin manifest (docs/taps, draft "Circuit Pin Manifest") of this chip: the covenant-v1 profile's
    inputs and outputs, the chip's meaning of the telemetry outputs, and its state fields. Its SHA-256 is the
    manifestHash given to the Fab at tape-out."""
    with open(PROFILE, "rb") as f:
        profile_bytes = f.read()
    profile = PR.parse(profile_bytes)
    overrides = chip.cfg.get("outputs") or {}
    unknown = set(overrides) - {f["name"] for f in profile["outputs"]}
    if unknown:
        raise KitError(f"chip.json outputs: {sorted(unknown)} are not output fields of {profile['name']}")

    def order(f: dict) -> dict:
        return {k: f[k] for k in FIELD_KEYS if k in f}

    outputs = []
    for pf in profile["outputs"]:
        ov = overrides.get(pf["name"])
        if ov is None:
            outputs.append(order(dict(pf)))
        elif pf["encoding"] == "bits":          # an uninterpreted telemetry field: the chip gives it a meaning
            outputs.append(order({"name": pf["name"], "offset": pf["offset"], "width": pf["width"], **ov}))
        else:                                   # a routed field keeps the profile's encoding; text may be added
            if set(ov) - {"description"}:
                raise KitError(f"chip.json outputs.{pf['name']}: only a description can be added to a routed field")
            outputs.append(order({**pf, "description": pf["description"] + " " + ov["description"]}))
    state = [order(dict(f)) for f in chip.state]
    if sum(int(f["width"]) for f in state) != n_state:
        raise KitError(f"chip.json state names {sum(int(f['width']) for f in state)} bits, the netlist has {n_state} latches")
    doc = {
        "tapepins": "0.1",
        "name": chip.name,
        "description": chip.cfg.get("description", ""),
        "circuit": {"netlistHash": PR.netlist_hash(netlist)},
        "profile": {"name": profile["name"], "sha256": PR.sha256(profile_bytes)},
        "nIn": profile["nIn"], "nOut": profile["nOut"], "nState": n_state,
        "inputs": [order(dict(f)) for f in profile["inputs"]],
        "outputs": outputs,
        "state": state,
    }
    data = (json.dumps(doc, indent=2, ensure_ascii=True) + "\n").encode("ascii")
    parsed = PR.parse(data)
    problems = (PR.validate(parsed) + PR.check_binding(parsed, netlist, N_IN, N_OUT, n_state, chain_id=196)
                + PR.conforms(parsed, profile, profile_bytes) + PR.check_shape(profile, netlist))
    if problems:
        raise KitError("the pin manifest is not valid: " + "; ".join(problems))
    try:
        import jsonschema
    except ImportError:
        pass
    else:
        with open(SCHEMA, "r", encoding="utf-8") as f:
            jsonschema.Draft202012Validator(json.load(f)).validate(json.loads(data))
    return data


def gas_budget(n_nand: int, n_latch: int) -> dict:
    gates = n_nand + n_latch
    return {"stepFloor": STEP_BASE + STEP_PER_GATE * gates + STEP_PER_LATCH * n_latch,
            "sealedFloor": SEALED_BASE + SEALED_PER_NAND * n_nand + SEALED_PER_LATCH * n_latch}


def cmd_build(a) -> int:
    from tapc import prove as P, synth as S, pack as PK
    chip = Chip(a.chip, a.out)
    os.makedirs(chip.out, exist_ok=True)
    os.makedirs(chip.build_dir, exist_ok=True)
    say(f"== build {chip.name}: {', '.join(rel(s) for s in chip.sources)} -> {rel(chip.out)}")

    # 1. Synthesis: Yosys + ABC to NAND and LATCH records (TAP-20), packed with the latches first.
    try:
        r = S.synthesize(chip.sources, chip.name, out_dir=chip.out, top=chip.top, recipe=a.recipe,
                         build_dir=os.path.join(chip.build_dir, "synth"), pins=chip.tapc_pins(),
                         n_in=N_IN, n_out=N_OUT, max_bytes=24_000, timeout=a.timeout)
    except (S.SynthError, PK.PackError) as e:
        raise KitError(f"synthesis failed: {e}")
    nl = r.packed.netlist
    m = r.packed.manifest
    say(f"   {m['nNand']} NAND + {m['nLatch']} LATCH = {m['gateCount']} gates, {m['bytes']} bytes, depth {m['depth']}, "
        f"recipe {r.recipe}")
    bad = N.shape_violations(nl, "covenant-v1")
    if bad:
        raise KitError("the netlist is not a Covenant v1 chip (the Fab would refuse it): " + "; ".join(bad))
    say("   shape covenant-v1 (what the Fab checks): ok")
    data = nl.data

    # 2. Proofs: RTL == bytes and every property, with Yosys SAT and with z3, over every state and input.
    t0 = time.perf_counter()
    if a.no_prove:
        results = []
        say("   proofs SKIPPED (--no-prove): nothing below is proved")
    else:
        try:
            results = P.prove_all(chip.sources, chip.top, data, N_IN, N_OUT, props_v=chip.props_sources or None,
                                  props_top=chip.props_top, signals=chip.signals, tap_module=chip.tap_module,
                                  work=os.path.join(chip.build_dir, "prove"), timeout=a.timeout)
        except P.ProofError as e:
            raise KitError(f"proofs could not run: {e}")
        for res in results:
            say("   " + res.line())
        dump_json(chip.path("proofs.json"), P.report(nl, results, chip.name))
    proved = sum(res.ok for res in results)
    say(f"   {proved}/{len(results)} proved in {time.perf_counter() - t0:.1f} s -> {rel(chip.path('proofs.json'))}")

    # 3. Pin manifest and manifestHash.
    pins = pin_manifest(chip, data, nl.n_state)
    with open(chip.path("tape-pins.json"), "wb") as f:
        f.write(pins)
    manifest_hash = "0x" + hashlib.sha256(pins).hexdigest()
    say(f"   pin manifest {rel(chip.path('tape-pins.json'))}: valid against profile covenant-v1, "
        f"bound to the netlist")

    gas = gas_budget(nl.n_nand, nl.n_latch)
    summary = {
        "format": "covenant-kit-build/1",
        "name": chip.name,
        "config": rel(chip.config_path),
        "netlist": {"file": os.path.basename(chip.path("tap")), "hex": os.path.basename(chip.path("hex")),
                    "keccak256": keccak_hex(data), "bytes": len(data), "nIn": nl.n_in, "nOut": nl.n_out,
                    "nState": nl.n_state, "nNand": nl.n_nand, "nLatch": nl.n_latch,
                    "gateCount": nl.n_nand + nl.n_latch, "depth": m["depth"], "recipe": r.recipe},
        "manifest": {"file": os.path.basename(chip.path("tape-pins.json")), "sha256": manifest_hash,
                     "note": "the manifestHash for Fab.tapeoutChip; publish the file as .well-known/tape-pins.json"},
        "proofs": {"file": os.path.basename(chip.path("proofs.json")), "proved": proved, "total": len(results),
                   "ok": bool(results) and proved == len(results)},
        "gas": {**gas, "note": "gas the kernel gives each evaluator per beat (KernelFactory: 200,000 + 2,600 per "
                               "gate + 800 per latch for TapeOut's step; 40,000 + 200 per NAND + 400 per latch "
                               "for the sealed one)"},
        "sources": {rel(s): sha256_file(s) for s in [chip.config_path] + chip.sources
                    + chip.props_sources},
    }
    dump_json(chip.path("build.json"), summary)
    say(f"   keccak256    {summary['netlist']['keccak256']}")
    say(f"   manifestHash {manifest_hash}")
    say(f"   step gas     TapeOut {gas['stepFloor']:,}, sealed {gas['sealedFloor']:,} (fixed by the factory)")
    say(f"   -> {rel(chip.path('build.json'))}")
    if not summary["proofs"]["ok"]:
        say("BUILD FINISHED, BUT NOT EVERY PROOF PASSED" if results else "BUILD FINISHED WITHOUT PROOFS")
        return 1
    return 0


# ================================================================================================ quote

def quote(rpc: chain.Rpc, addrs: dict, data: bytes) -> dict:
    ret = rpc.eth_call(addrs["fab"], call_data("quote(bytes)", w(0x20)) + enc_bytes_arg(data))
    n_nand, n_latch, cost = dec_words(ret, 3)
    mint_price = uint_call(rpc, addrs["transistors"], "mintPrice()")
    protocol_fee = uint_call(rpc, addrs["transistors"], "protocolFee()")
    tapeout_fee = uint_call(rpc, addrs["circuits"], "TAPEOUT_FEE()")
    supply_cap = uint_call(rpc, addrs["transistors"], "supplyCap()")
    minted = uint_call(rpc, addrs["transistors"], "minted()")
    tank_price = uint_call(rpc, addrs["keeperTank"], "mintPrice()")
    calls = 1 if n_nand == 0 else 2
    if mint_price * (n_nand + n_latch) + protocol_fee * calls + tapeout_fee != cost:
        raise KitError("Fab.quote disagrees with TapeOut's prices read in the same block range; try again")
    return {
        "block": rpc.block_number(), "nNand": n_nand, "nLatch": n_latch, "transistors": n_nand + n_latch,
        "costWei": cost, "mintPriceWei": mint_price, "protocolFeeWei": protocol_fee, "mintCalls": calls,
        "tapeoutFeeWei": tapeout_fee, "supplyCap": supply_cap, "minted": minted,
        "remaining": supply_cap - minted if supply_cap >= minted else 0,
        "tankAllowanceWei": (n_nand + n_latch) * tank_price * TANK_ALLOWANCE_BPS // 10_000,
    }


def cmd_quote(a) -> int:
    chip = Chip(a.chip, a.out)
    b = chip.built()
    addrs = load_deployment()
    rpc = rpc_for(a.rpc)
    q = quote(rpc, addrs, b["_data"])
    say(f"== quote {chip.name} on X Layer (eth_call to Fab {addrs['fab']}, block {q['block']})")
    say(f"   transistors   {q['nNand']} NAND + {q['nLatch']} LATCH = {q['transistors']} (minted and burned in the tape-out call)")
    say(f"   mint          {q['transistors']} x {okb(q['mintPriceWei'])} = {okb(q['transistors'] * q['mintPriceWei'])}")
    say(f"   protocol fee  {q['mintCalls']} mint call(s) x {okb(q['protocolFeeWei'])} = {okb(q['mintCalls'] * q['protocolFeeWei'])}")
    say(f"   tape-out fee  {okb(q['tapeoutFeeWei'])}")
    say(f"   TOTAL         {okb(q['costWei'])}  ({q['costWei']} wei: Fab.tapeoutChip must carry exactly this)")
    say(f"   supply        {q['remaining']:,} of {q['supplyCap']:,} transistors left on the processor "
        f"({'enough' if q['remaining'] >= q['transistors'] else 'NOT ENOUGH'})")
    say(f"   settle gas    {okb(q['tankAllowanceWei'])} of the mint price becomes this chip's prepaid allowance "
        f"in the KeeperTank (85%), paid out to whoever calls settleAndRefund for its kernel. The OKB itself")
    say(f"                 reaches the tank only when someone calls Splitter.pull() ({addrs['splitter']}, anyone may); "
        "refunds stop while the shared tank is empty")
    say("   Gas for the transactions comes on top (see `kit.sh fork` for the amounts).")
    q["chip"] = chip.name
    q["keccak256"] = b["netlist"]["keccak256"]
    q["fab"] = addrs["fab"]
    q["readAt"] = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    dump_json(chip.path("quote.json"), q)
    say(f"   -> {rel(chip.path('quote.json'))}")
    return 0 if q["remaining"] >= q["transistors"] else 1


# ================================================================================================ envelope

def envelope_checks(e: dict) -> list:
    """KernelFactory._checkEnvelope, check for check: [(code, ok, rule)]."""
    el = e["epochLen"]
    return [
        (1, e["launcher"].lower() != ZERO, "launcher is not the zero address"),
        (2, 300 <= el <= 86_400, "epochLen is 300 .. 86400 s"),
        (3, e["allowancePayee"].lower() != ZERO, "allowancePayee is not the zero address"),
        (4, e["capT"] <= 128, "capT <= 128"),
        (5, e["capV"] <= 255, "capV <= 255"),
        (6, e["allowCumBps"] <= 5000, "allowCumBps <= 5000"),
        (7, e["ceilMax"] <= 1023, "ceilMax <= 1023"),
        (8, 1 <= e["relMax"] <= 256, "relMax is 1 .. 256"),
        (9, 1 <= e["floorRel"] <= e["relMax"], "floorRel is 1 .. relMax"),
        (10, 1 <= e["floorMin"] <= 425, "floorMin is 1 .. 425"),
        (11, e["fallbackEpochs"] >= 2, "fallbackEpochs >= 2"),
        (12, e["fbAllow"] <= e["capT"], "fbAllow <= capT"),
        (13, e["buyEnabled"] is True, "buyEnabled is true"),
        (14, el * e["fallbackEpochs"] <= MAX_FALLBACK_DELAY, "epochLen * fallbackEpochs <= 30 days"),
        (15, el * HALVING_SETTLES <= MAX_HALF_LIFE * e["floorRel"], "epochLen * 178 <= 30 days * floorRel"),
    ]


def field_bv(c, vec: list, layout, name: str):
    for n, off, wd in layout:
        if n == name:
            return c.bv(vec[off:off + wd])
    raise KeyError(name)


def clamp_analysis(data: bytes, env: dict, timeout: int = 600) -> dict:
    """For every state and every input word, can each clamp of chips/INTERFACE.md section 8.2 fire for this chip
    under this envelope? Each answer is a z3 query on the netlist bytes: `never` is a proof, `can` comes with a
    state and input word that does it. The state space includes states the chip may never reach from zero, so a
    `can` may be a state that does not occur in practice; a `never` holds regardless."""
    from tapc.prove import Z3Circuit, _z3
    z3 = _z3()
    c = Z3Circuit(data, N_IN, N_OUT)
    y, x = c.y, c.x
    O = lambda n: field_bv(c, y, km.OUTPUT_FIELDS, n)  # noqa: E731
    I = lambda n: field_bv(c, x, km.INPUT_FIELDS, n)  # noqa: E731
    ext = lambda v: z3.ZeroExt(11 - v.size(), v)  # noqa: E731
    tb, th, ta, tr = (ext(O(n)) for n in ("T_BUY", "T_HOLD", "T_ALLOW", "T_RES"))
    well = z3.And(z3.ULE(tb, 256), z3.ULE(th, 256), z3.ULE(ta, 256), z3.ULE(tr, 256), tb + th + ta + tr == 256)
    rel, ceil, res = ext(O("REL")), ext(O("CEIL")), ext(I("RES"))
    grad = x[80]
    on_curve = z3.Not(grad)
    eff_ta = z3.If(z3.ULE(ta, env["capT"]), ta, z3.BitVecVal(env["capT"], 11))
    conds = {
        "K1T": (z3.Not(well), "the T_ shares do not sum to 256: the whole inflow goes to the reserve"),
        "K2": (z3.And(well, on_curve, z3.UGT(ta, env["capT"])), f"T_ALLOW above capT {env['capT']}: clipped to it"),
        "K3": (z3.UGT(rel, env["relMax"]), f"REL above relMax {env['relMax']}: clipped to it"),
        "K5": (z3.And(z3.UGE(res, env["floorMin"]), z3.ULT(rel, env["floorRel"])),
               f"REL below floorRel {env['floorRel']} with the reserve at or above code {env['floorMin']}: raised"),
    }
    if env["ceilMax"] == 1023:
        conds["K2C"] = (None, "ceilMax is 1023: there is no per-settle ceiling to hit")
    else:
        conds["K2C"] = (z3.And(well, on_curve, eff_ta != 0,
                               z3.Or(ceil == 1023, z3.UGT(ceil, env["ceilMax"]))),
                        f"an allowance can exceed exp8(ceilMax {env['ceilMax']}) = {okb(km.exp8(env['ceilMax']))} "
                        "when the epoch's inflow is large enough: clipped to it")
    # K2L cannot fire while every allowance share the kernel applies is at most allowCumBps / 10000.
    conds["K2L"] = (z3.And(well, on_curve, z3.UGT(z3.ZeroExt(32, eff_ta) * 10_000,
                                                  z3.BitVecVal(env["allowCumBps"] * 256, 43))),
                    f"an allowance share above allowCumBps {env['allowCumBps']} / 10000: the lifetime cap clips it "
                    "once the allowance paid so far reaches that share of cumulative inflow")
    out = {}
    for name, (cond, meaning) in conds.items():
        if cond is None:
            out[name] = {"verdict": "never", "why": meaning}
            continue
        s = z3.Solver()
        s.set("timeout", timeout * 1000)
        s.add(cond)
        r = s.check()
        if r == z3.unsat:
            out[name] = {"verdict": "never", "why": "proved for every state and input (z3, on the netlist bytes)"}
        elif r == z3.sat:
            mdl = s.model()
            bits = lambda vs: sum(1 << i for i, b in enumerate(vs) if z3.is_true(mdl.eval(b, model_completion=True)))  # noqa: E731
            sv, xv = bits(c.s), bits(c.x)
            out[name] = {"verdict": "can", "why": meaning,
                         "example": {"state": "0x" + sv.to_bytes((len(c.s) + 7) // 8, "little").hex(),
                                     "inputs": "0x" + xv.to_bytes(12, "little").hex()}}
        else:
            out[name] = {"verdict": "unknown", "why": f"z3: {s.reason_unknown()}"}

    def extreme(term, maximize: bool, width: int) -> int:
        """Largest (or smallest) value `term` takes over every state and input, bit by bit."""
        v = 0
        for i in reversed(range(width)):
            s = z3.Solver()
            s.set("timeout", timeout * 1000)
            if maximize:
                trial = v | (1 << i)
                s.add(z3.UGE(term, trial))
                if s.check() == z3.sat:
                    v = trial
            else:
                s.add(z3.ULT(term, v | (1 << i)))
                if s.check() == z3.unsat:
                    v |= 1 << i
        return v

    out["_range"] = {
        "T_ALLOW max (well-formed groups, on the curve)": extreme(z3.If(z3.And(well, on_curve), ta, z3.BitVecVal(0, 11)), True, 11),
        "REL min": extreme(rel, False, 11),
        "REL max": extreme(rel, True, 11),
    }
    return out


def guarantees(e: dict) -> list:
    el = e["epochLen"]
    share = min(Decimal(e["capT"]) / 256, Decimal(e["allowCumBps"]) / 10000)
    lines = [
        f"allowance: at most {share * 100:.2f}% of the OKB that reaches the kernel (capT {e['capT']}/256, lifetime "
        f"allowCumBps {e['allowCumBps']}/10000), "
        + (f"at most {okb(km.exp8(e['ceilMax']))} in one settle, " if e["ceilMax"] != 1023 else "no per-settle ceiling, ")
        + f"paid to {e['allowancePayee']} only, and nothing after graduation",
        "everything else can only be bought and locked, burned, or wait in the reserve",
        f"reserve: at or above {okb(km.exp8(e['floorMin']))} at least {e['floorRel']}/256 of it is offered to the buy "
        f"leg each settle (half of it within {-(-HALVING_SETTLES // e['floorRel'])} settles, "
        f"{-(-HALVING_SETTLES // e['floorRel']) * el / 3600:.1f} h at one settle per {el} s epoch); at most "
        f"{e['relMax']}/256 per settle",
        f"fallback: if neither evaluator answers for {e['fallbackEpochs']} epochs ({e['fallbackEpochs'] * el / 3600:.1f} h),"
        f" settles apply the fallback word: {256 - e['fbAllow']}/256 bought, {e['fbAllow']}/256 allowance",
    ]
    return lines


def onchain_envelope_check(rpc: chain.Rpc, addrs: dict, env: dict, chip_id: int, salt: str) -> dict:
    """KernelFactory.predict reverts on an envelope create() would refuse. eth_call only."""
    data = call_data(f"predict({ENV_TUPLE},uint256,bytes32)", enc_envelope(env), w(chip_id), bytes.fromhex(salt[2:]))
    try:
        ret = rpc.eth_call(addrs["kernelFactory"], data)
        return {"ok": True, "chipId": chip_id, "predicted": "0x" + ret[12:32].hex()}
    except chain.RpcError as e:
        return {"ok": False, "chipId": chip_id, "revert": decode_revert(e)}


def cmd_envelope(a) -> int:
    chip = Chip(a.chip, a.out)
    b = chip.built()
    env = chip.envelope(a.launcher, a.payee, a.set)
    check_salt(a.salt)
    say(f"== envelope for {chip.name} (chips/INTERFACE.md section 7)")
    say("   " + env_tuple_text(env))
    checks = envelope_checks(env)
    for code, ok, rule in checks:
        say(f"   {'PASS' if ok else 'FAIL'}  {rule}" + ("" if ok else f"   (the factory reverts BadEnvelope({code}))"))
    local_ok = all(ok for _, ok, _ in checks)
    report = {"format": "covenant-kit-envelope/1", "chip": chip.name, "netlistKeccak256": b["netlist"]["keccak256"],
              "envelope": env, "factoryChecks": [{"code": c, "ok": ok, "rule": r} for c, ok, r in checks]}
    if local_ok:
        say("   What the factory then guarantees for ANY chip on this kernel:")
        for line in guarantees(env):
            say("     - " + line)
        report["guarantees"] = guarantees(env)
    if not a.offline:
        addrs = load_deployment()
        rpc = rpc_for(a.rpc)
        chk = onchain_envelope_check(rpc, addrs, env, a.chip_id if a.chip_id is not None else addrs["flagshipChipId"],
                                     a.salt)
        report["onchain"] = chk
        if chk["ok"]:
            say(f"   on chain: KernelFactory.predict accepts it (eth_call; checked with chip {chk['chipId']})")
        else:
            say(f"   on chain: KernelFactory.predict REVERTS {chk['revert']} (eth_call; chip {chk['chipId']})")
    say("   Which clamps this chip can trigger under this envelope (z3, every state and every input word):")
    t0 = time.perf_counter()
    ca = clamp_analysis(b["_data"], env, a.timeout)
    for k in ("K1T", "K2", "K2C", "K2L", "K3", "K5"):
        v = ca[k]
        line = f"     {k:4s} {v['verdict'].upper():7s} {v['why']}"
        if v.get("example"):
            line += f"  e.g. state {v['example']['state']} inputs {v['example']['inputs']}"
        say(line)
    rg = ca.pop("_range")
    say("   Output ranges over every state and input: " + "; ".join(f"{k} {v}" for k, v in rg.items()))
    say(f"   ({time.perf_counter() - t0:.1f} s. A chip that triggers clamps still runs: the kernel corrects its answer "
        "and records the clamp bits. A chip that triggers none decided every settle itself.)")
    report["clamps"] = ca
    report["outputRanges"] = rg
    dump_json(chip.path("envelope.json"), env)
    dump_json(chip.path("envelope-report.json"), report)
    say(f"   -> {rel(chip.path('envelope.json'))} (the envelope), "
        f"{rel(chip.path('envelope-report.json'))} (this report)")
    ok = local_ok and report.get("onchain", {}).get("ok", True)
    return 0 if ok else 1


# ================================================================================================ plan

PLAN_TEMPLATE = r"""#!/usr/bin/env bash
# Covenant launch plan for the chip "@@NAME@@", written by `chips/kit/kit.sh plan` on @@DATE@@.
#
# Every transaction below is signed by the launcher @@LAUNCHER@@ with its own key. The kit sent nothing.
#   1. Fab.tapeoutChip            tape the netlist out, paying Fab.quote at the moment of signing   1 transaction
#   2. KernelFactory.create       the kernel for this chip and this envelope                        1 transaction
#   3. Circuits.safeTransferFrom  hand the chip NFT to the kernel                                   1 transaction
#   4. Lens.preflight             both evaluators step the chip with the gas a settle gives them   read only
#   5. the deployment file for tools/launch-check, and the IGNIX launch settings                   nothing sent
# A step the state file records as done is skipped, so a run stopped between steps can be started again without
# repeating one; a state file whose chip or kernel is not this plan's stops the script. If it stopped with an error
# right after a signature, look the transaction up before running it again. Every step asks "yes" before it signs
# (CONFIRM=no turns that off). A transaction not signed by the launcher stops the script after it.
#
#   ACCOUNT=<your cast keystore name> bash @@SCRIPT@@
#   SIGN="--ledger" bash @@SCRIPT@@                 (any `cast send` signer options)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
RPC=${RPC:-https://rpc.xlayer.tech}
SIGN=${SIGN:---account ${ACCOUNT:?set ACCOUNT to your cast keystore name, or SIGN to other cast send signer options}}
CONFIRM=${CONFIRM:-ask}
STATE=${STATE:-$HERE/@@NAME@@.launch.json}
DEPLOYMENT_OUT=${DEPLOYMENT_OUT:-$HERE/@@NAME@@.deployment.json}

FAB=@@FAB@@
FACTORY=@@FACTORY@@
LENS=@@LENS@@
CIRCUITS=@@CIRCUITS@@
TANK=@@TANK@@
LAUNCHER=@@LAUNCHER@@
NETLIST_FILE=$HERE/@@NAME@@.hex
NETLIST_KECCAK=@@KECCAK@@
MANIFEST_HASH=@@MANIFEST@@   # SHA-256 of @@NAME@@.tape-pins.json
SALT=@@SALT@@
ENV_T='@@ENV_T@@'
ENV='@@ENV@@'
CHIP_TAPED=@@TOPIC@@   # topic 0 of Fab's ChipTaped(uint256,address,bytes32,bytes32,uint32,uint32)

die() { echo "plan: STOPPED: $*" >&2; exit 1; }
say() { echo "plan: $*"; }
lower() { tr '[:upper:]' '[:lower:]'; }
num() { awk '{print $1}'; }   # cast prints "123 [1.23e2]"
confirm() {
  [ "$CONFIRM" = no ] && return 0
  printf 'plan: about to sign: %s\nplan: type yes to sign it: ' "$1"
  read -r answer
  [ "$answer" = yes ] || die "not signed"
}
get() { if [ -f "$STATE" ]; then jq -r --arg k "$1" '.[$k] // empty' "$STATE"; fi; }
put() {
  local tmp
  tmp=$(mktemp)
  { if [ -f "$STATE" ]; then cat "$STATE"; else echo '{}'; fi; } | jq --arg k "$1" --arg v "$2" '.[$k] = $v' >"$tmp"
  mv "$tmp" "$STATE"
}
sent() { # receipt JSON -> transaction hash, or stop
  local tx
  tx=$(jq -r .transactionHash <<<"$1")
  [ "$(jq -r .status <<<"$1")" = 0x1 ] || die "transaction $tx failed"
  [ "$(jq -r .from <<<"$1" | lower)" = "$(lower <<<$LAUNCHER)" ] \
    || die "transaction $tx was signed by $(jq -r .from <<<"$1"), not by the launcher $LAUNCHER: check ACCOUNT / SIGN"
  echo "$tx"
}
for tool in cast jq awk; do command -v $tool >/dev/null || die "$tool is not installed"; done

NETLIST=$(tr -d '[:space:]' <"$NETLIST_FILE")
[ "$(cast keccak "$NETLIST")" = "$NETLIST_KECCAK" ] || die "$NETLIST_FILE is not the netlist this plan was written for"
[ "$(cast chain-id --rpc-url "$RPC")" = 196 ] || die "$RPC is not X Layer (chain 196)"
[ "$(cast call $FACTORY 'fab()(address)' --rpc-url "$RPC" | lower)" = "$(lower <<<$FAB)" ] || die "the factory was built for another Fab"
cast call $FACTORY "predict($ENV_T,uint256,bytes32)(address)" "$ENV" @@FLAGSHIP@@ $SALT --rpc-url "$RPC" >/dev/null \
  || die "KernelFactory.predict refuses this envelope (checked with chip @@FLAGSHIP@@); nothing was signed"
say "launcher $LAUNCHER; state file $STATE"

# ---- 1. Tape out through the Fab.
CHIP_ID=$(get chipId)
if [ -z "$CHIP_ID" ]; then
  read -r NNAND NLATCH COST <<<"$(cast call $FAB 'quote(bytes)(uint256,uint256,uint256)' "$NETLIST" --rpc-url "$RPC" | num | xargs)"
  say "1. tape-out: $NNAND NAND + $NLATCH LATCH = $((NNAND + NLATCH)) transistors for $(cast from-wei $COST) OKB; the launcher holds $(cast from-wei "$(cast balance $LAUNCHER --rpc-url "$RPC")") OKB"
  confirm "Fab.tapeoutChip(netlist, $MANIFEST_HASH) to $FAB with value $COST wei"
  RECEIPT=$(cast send $FAB 'tapeoutChip(bytes,bytes32)' "$NETLIST" $MANIFEST_HASH --value $COST --rpc-url "$RPC" $SIGN --json)
  TX=$(sent "$RECEIPT")
  CHIP_ID=$(jq -r --arg t $CHIP_TAPED '.logs[] | select(.topics[0] == $t) | .topics[1]' <<<"$RECEIPT" | head -1)
  [ -n "$CHIP_ID" ] || die "no ChipTaped event in $TX"
  CHIP_ID=$(cast to-dec $CHIP_ID)
  put tapeoutTx $TX
  put chipId $CHIP_ID
  say "   chip $CHIP_ID (transaction $TX)"
else
  [ "$(cast call $FAB 'chipInfo(uint256)(address,bytes32,uint32,uint32,address,bytes32)' $CHIP_ID --rpc-url "$RPC" | sed -n 2p)" = "$NETLIST_KECCAK" ] \
    || die "the state file $STATE records chip $CHIP_ID, which is not this netlist: set STATE to a new file"
  say "1. tape-out: done earlier, chip $CHIP_ID"
fi

# ---- 2. Create the kernel: its address follows from (factory, envelope, chip, salt).
PREDICTED=$(cast call $FACTORY "predict($ENV_T,uint256,bytes32)(address)" "$ENV" $CHIP_ID $SALT --rpc-url "$RPC")
KERNEL=$(get kernel)
if [ -z "$KERNEL" ]; then
  KERNEL=$PREDICTED
  say "2. kernel: $KERNEL"
  confirm "KernelFactory.create($ENV, $CHIP_ID, $SALT) on $FACTORY"
  RECEIPT=$(cast send $FACTORY "create($ENV_T,uint256,bytes32)" "$ENV" $CHIP_ID $SALT --rpc-url "$RPC" $SIGN --json)
  TX=$(sent "$RECEIPT")
  [ "$(cast call $FACTORY 'isKernel(address)(bool)' $KERNEL --rpc-url "$RPC")" = true ] || die "$KERNEL is not a kernel of the factory"
  put createTx $TX
  put kernel $KERNEL
  say "   created (transaction $TX)"
else
  [ "$(lower <<<$KERNEL)" = "$(lower <<<$PREDICTED)" ] \
    || die "the state file $STATE records kernel $KERNEL, but this envelope, chip and salt give $PREDICTED: set STATE to a new file"
  say "2. kernel: done earlier, $KERNEL"
fi

# ---- 3. Hand the chip to the kernel (it must hold its chip to bind and to settle).
OWNER=$(cast call $CIRCUITS 'ownerOf(uint256)(address)' $CHIP_ID --rpc-url "$RPC")
if [ "$(lower <<<$OWNER)" != "$(lower <<<$KERNEL)" ]; then
  [ "$(lower <<<$OWNER)" = "$(lower <<<$LAUNCHER)" ] || die "chip $CHIP_ID is held by $OWNER, not by the launcher: sign step 3 from that wallet"
  say "3. hand chip $CHIP_ID to the kernel"
  confirm "Circuits.safeTransferFrom($LAUNCHER, $KERNEL, $CHIP_ID) on $CIRCUITS"
  RECEIPT=$(cast send $CIRCUITS 'safeTransferFrom(address,address,uint256)' $LAUNCHER $KERNEL $CHIP_ID --rpc-url "$RPC" $SIGN --json)
  TX=$(sent "$RECEIPT")
  put handoverTx $TX
  say "   done (transaction $TX)"
else
  say "3. the kernel holds chip $CHIP_ID already"
fi
[ "$(lower <<<"$(cast call $CIRCUITS 'ownerOf(uint256)(address)' $CHIP_ID --rpc-url "$RPC")")" = "$(lower <<<$KERNEL)" ] || die "the kernel does not hold its chip"
[ "$(cast call $KERNEL 'chipId()(uint256)' --rpc-url "$RPC" | num)" = "$CHIP_ID" ] || die "kernel chip id mismatch"
[ "$(cast call $KERNEL 'token()(address)' --rpc-url "$RPC")" = 0x0000000000000000000000000000000000000000 ] || say "   note: the kernel is bound already"

# ---- 4. Preflight: one beat on each evaluator, zero state and zero inputs, with exactly a settle's gas.
P=$(cast call $LENS 'preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))' $KERNEL --rpc-url "$RPC" \
  | sed -E 's/ \[[^]]*\]//g; s/[(),]/ /g')
read -r SEALED_NOW T_RAN S_RAN AGREE T_GAS S_GAS T_FLOOR S_FLOOR MIN_SETTLE <<<"$P"
say "4. preflight: TapeOut step ran $T_RAN ($T_GAS gas of $T_FLOOR); sealed step ran $S_RAN ($S_GAS gas of $S_FLOOR); agree $AGREE"
say "   next settle goes straight to the sealed evaluator: $SEALED_NOW; minSettleGas $MIN_SETTLE"
put preflight "$(echo $P)"
[ "$T_RAN $S_RAN $AGREE" = "true true true" ] || die "preflight failed: do not launch a token against this kernel"

# ---- 5. What tools/launch-check needs, and the launch itself (signed at ignix.bot, not here).
jq -n --arg kernel $KERNEL --argjson chipId $CHIP_ID '{
  chainId: 196,
  note: "Written by the plan of chip @@NAME@@ (chips/kit). The shared addresses are those of deployments/xlayer.json.",
  splitter: "@@SPLITTER@@", circuits: "@@CIRCUITS@@", transistors: "@@TRANSISTORS@@", keeperTank: "@@TANK@@",
  teamRegistry: "@@REGISTRY@@", sealedVM: "@@SEALED@@", fab: "@@FAB@@", kernelFactory: "@@FACTORY@@",
  kernelImpl: "@@KIMPL@@", lens: "@@LENS@@", kernel: $kernel, chipId: $chipId }' >"$DEPLOYMENT_OUT"
say "5. wrote $DEPLOYMENT_OUT"
cat <<EOF

NEXT (nothing below is done by this script):
 a. Launch the token at ignix.bot/create from the launcher wallet $LAUNCHER (no other wallet: the kernel binds only
    a token its launcher created):
      vault Directed, recipient $KERNEL; quote OKB; buy and sell tax @@TAXB@@ / @@TAXS@@ bps (at least one side
      above 0); first buy 0; anti-snipe off; no founder round.
 b. Before you sign, capture the transaction (tools/README.md, "Launch day", step 3) and, at the repository root:
      node tools/launch-check/launch-check.ts --deployment $DEPLOYMENT_OUT --expected $HERE/@@NAME@@.expected.json --tx @tx.json
      node tools/launch-check/simulate.ts --deployment $DEPLOYMENT_OUT --tx @tx.json
    Sign only if both end with VERDICT: PASS.
 c. After the launch, bind (anyone may send it for a token the launcher created):
      cast send $KERNEL 'bind(address)' <token> --rpc-url $RPC <signer>
 d. Settle once per epoch (@@EPOCH@@ s). Anyone may; the KeeperTank refunds the caller's gas out of this chip's
    prepaid allowance, paid only from OKB the tank holds: the tape-out's share reaches it when someone calls
    Splitter.pull() (anyone may; the tank pays nothing while it is empty):
      cast send @@SPLITTER@@ 'pull()' --rpc-url $RPC <signer>
      cast send $TANK 'settleAndRefund(address)' $KERNEL --rpc-url $RPC <signer>
EOF
"""


def render_plan(chip: Chip, b: dict, addrs: dict, env: dict, salt: str, tax_buy: int, tax_sell: int,
                script_name: str) -> str:
    topic = keccak_hex(b"ChipTaped(uint256,address,bytes32,bytes32,uint32,uint32)")
    subs = {
        "NAME": chip.name, "DATE": _dt.date.today().isoformat(), "LAUNCHER": env["launcher"],
        "SCRIPT": script_name, "FAB": addrs["fab"], "FACTORY": addrs["kernelFactory"], "LENS": addrs["lens"],
        "CIRCUITS": addrs["circuits"], "TANK": addrs["keeperTank"], "TRANSISTORS": addrs["transistors"],
        "SPLITTER": addrs["splitter"], "REGISTRY": addrs["teamRegistry"], "SEALED": addrs["sealedVM"],
        "KIMPL": addrs["kernelImpl"], "KECCAK": b["netlist"]["keccak256"], "MANIFEST": b["manifest"]["sha256"],
        "SALT": salt, "ENV_T": ENV_TUPLE, "ENV": env_tuple_text(env), "TOPIC": topic,
        "TAXB": str(tax_buy), "TAXS": str(tax_sell), "EPOCH": str(env["epochLen"]),
        "FLAGSHIP": str(addrs["flagshipChipId"]),
    }
    text = PLAN_TEMPLATE
    for k, v in subs.items():
        text = text.replace(f"@@{k}@@", v)
    left = re.findall(r"@@[A-Z_]+@@", text)
    if left:
        raise KitError(f"plan template: unfilled {left}")
    return text


def write_plan(chip: Chip, b: dict, env: dict, salt: str, tax_buy: int, tax_sell: int, out_dir: str,
               name: str | None = None, symbol: str | None = None) -> str:
    addrs = load_deployment()
    os.makedirs(out_dir, exist_ok=True)
    script = os.path.join(out_dir, f"{chip.name}.plan.sh")
    with open(script, "w", encoding="utf-8") as f:
        f.write(render_plan(chip, b, addrs, env, salt, tax_buy, tax_sell, rel(script)))
    os.chmod(script, 0o755)
    for ext in ("hex",):                                  # the script reads the netlist from its own directory
        src = chip.path(ext)
        dst = os.path.join(out_dir, os.path.basename(src))
        if os.path.abspath(src) != os.path.abspath(dst):
            shutil.copyfile(src, dst)
    dump_json(os.path.join(out_dir, f"{chip.name}.envelope.json"), env)
    dump_json(os.path.join(out_dir, f"{chip.name}.expected.json"), {
        "description": f"Expected values for tools/launch-check, written by the plan of chip {chip.name}. The "
                       "kernel comes from the deployment file the plan writes.",
        "chainId": 196, "templateId": 3, "quote": ZERO, "venue": 1, "taxBuyBps": tax_buy, "taxSellBps": tax_sell,
        "protectionSecs": 8640000, "firstBuy": "0", "snipeStartBps": 0, "founderBps": 0, "name": name,
        "symbol": symbol, "kernel": None,
        "processor": {"circuits": addrs["circuits"], "transistors": addrs["transistors"]}})
    return script


def cmd_plan(a) -> int:
    chip = Chip(a.chip, a.out)
    b = chip.built()
    if not b["proofs"]["ok"] and not a.allow_unproven:
        raise KitError("not every proof passed in the last build; fix the chip or pass --allow-unproven")
    env = chip.envelope(a.launcher, a.payee, a.set)
    bad = [(c, r) for c, ok, r in envelope_checks(env) if not ok]
    if bad:
        raise KitError("the factory would refuse this envelope: " + "; ".join(f"BadEnvelope({c}): {r}" for c, r in bad))
    check_salt(a.salt)
    for t in (a.tax_buy, a.tax_sell):
        if not 0 <= t <= 1000:
            raise KitError("taxes are in bps, 0 .. 1000")
    if a.tax_buy == 0 and a.tax_sell == 0:
        raise KitError("the kernel binds only a token with a non-zero tax on at least one side")
    script = write_plan(chip, b, env, a.salt, a.tax_buy, a.tax_sell, chip.out, a.token_name, a.token_symbol)
    addrs = load_deployment()
    script_rel = rel(script)
    hexrel = rel(chip.path("hex"))
    say(f"== plan for {chip.name}, launcher {env['launcher']}")
    say(f"   runnable script: {script_rel}   (ACCOUNT=<keystore> bash {script_rel}; it asks before each signature and resumes)")
    say("   The exact transactions, in order (the script fills in COST, CHIP_ID and KERNEL as it goes):")
    say("")
    say(f"   # 1. tape out. COST = the third value of: cast call {addrs['fab']} 'quote(bytes)(uint256,uint256,uint256)' $(cat {hexrel})")
    say(f"   cast send {addrs['fab']} 'tapeoutChip(bytes,bytes32)' $(cat {hexrel}) {b['manifest']['sha256']} \\")
    say("       --value $COST --rpc-url https://rpc.xlayer.tech --account <you>")
    say("   #    CHIP_ID = topic 1 of the ChipTaped event in the receipt")
    say("   # 2. the kernel (KERNEL = the same call with `cast call` and 'predict(...)(address)')")
    say(f"   cast send {addrs['kernelFactory']} 'create({ENV_TUPLE},uint256,bytes32)' \\")
    say(f"       '{env_tuple_text(env)}' $CHIP_ID {a.salt} --rpc-url https://rpc.xlayer.tech --account <you>")
    say("   # 3. the chip to its kernel")
    say(f"   cast send {addrs['circuits']} 'safeTransferFrom(address,address,uint256)' {env['launcher']} $KERNEL $CHIP_ID \\")
    say("       --rpc-url https://rpc.xlayer.tech --account <you>")
    say("   # 4. preflight (read only): tapeoutRan, sealedRan and agree must all be true")
    say(f"   cast call {addrs['lens']} 'preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))' $KERNEL")
    say("   # 5. IGNIX launch at ignix.bot from the launcher: Directed vault with recipient $KERNEL, quote OKB, "
        f"tax {a.tax_buy}/{a.tax_sell} bps,")
    say("   #    first buy 0, anti-snipe off, no founder round. Before signing it:")
    say(f"   node tools/launch-check/launch-check.ts --deployment {rel(os.path.join(chip.out, chip.name + '.deployment.json'))} "
        f"--expected {rel(os.path.join(chip.out, chip.name + '.expected.json'))} --tx @tx.json")
    say(f"   node tools/launch-check/simulate.ts --deployment {rel(os.path.join(chip.out, chip.name + '.deployment.json'))} --tx @tx.json")
    say("   # 6. bind the token, then settle once per epoch:")
    say("   cast send $KERNEL 'bind(address)' $TOKEN ...;   cast send "
        f"{addrs['keeperTank']} 'settleAndRefund(address)' $KERNEL ...")
    say(f"   #    the tank refunds settle gas only from OKB it holds: cast send {addrs['splitter']} 'pull()' moves the "
        "tape-out's share in (anyone may)")
    say("")
    say(f"   Also written: {chip.name}.envelope.json, {chip.name}.expected.json (in {rel(chip.out)}).")
    say("   Rehearse all of it first on a local fork: chips/kit/kit.sh fork " + rel(chip.base)
        + f" --launcher {env['launcher']}")
    return 0


# ================================================================================================ fork

def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Anvil:
    def __init__(self, upstream: str, block: int | None, log: str):
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        cmd = ["anvil", "--fork-url", upstream, "--port", str(self.port), "--auto-impersonate", "--silent",
               "--chain-id", "196"]
        if block:
            cmd += ["--fork-block-number", str(block)]
        self.log = open(log, "w")
        self.proc = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
        try:
            self._wait(log)
        except BaseException:
            self.stop()
            raise

    def _wait(self, log: str) -> None:
        rpc = chain.Rpc(self.url, retries=0, timeout=30)
        for _ in range(90):
            if self.proc.poll() is not None:
                raise KitError(f"anvil exited (code {self.proc.returncode}); see {log}")
            try:
                rpc.chain_id()
                break
            except chain.RpcError:
                time.sleep(1)
        else:
            raise KitError("the anvil fork did not start within 90 s")
        if self.proc.poll() is not None:
            raise KitError("anvil exited; something else answers on its port")
        self.rpc = chain.Rpc(self.url, retries=2, timeout=120)
        info = self.rpc.call("anvil_nodeInfo", [])                 # refuses anything that is not anvil
        if not isinstance(info, dict):
            raise KitError("the node on the fork port is not anvil")

    def alive(self) -> bool:
        return self.proc.poll() is None

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.log.close()


def require_local(url: str) -> None:
    if (urlsplit(url).hostname or "") not in ("127.0.0.1", "localhost"):
        raise KitError(f"refusing to send transactions to {chain.rpc_host(url)}: only a local anvil fork")


def step_on_chain(rpc: chain.Rpc, circuits: str, chip_id: int, state: bytes, inputs: bytes, gas: int) -> tuple:
    ret = rpc.eth_call(circuits, chain.enc_step(chip_id, state, inputs), gas=gas)
    return chain.dec_step_return(ret)


def bounded_demo(rpc: chain.Rpc, addrs: dict, chip_id: int, n_state: int, env: dict, gas: int) -> list:
    """Six settles of the chip ON THE FORK (Circuits.step, eth_call), each routed by the kernel model of
    chips/golden/kernel_model.py (the arithmetic the Solidity kernel matches on the golden vectors) under the
    kernel's own envelope, as read back from the fork. Every buy is assumed to execute in full; the tax of the
    kernel's own buys is left out. No token, so no real settle: this shows what the clamps do to the chip's answers."""
    kenv = km.Envelope(capT=env["capT"], capV=env["capV"], allowCumBps=env["allowCumBps"], ceilMax=env["ceilMax"],
                       relMax=env["relMax"], floorRel=env["floorRel"], floorMin=env["floorMin"])
    flows = [5 * 10 ** 16, 5 * 10 ** 17, 10 ** 18, 5 * 10 ** 18, 20 * 10 ** 18, 100 * 10 ** 18]
    state = bytes((n_state + 7) // 8)
    reserve = cum = paid = 0
    rows = []
    for inflow in flows:
        cum += inflow
        x = km.pack_input({"TAX": km.lg8(inflow), "TAXCUM": km.lg8(cum), "RES": km.lg8(reserve), "DT": 1, "GRAD": 0})
        inputs = km.word_to_bytes(x, N_IN)
        ns, out = step_on_chain(rpc, addrs["circuits"], chip_id, state + bytes(32 - len(state)), inputs, gas)
        word = int.from_bytes(out, "little")
        o = km.unpack_output(word)
        r = km.route_tax(kenv, word, inflow, reserve, cum, paid)
        rows.append({
            "inflowWei": inflow, "reserveBeforeWei": reserve, "stateBefore": "0x" + state.hex(),
            "stateAfter": "0x" + ns.hex(), "asked": {k: o[k] for k in ("T_BUY", "T_ALLOW", "T_RES", "REL", "CEIL")},
            "clamps": [n for bit, n in CLAMP_NAMES if r.clamp & bit], "allowWei": r.allow, "buyDecidedWei": r.buy_decided,
            "effectiveRel": r.rel,
        })
        paid += r.allow
        reserve = r.reserve_after
        state = ns
    return rows


def cmd_fork(a) -> int:
    chip = Chip(a.chip, a.out)
    b = chip.built()
    addrs = load_deployment()
    launcher = a.launcher or outsider_address()
    env = chip.envelope(launcher, a.payee, a.set)
    check_salt(a.salt)
    bad = [(c, r) for c, ok, r in envelope_checks(env) if not ok]
    if bad:
        raise KitError("the factory would refuse this envelope: " + "; ".join(f"BadEnvelope({c}): {r}" for c, r in bad))
    work = os.path.join(chip.build_dir, "fork")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    say(f"== fork rehearsal for {chip.name}: LOCAL anvil fork of X Layer; nothing here reaches the real chain")
    anvil = Anvil(a.rpc or chain.XLAYER_RPCS[0], a.block, os.path.join(work, "anvil.log"))
    try:
        require_local(anvil.url)
        rpc = anvil.rpc
        block = rpc.block_number()
        say(f"   anvil pid {anvil.proc.pid} on {anvil.url}, forked at block {block}")
        if rpc.call("eth_getCode", [launcher, "latest"]) not in ("0x", "0x0"):
            raise KitError(f"{launcher} has code on chain; use an ordinary wallet address as launcher")
        funding = 10 ** 20
        rpc.call("anvil_setBalance", [launcher, hex(funding)])
        say(f"   outsider (impersonated, no key): {launcher}, given {okb(funding)} on the fork")
        script = write_plan(chip, b, env, a.salt, 300, 300, work)
        state_file = os.path.join(work, f"{chip.name}.launch.json")
        envp = dict(os.environ, RPC=anvil.url, SIGN=f"--unlocked --from {launcher}", CONFIRM="no", STATE=state_file)
        say(f"   running the plan script {rel(script)} against the fork:")
        t0 = time.perf_counter()
        proc = subprocess.run(["bash", script], env=envp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              timeout=1800)
        transcript = proc.stdout
        with open(os.path.join(work, "plan.transcript.txt"), "w", encoding="utf-8") as f:
            f.write(transcript)
        for line in transcript.splitlines():
            if line.startswith("plan:"):
                say("     " + line)
        if proc.returncode != 0:
            say(transcript[-3000:])
            raise KitError(f"the plan script failed on the fork (exit {proc.returncode})")
        if not anvil.alive():
            raise KitError("anvil died during the rehearsal")
        with open(state_file, "r", encoding="utf-8") as f:
            st = json.load(f)
        chip_id, kernel = int(st["chipId"]), st["kernel"]

        # Read everything back from the fork.
        gas = {}
        for key in ("tapeoutTx", "createTx", "handoverTx"):
            rc = rpc.call("eth_getTransactionReceipt", [st[key]])
            gas[key.replace("Tx", "")] = {"tx": st[key], "gasUsed": int(rc["gasUsed"], 16),
                                          "effectiveGasPrice": int(rc.get("effectiveGasPrice", "0x0"), 16)}
        pre = dec_words(rpc.eth_call(addrs["lens"], call_data("preflight(address)", waddr(kernel))), 9)
        preflight = dict(zip(("sealedModeNow", "tapeoutRan", "sealedRan", "agree", "tapeoutGas", "sealedGas",
                              "stepFloor", "sealedFloor", "minSettleGas"), pre))
        for k in ("sealedModeNow", "tapeoutRan", "sealedRan", "agree"):
            preflight[k] = bool(preflight[k])
        kenv = dec_envelope(rpc.eth_call(kernel, call_data("envelope()")))
        owner = "0x" + rpc.eth_call(addrs["circuits"], call_data("ownerOf(uint256)", w(chip_id)))[12:32].hex()
        is_kernel = bool(uint_call(rpc, addrs["kernelFactory"], "isKernel(address)", waddr(kernel)))
        fab_info = rpc.eth_call(addrs["fab"], call_data("chipInfo(uint256)", w(chip_id)))
        fw = dec_words(fab_info, 6)
        tank = uint_call(rpc, addrs["keeperTank"], "allowanceOf(uint256)", w(chip_id))
        pins_live = bool(uint_call(rpc, addrs["kernelFactory"], "pinsLive()"))
        demo = bounded_demo(rpc, addrs, chip_id, b["netlist"]["nState"], kenv, preflight["stepFloor"])
        paid_wei = sum(gas[k]["gasUsed"] * gas[k]["effectiveGasPrice"] for k in gas)
        cost_wei = int(rpc.call("eth_getTransactionByHash", [st["tapeoutTx"]])["value"], 16)
        seconds = time.perf_counter() - t0
    finally:
        anvil.stop()
    say(f"   anvil stopped (pid {anvil.proc.pid}, exit {anvil.proc.returncode})")

    checks = {
        "kernel holds its chip": owner.lower() == kernel.lower(),
        "factory.isKernel(kernel)": is_kernel,
        "kernel envelope is the planned one": {k: (v.lower() if isinstance(v, str) else v) for k, v in kenv.items()}
        == {k: (v.lower() if isinstance(v, str) else v) for k, v in env.items()},
        "Fab records the netlist (keccak256)": "0x" + fw[1].to_bytes(32, "big").hex() == b["netlist"]["keccak256"],
        "Fab records the manifestHash": "0x" + fw[5].to_bytes(32, "big").hex() == b["manifest"]["sha256"],
        "Fab records the outsider as author": "0x" + fw[4].to_bytes(32, "big")[12:].hex() == launcher.lower(),
        "preflight: TapeOut evaluator ran": preflight["tapeoutRan"],
        "preflight: sealed evaluator ran": preflight["sealedRan"],
        "preflight: both evaluators agree": preflight["agree"],
    }
    say("")
    say(f"   chip id {chip_id}, kernel {kernel}")
    for k, v in checks.items():
        say(f"   {'PASS' if v else 'FAIL'}  {k}")
    say(f"   preflight gas: TapeOut step {preflight['tapeoutGas']:,} of {preflight['stepFloor']:,} "
        f"({100 * preflight['tapeoutGas'] / preflight['stepFloor']:.1f}%), sealed step {preflight['sealedGas']:,} of "
        f"{preflight['sealedFloor']:,} ({100 * preflight['sealedGas'] / preflight['sealedFloor']:.1f}%); "
        f"minSettleGas {preflight['minSettleGas']:,}; next settle on the sealed evaluator: {preflight['sealedModeNow']} "
        f"(factory pins live: {pins_live})")
    say(f"   transaction gas: tape-out {gas['tapeout']['gasUsed']:,}, create {gas['create']['gasUsed']:,}, "
        f"hand-over {gas['handover']['gasUsed']:,}; paid {okb(cost_wei)} to the Fab + {okb(paid_wei)} gas at the fork's "
        "gas price")
    say(f"   KeeperTank allowance of chip {chip_id}: {okb(tank)} (prepaid settle gas)")
    say("   Six settles of the chip as taped out (Circuits.step on the fork), routed by the kernel model under the")
    say("   kernel's envelope (no token on a fork, so no real settle; buys assumed to execute in full):")
    say("     inflow      asked T_ALLOW  REL  CEIL   clamps        allowance paid       share")
    for r in demo:
        say(f"     {okb(r['inflowWei']):>11s} {r['asked']['T_ALLOW']:>8d}   {r['asked']['REL']:>5d} {r['asked']['CEIL']:>5d}   "
            f"{'+'.join(r['clamps']) or 'none':12s}  {okb(r['allowWei']):>18s}  {100 * r['allowWei'] / r['inflowWei']:6.2f}%")
    total_in = sum(r["inflowWei"] for r in demo)
    total_allow = sum(r["allowWei"] for r in demo)
    say(f"     total allowance {okb(total_allow)} of {okb(total_in)} inflow = {100 * total_allow / total_in:.2f}% "
        f"(envelope bound {min(kenv['capT'] / 256, kenv['allowCumBps'] / 10000) * 100:.2f}%)")
    report = {
        "format": "covenant-kit-fork/1",
        "note": "LOCAL ANVIL FORK of X Layer. Nothing here happened on the real chain. The launcher was impersonated.",
        "chip": chip.name, "forkBlock": block, "launcher": launcher, "chipId": chip_id, "kernel": kernel,
        "netlistKeccak256": b["netlist"]["keccak256"], "manifestHash": b["manifest"]["sha256"],
        "envelope": kenv, "checks": checks, "preflight": preflight, "pinsLive": pins_live, "transactions": gas,
        "fabValueWei": cost_wei, "keeperTankAllowanceWei": tank, "boundedDemo": demo, "seconds": round(seconds, 1),
    }
    dump_json(chip.path("fork.json"), report)
    say(f"   -> {rel(chip.path('fork.json'))}; transcript {rel(os.path.join(work, 'plan.transcript.txt'))}")
    ok = all(checks.values())
    say("FORK REHEARSAL: PASS" if ok else "FORK REHEARSAL: FAIL")
    return 0 if ok else 1


# ================================================================================================ main

def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="kit.sh", description="Covenant chip kit (see docs/BUILD_YOUR_CHIP.md).")
    sub = p.add_subparsers(dest="cmd", required=True)

    def chip_args(sp):
        sp.add_argument("chip", help="chip directory (holding chip.json) or kit config file")
        sp.add_argument("--out", help="output directory (default: <chip directory>/out)")

    def env_args(sp, launcher_required: bool):
        sp.add_argument("--launcher", required=launcher_required, help="the wallet that will create the token")
        sp.add_argument("--payee", help="allowance payee (default: the launcher)")
        sp.add_argument("--set", action="append", metavar="FIELD=VALUE", help="override an envelope field of chip.json")
        sp.add_argument("--salt", default="0x" + "00" * 32, help="bytes32 salt of the kernel address (default 0)")

    sp = sub.add_parser("new", help="a new chip directory from the Starter template")
    sp.add_argument("name")
    sp.add_argument("--dir", help="where (default chips/cells/<name>)")
    sp.set_defaults(fn=cmd_new)

    sp = sub.add_parser("build", help="synthesise, prove, pin manifest and manifestHash")
    chip_args(sp)
    sp.add_argument("--recipe", default="auto")
    sp.add_argument("--timeout", type=int, default=1800, help="seconds per synthesis recipe or proof")
    sp.add_argument("--no-prove", action="store_true", help="skip the proofs (plan then refuses the build)")
    sp.set_defaults(fn=cmd_build)

    sp = sub.add_parser("quote", help="Fab.quote on X Layer (eth_call)")
    chip_args(sp)
    sp.add_argument("--rpc", action="append", help="X Layer RPC (default: the public ones)")
    sp.set_defaults(fn=cmd_quote)

    sp = sub.add_parser("envelope", help="write and check the envelope; which clamps the chip can trigger")
    chip_args(sp)
    env_args(sp, True)
    sp.add_argument("--rpc", action="append", help="X Layer RPC (default: the public ones)")
    sp.add_argument("--offline", action="store_true", help="skip the eth_call to KernelFactory.predict")
    sp.add_argument("--chip-id", type=int, help="chip id for the on-chain check (default: the flagship's)")
    sp.add_argument("--timeout", type=int, default=600, help="seconds per z3 query")
    sp.set_defaults(fn=cmd_envelope)

    sp = sub.add_parser("plan", help="the exact transactions the launcher signs, as a runnable script")
    chip_args(sp)
    env_args(sp, True)
    sp.add_argument("--tax-buy", type=int, default=300, help="buy tax in bps for the launch-check expectations")
    sp.add_argument("--tax-sell", type=int, default=300, help="sell tax in bps")
    sp.add_argument("--token-name", help="token name for the launch-check expectations")
    sp.add_argument("--token-symbol", help="token symbol for the launch-check expectations")
    sp.add_argument("--allow-unproven", action="store_true")
    sp.set_defaults(fn=cmd_plan)

    sp = sub.add_parser("fork", help="tape out, create, hand over and preflight on a LOCAL anvil fork")
    chip_args(sp)
    env_args(sp, False)
    sp.add_argument("--rpc", help="upstream X Layer RPC to fork (default https://rpc.xlayer.tech)")
    sp.add_argument("--block", type=int, help="fork at this block (default: latest)")
    sp.set_defaults(fn=cmd_fork)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except KitError as e:
        print(f"kit {a.cmd}: {e}", file=sys.stderr)
        return 1
    except chain.RpcError as e:
        print(f"kit {a.cmd}: RPC error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
