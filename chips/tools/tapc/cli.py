"""tapc command line: info, pack, unpack, sim, synth, prove, difftest."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

from . import __version__
from . import netlist as N


def _load_tap(path_or_hex: str) -> bytes:
    if os.path.exists(path_or_hex):
        return N.read_netlist_file(path_or_hex)
    try:
        return N.from_hex(path_or_hex)
    except ValueError:
        raise SystemExit(f"tapc: {path_or_hex!r} is neither a file nor a hex string")


def _manifest_for(tap_path: str, explicit: str = None) -> dict:
    cand = explicit
    if not cand and os.path.exists(tap_path):
        base = tap_path.rsplit(".", 1)[0]
        if os.path.exists(base + ".manifest.json"):
            cand = base + ".manifest.json"
    if cand:
        with open(cand, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def _pins(args, m: dict) -> tuple:
    n_in = args.nin if args.nin is not None else m.get("nIn")
    n_out = args.nout if args.nout is not None else m.get("nOut")
    if n_in is None or n_out is None:
        raise SystemExit("tapc: --nin and --nout are required (no manifest found next to the netlist)")
    return n_in, n_out


def _hexbytes(s: str) -> bytes:
    return N.from_hex(s) if s else b""


# ------------------------------------------------------------------------------------------------ info

def cmd_info(a) -> int:
    from . import chain
    if a.rpc or a.cpu:
        if not (a.cpu and a.id is not None):
            raise SystemExit("tapc info: --cpu and --id are both needed for an on-chain circuit")
        rpc = chain.Rpc(a.rpc or list(chain.XLAYER_RPCS))
        info = chain.circuit_info(rpc, a.cpu, a.id)
        data = chain.fetch_netlist(rpc, a.cpu, a.id)
        n_in, n_out = info["nIn"], info["nOut"]
        extra = {"chainId": rpc.chain_id(), "block": rpc.block_number(), "cpu": a.cpu, "id": a.id,
                 "circuitInfo": info, **chain.implementation_of(rpc, a.cpu)}
        if a.save:
            with open(a.save, "wb") as f:
                f.write(data)
            extra["saved"] = a.save
    else:
        if not a.netlist:
            raise SystemExit("tapc info: give a netlist file / hex, or --cpu and --id")
        data = _load_tap(a.netlist)
        n_in, n_out = _pins(a, _manifest_for(a.netlist, a.manifest))
        extra = {}
    try:
        nl = N.check(data, n_in, n_out)
    except N.IllFormed as e:
        print(json.dumps({"wellFormed": False, "condition": e.condition, "reason": str(e), "bytes": len(data),
                          "keccak256": "0x" + N.keccak256(data).hex()}, indent=1))
        return 1
    doc = {"wellFormed": True, **nl.counts(), "latchesFirst": nl.latches_first, "flat": nl.is_flat}
    if nl.is_flat:
        doc["depth"] = N.depth_of(nl)
        doc["liveElements"] = N.live_count(nl)
    doc["tapeoutBurn"] = {"nand": nl.n_nand, "latch": nl.n_latch}
    doc.update(extra)
    bad = []
    if a.shape:
        bad = N.shape_violations(nl, a.shape)
        doc["shape"] = {"name": a.shape, "ok": not bad, "violations": bad}
    print(json.dumps(doc, indent=1))
    return 1 if bad else 0


# ------------------------------------------------------------------------------------------------ pack / unpack

def cmd_pack(a) -> int:
    from . import pack
    st = tuple(a.state.split(":"))
    if len(st) != 2:
        raise SystemExit("tapc pack: --state takes s:ns")
    try:
        p = pack.pack_blif_file(a.blif, name=a.name, state=st, in_port=a.in_port, out_port=a.out_port,
                                n_in=a.nin, n_out=a.nout, pins=pack.load_pins(a.pins), allow_undef=a.allow_undef)
    except pack.PackError as e:
        raise SystemExit(f"tapc pack: {e}")
    if a.max_bytes is not None and len(p.data) > a.max_bytes:
        raise SystemExit(f"tapc pack: netlist is {len(p.data)} bytes, above --max-bytes {a.max_bytes}")
    paths = pack.write_outputs(p, a.out)
    m = p.manifest
    print(f"{p.name}: nIn {m['nIn']}  nOut {m['nOut']}  nState {m['nState']}  NAND {m['nNand']}  "
          f"LATCH {m['nLatch']}  bytes {m['bytes']}")
    print(f"keccak256 {m['keccak256']}")
    for k, v in paths.items():
        print(f"  {k:9s}{v}")
    return 0


def cmd_unpack(a) -> int:
    from . import unpack
    data = _load_tap(a.netlist)
    n_in, n_out = _pins(a, _manifest_for(a.netlist, a.manifest))
    if a.list:
        text = unpack.listing(data, n_in, n_out)
    else:
        try:
            text = unpack.to_verilog(data, n_in, n_out, module=a.module)
        except (N.IllFormed, unpack.UnpackError) as e:
            raise SystemExit(f"tapc unpack: {e}")
    if a.output:
        with open(a.output, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


# ------------------------------------------------------------------------------------------------ sim

def cmd_sim(a) -> int:
    from . import sim
    data = _load_tap(a.netlist)
    n_in, n_out = _pins(a, _manifest_for(a.netlist, a.manifest))
    try:
        nl = N.check(data, n_in, n_out)
    except N.IllFormed as e:
        raise SystemExit(f"tapc sim: ill-formed netlist: {e}")
    if a.check:
        with open(a.check, "r", encoding="utf-8") as f:
            doc = json.load(f)
        rows = doc["beats"] if isinstance(doc, dict) else doc
        if isinstance(doc, dict) and "exhaustive" in doc:
            rows = rows + [dict(zip(("state", "inputs", "newState", "outputs"), r)) for r in doc["exhaustive"]]
        got = sim.step_many(nl, [_hexbytes(r.get("state", "")) for r in rows], [_hexbytes(r["inputs"]) for r in rows])
        bad = 0
        for r, (ns, out) in zip(rows, got):
            if out.hex() != r["outputs"].removeprefix("0x") or \
                    ("newState" in r and ns.hex() != r["newState"].removeprefix("0x")):
                bad += 1
                if bad <= 5:
                    print(f"MISMATCH state={r.get('state')} inputs={r['inputs']}: got newState={ns.hex()} "
                          f"outputs={out.hex()}, file says newState={r.get('newState')} outputs={r['outputs']}")
        print(f"{len(rows) - bad}/{len(rows)} vectors match")
        return 1 if bad else 0
    state = _hexbytes(a.state)
    rows = []
    for x in a.inputs or [""]:
        ns, out = sim.step(nl, None, None, state, _hexbytes(x))
        rows.append({"state": "0x" + sim.int_to_bytes(sim.bytes_to_int(state, nl.n_state), nl.n_state).hex(),
                     "inputs": "0x" + sim.int_to_bytes(sim.bytes_to_int(_hexbytes(x), nl.n_in), nl.n_in).hex(),
                     "newState": "0x" + ns.hex(), "outputs": "0x" + out.hex()})
        state = ns                                   # beats chain: each one starts from the previous new state
    print(json.dumps(rows if len(rows) > 1 else rows[0], indent=1))
    return 0


# ------------------------------------------------------------------------------------------------ synth

def cmd_synth(a) -> int:
    from . import pack, synth
    name = a.name or os.path.basename(a.sources[0]).rsplit(".", 1)[0].removesuffix("_core")
    st = tuple(a.state.split(":"))
    try:
        r = synth.synthesize(a.sources, name, out_dir=a.out, top=a.top, recipe=a.recipe, build_dir=a.build,
                             pins=pack.load_pins(a.pins), state=st, in_port=a.in_port, out_port=a.out_port,
                             n_in=a.nin, n_out=a.nout, timeout=a.timeout, jobs=a.jobs, hier=a.hier,
                             max_bytes=a.max_bytes)
    except (synth.SynthError, pack.PackError) as e:
        raise SystemExit(f"tapc synth: {e}")
    print(r.summary())
    for k, v in r.paths.items():
        print(f"  {k:9s}{v}")
    if a.shape:
        bad = N.shape_violations(r.packed.netlist, a.shape)
        print(f"shape {a.shape}: " + ("ok" if not bad else "DOES NOT FIT: " + "; ".join(bad)))
        return 1 if bad else 0
    return 0


# ------------------------------------------------------------------------------------------------ prove

def cmd_prove(a) -> int:
    from . import prove
    try:
        return _cmd_prove(a, prove)
    except (prove.ProofError, N.IllFormed) as e:
        raise SystemExit(f"tapc prove: {e}")


def _cmd_prove(a, prove) -> int:
    results = []
    t0 = time.perf_counter()
    if a.what == "equiv":
        data = _load_tap(a.tap)
        n_in, n_out = _pins(a, _manifest_for(a.tap, a.manifest))
        engines = ["yosys", "z3"] if a.engine == "both" else [a.engine]
        for eng in engines:
            f = prove.equiv_yosys if eng == "yosys" else prove.equiv_z3
            results.append(f(a.rtl, a.top, data, n_in, n_out, work=os.path.join(a.work, f"equiv_{eng}"),
                             timeout=a.timeout))
    elif a.what == "prop":
        data = n_in = n_out = None
        if a.tap:
            data = _load_tap(a.tap)
            n_in, n_out = _pins(a, _manifest_for(a.tap, a.manifest))
        engines = ["yosys", "z3"] if a.engine == "both" else [a.engine]
        for eng in engines:
            results += prove.prove_properties(a.rtl, a.top, a.signal or ["ok"], tap=data, n_in=n_in, n_out=n_out,
                                              tap_module=a.tap_module, work=os.path.join(a.work, f"prop_{eng}"),
                                              timeout=a.timeout, engine=eng)
    elif a.what == "z3":                                # Python predicates over the bytes
        data = _load_tap(a.tap)
        m = _manifest_for(a.tap, a.manifest)
        n_in, n_out = _pins(a, m)
        results = prove.check_z3(data, prove.load_predicates(a.props), n_in, n_out, manifest=m, timeout=a.timeout)
    else:                                               # all
        data = _load_tap(a.tap)
        m = _manifest_for(a.tap, a.manifest)
        n_in, n_out = _pins(a, m)
        results = prove.prove_all(a.rtl, a.top, data, n_in, n_out, props_v=a.props_v, props_top=a.props_top,
                                  signals=a.signal, tap_module=a.tap_module, props_py=a.props_py, manifest=m,
                                  work=a.work, timeout=a.timeout)
    for r in results:
        print(r.line())
    ok = all(r.ok for r in results) and bool(results)
    print(f"{sum(r.ok for r in results)}/{len(results)} proved in {time.perf_counter() - t0:.2f} s")
    if a.report:
        if data is None:
            raise SystemExit("tapc prove: --report needs --tap (the report is tied to the netlist's keccak256)")
        nl = N.check(data, n_in, n_out)
        name = (_manifest_for(a.tap, a.manifest) or {}).get("name", "")
        with open(a.report, "w", encoding="utf-8") as f:
            f.write(json.dumps(prove.report(nl, results, name, timings=a.timings), indent=1) + "\n")
    return 0 if ok else 1


# ------------------------------------------------------------------------------------------------ difftest

def cmd_difftest(a) -> int:
    from . import chain, difftest
    urls = a.rpc or list(chain.XLAYER_RPCS)
    manifest, local = None, None
    if a.manifest:
        with open(a.manifest, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    if a.tap:
        local = _load_tap(a.tap)
        manifest = manifest or _manifest_for(a.tap) or None
    mix = tuple(int(v) for v in a.mix.split(","))
    out = a.out or f"difftest-{a.cpu[:10].lower()}-{a.id}-seed{a.seed}.jsonl"
    extra = None
    if a.vectors:
        with open(a.vectors, "r", encoding="utf-8") as f:
            doc = json.load(f)
        extra = [dict(r, kind="file") for r in (doc.get("beats", []) if isinstance(doc, dict) else doc)]
        if isinstance(doc, dict):                       # tapc-vectors/1: rows of [state, inputs, newState, outputs]
            extra += [{"state": r[0], "inputs": r[1], "kind": "exhaustive"} for r in doc.get("exhaustive", [])]
    try:
        r = difftest.run(urls, a.cpu, a.id, n=a.n, seed=a.seed, out_path=out, per_call=a.per_call, mix=mix,
                         manifest=manifest, local_tap=local, force_step=a.step, gas_cap=a.gas_cap,
                         concurrency=a.concurrency, rpc_batch=a.rpc_batch, extra_vectors=extra,
                         progress=lambda m: print(m, file=sys.stderr, flush=True))
    except chain.RpcError as e:
        print(f"tapc difftest: {e}", file=sys.stderr)
        return 2
    h = r.header
    print(f"{r.matched}/{r.n} vectors identical, {r.mismatched} mismatched, {r.errors} not checked")
    print(f"{r.vectors_per_minute:.0f} vectors per minute ({r.chain_seconds:.1f} s on chain, "
          f"{h['callsPerEthCall']} calls per eth_call, {h['httpRequests']} HTTP requests, {h['httpRetries']} retries)")
    print(f"netlist keccak256 {h['netlistKeccak256']}  implementation {h['implementation']} code hash "
          f"{h['implementationCodeHash']}  blocks {h['blockStart']}..{h['blockEnd']}")
    if local is not None and not h["localNetlistMatches"]:
        print("LOCAL NETLIST DIFFERS FROM THE ON-CHAIN BYTES")
    for row in r.first_mismatches:
        print("MISMATCH", json.dumps(row))
    print(f"evidence: {r.evidence}")
    return 0 if r.ok and (local is None or h["localNetlistMatches"]) else 1


# ------------------------------------------------------------------------------------------------ fork-tapeout

def cmd_fork_tapeout(a) -> int:
    from . import chain, rehearse
    data = _load_tap(a.netlist)
    n_in, n_out = _pins(a, _manifest_for(a.netlist, a.manifest))
    try:
        r = rehearse.fork_tapeout(a.rpc, data, n_in, n_out, factory=a.factory, cpu=a.cpu,
                                  say=lambda m: print(m, file=sys.stderr, flush=True))
    except (rehearse.RehearsalError, chain.RpcError, N.IllFormed) as e:
        print(f"tapc fork-tapeout: {e}", file=sys.stderr)
        return 2
    doc = r.as_dict()
    doc["note"] = "LOCAL ANVIL FORK. Nothing here happened on a real chain."
    print(json.dumps(doc, indent=1))
    if a.report:
        with open(a.report, "w", encoding="utf-8") as f:
            f.write(json.dumps(doc, indent=1) + "\n")
    return 0 if r.netlist_matches else 1


# ------------------------------------------------------------------------------------------------ parser

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tapc", description="Covenant chip toolchain (TAP-20 netlists).")
    p.add_argument("--version", action="version", version=f"tapc {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    def pins(sp):
        sp.add_argument("--nin", type=int, help="number of inputs (default: from the manifest)")
        sp.add_argument("--nout", type=int, help="number of outputs (default: from the manifest)")
        sp.add_argument("--manifest", help="manifest JSON (default: <netlist>.manifest.json next to the file)")

    sp = sub.add_parser("info", help="counts, keccak256 and well-formedness of a netlist (file, hex or on-chain)")
    sp.add_argument("netlist", nargs="?", help=".tap file, .hex file or 0x... string")
    pins(sp)
    sp.add_argument("--rpc", action="append", help="RPC url (repeat for fallbacks; default: X Layer public RPCs)")
    sp.add_argument("--cpu", help="processor contract address")
    sp.add_argument("--id", type=int, help="circuit id")
    sp.add_argument("--save", help="write the fetched on-chain netlist bytes to this file")
    sp.add_argument("--shape", choices=sorted(N.SHAPES), help="also check a chip shape; exit 1 if it does not fit")
    sp.set_defaults(fn=cmd_info)

    sp = sub.add_parser("pack", help="BLIF from Yosys -> TAP-20 bytes, manifest and map")
    sp.add_argument("blif")
    sp.add_argument("--name", help="chip name (default: the BLIF model name without _core)")
    sp.add_argument("--out", default=".", help="output directory")
    sp.add_argument("--state", default="s:ns", help="state ports, <current>:<next> (default s:ns)")
    sp.add_argument("--in-port", default="x")
    sp.add_argument("--out-port", default="y")
    sp.add_argument("--nin", type=int, help="assert the input width")
    sp.add_argument("--nout", type=int, help="assert the output width")
    sp.add_argument("--pins", help="pins JSON naming input / output / state fields")
    sp.add_argument("--max-bytes", type=int, help="fail when the netlist is larger than this")
    sp.add_argument("--allow-undef", action="store_true", help="tie undefined ($undef) nets to 0 instead of failing")
    sp.set_defaults(fn=cmd_pack)

    sp = sub.add_parser("unpack", help="TAP-20 bytes -> structural Verilog (one beat as a combinational module)")
    sp.add_argument("netlist")
    pins(sp)
    sp.add_argument("--module", default="chip_tap", help="Verilog module name")
    sp.add_argument("--list", action="store_true", help="print a record listing instead of Verilog")
    sp.add_argument("-o", "--output")
    sp.set_defaults(fn=cmd_unpack)

    sp = sub.add_parser("sim", help="evaluate beats, or check a vector file")
    sp.add_argument("netlist")
    pins(sp)
    sp.add_argument("--state", default="", help="packed state, hex (default: all zero)")
    sp.add_argument("--inputs", action="append", help="packed inputs, hex; repeat to chain beats")
    sp.add_argument("--check", help="vector JSON ({beats:[{state,inputs,newState,outputs}]}) to verify")
    sp.set_defaults(fn=cmd_sim)

    sp = sub.add_parser("synth", help="Verilog core -> TAP-20 bytes (Yosys + ABC + pack)")
    sp.add_argument("sources", nargs="+", help="Verilog source files")
    sp.add_argument("--name", help="chip name (default: first source file name without _core)")
    sp.add_argument("--top", help="top module (default: <name>_core)")
    sp.add_argument("--out", default=".", help="output directory for .tap/.hex/.manifest.json/.map.json")
    sp.add_argument("--build", help="scratch directory (default: <out>/build)")
    sp.add_argument("--recipe", default="auto", help="auto, a recipe name, or a comma-separated list")
    sp.add_argument("--hier", action="store_true", help="map per module so the map keeps block names (more gates)")
    sp.add_argument("--pins", help="pins JSON naming input / output / state fields")
    sp.add_argument("--state", default="s:ns")
    sp.add_argument("--in-port", default="x")
    sp.add_argument("--out-port", default="y")
    sp.add_argument("--nin", type=int)
    sp.add_argument("--nout", type=int)
    sp.add_argument("--max-bytes", type=int)
    sp.add_argument("--timeout", type=float, default=1800)
    sp.add_argument("--jobs", type=int, default=4)
    sp.add_argument("--shape", choices=sorted(N.SHAPES), help="check a chip shape after the build; exit 1 if it does not fit")
    sp.set_defaults(fn=cmd_synth)

    sp = sub.add_parser("prove", help="proofs over every (state, input)")
    ps = sp.add_subparsers(dest="what", required=True)
    e = ps.add_parser("equiv", help="RTL core == netlist bytes")
    e.add_argument("--rtl", nargs="+", required=True, help="Verilog sources of the core")
    e.add_argument("--top", required=True, help="core module name")
    e.add_argument("--tap", required=True, help="netlist (.tap / .hex / 0x...)")
    e.add_argument("--engine", choices=["yosys", "z3", "both"], default="both")
    q = ps.add_parser("prop", help="a 1-bit output of a wrapper module is always 1")
    q.add_argument("--rtl", nargs="+", required=True, help="Verilog sources: the wrapper and what it instantiates")
    q.add_argument("--top", required=True, help="wrapper module name")
    q.add_argument("--signal", action="append", help="1-bit output to prove (repeatable; default ok)")
    q.add_argument("--tap", help="netlist to unpack and add to the sources")
    q.add_argument("--tap-module", default="chip_tap", help="module name for the unpacked netlist")
    q.add_argument("--engine", choices=["yosys", "z3", "both"], default="yosys")
    z = ps.add_parser("z3", help="Python predicates (prop_* functions) over the bytes, with z3")
    z.add_argument("tap")
    z.add_argument("--props", required=True, help="Python file defining prop_*(c) functions")
    w = ps.add_parser("all", help="equivalence (both engines) + wrapper properties (both engines) + z3 predicates")
    w.add_argument("--rtl", nargs="+", required=True, help="Verilog sources of the core")
    w.add_argument("--top", required=True, help="core module name")
    w.add_argument("--tap", required=True, help="netlist (.tap / .hex / 0x...)")
    w.add_argument("--props-v", nargs="+", help="Verilog sources of the property wrapper")
    w.add_argument("--props-top", help="property wrapper module name")
    w.add_argument("--signal", action="append", help="1-bit output to prove (default: every 1-bit output)")
    w.add_argument("--tap-module", default="chip_tap", help="module name the wrapper uses for the netlist")
    w.add_argument("--props-py", help="Python file defining prop_*(c) functions for z3")
    for s_ in (e, q, z, w):
        s_.add_argument("--nin", type=int)
        s_.add_argument("--nout", type=int)
        s_.add_argument("--manifest")
        s_.add_argument("--work", default="build/prove", help="scratch directory")
        s_.add_argument("--timeout", type=int, default=1800, help="seconds per proof")
        s_.add_argument("--report", help="write a JSON proof report here")
        s_.add_argument("--timings", action="store_true", help="include timings in the report (not reproducible)")
    sp.set_defaults(fn=cmd_prove)

    sp = sub.add_parser("difftest", help="on-chain step/eval versus the simulator")
    sp.add_argument("--rpc", action="append", help="RPC url (repeat for fallbacks; anvil fork urls work)")
    sp.add_argument("--cpu", required=True, help="processor contract address")
    sp.add_argument("--id", type=int, required=True, help="circuit id")
    sp.add_argument("--n", type=int, default=10000)
    sp.add_argument("--seed", type=int, default=1)
    sp.add_argument("--out", help="evidence JSONL path")
    sp.add_argument("--mix", default="4,3,3", help="uniform,walk,boundary weights (default 4,3,3)")
    sp.add_argument("--per-call", type=int, help="step calls per Multicall3 eth_call (default: calibrated)")
    sp.add_argument("--rpc-batch", type=int, default=10, help="eth_calls per JSON-RPC batch (max 10)")
    sp.add_argument("--concurrency", type=int, default=8, help="HTTP requests in flight (max 8)")
    sp.add_argument("--gas-cap", type=int, default=50_000_000)
    sp.add_argument("--tap", help="local netlist that must equal the on-chain bytes")
    sp.add_argument("--manifest", help="manifest with field layout, for field-boundary vectors")
    sp.add_argument("--vectors", help="extra vectors JSON (beats and/or exhaustive rows) appended to the run")
    sp.add_argument("--step", action="store_true", help="use step even for a circuit without state")
    sp.set_defaults(fn=cmd_difftest)

    sp = sub.add_parser("fork-tapeout", help="rehearse a tape-out on a LOCAL anvil fork (refuses any other node)")
    sp.add_argument("netlist", help=".tap file, .hex file or 0x... string")
    pins(sp)
    sp.add_argument("--rpc", required=True, help="url of a local anvil fork, e.g. http://127.0.0.1:28545")
    sp.add_argument("--factory", default="0x1f09DAeFA827f02CBb40967cc91b259763760761", help="TapeOut factory")
    sp.add_argument("--cpu", help="reuse this processor on the fork instead of creating a throwaway one")
    sp.add_argument("--report", help="write the result JSON here")
    sp.set_defaults(fn=cmd_fork_tapeout)

    sp = sub.add_parser("architect", add_help=False,
                        help="Covenant Architect compile: JSON request on stdin, JSON answer on stdout")
    sp.add_argument("rest", nargs=argparse.REMAINDER)
    sp.set_defaults(fn=lambda a: __import__("tapc.architect", fromlist=["main"]).main(a.rest))
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args)
    except (OSError, json.JSONDecodeError) as e:           # a missing or unreadable file: say so, no traceback
        print(f"tapc {args.cmd}: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("tapc: interrupted", file=sys.stderr)
        return 130
