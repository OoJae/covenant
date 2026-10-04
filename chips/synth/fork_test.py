"""Local-fork tape-out and differential test. Nothing here touches mainnet state.

    chips/.venv-fg/bin/python chips/synth/fork_test.py [--block 72373000] [--n 10000] [--port 8546]

What it does, on a LOCAL anvil fork of X Layer pinned at --block:
  1. creates a throwaway processor through the real TapeOut factory (createCPU, 0.0066 OKB deploy fee paid
     by an anvil-funded account). The free test processor cpuAt(0) cannot be used: at the pinned block its
     transistor supply is fully minted (minted == supplyCap == 100,000);
  2. mints the NAND (id 0) and LATCH (id 1) transistors (0.00066 OKB protocol fee per mint call) and calls
     tapeout(bytes, 96, 112) with exactly 0.0013 OKB, for the Flow Governor and for both Glutton variants;
  3. checks circuitInfo and that netlist(id) returns exactly the local bytes;
  4. measures the gas of `step` with eth_estimateGas on several vectors;
  5. runs `tapc difftest` (on-chain step versus the tapc simulator) on --n generated vectors plus the witness,
     the mode tour and the scenario traces, then compares every on-chain answer with the Python MODEL
     (chips/model/flow_governor.py) as well;
  6. replays the witness (check 1 of the judge guide) with two plain eth_calls.

Results: chips/out/fg.fork.json, evidence chips/out/fg.difftest.jsonl.
The test account is a key-less address funded and impersonated on the fork; no key exists, is read or is printed.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))
sys.path.insert(0, os.path.join(CHIPS, "props"))

import flow_governor as fg  # noqa: E402
import scenarios as sc  # noqa: E402
from flow_governor import km  # noqa: E402
from tapc import difftest, netlist as tnl  # noqa: E402

FACTORY = "0x1f09daefa827f02cbb40967cc91b259763760761"
UPSTREAM = "https://rpc.xlayer.tech"
# A fresh address with no code and no key, funded and impersonated on the fork only. (anvil's first
# development account cannot be used: on X Layer it carries code, so ERC-1155 mints to it revert.)
DEV = "0x00000000000000000000000000000000C07E7A77"
DEPLOY_FEE = "0.0066ether"
MINT_FEE = "0.00066ether"
TAPEOUT_FEE = "0.0013ether"


def sh(*args, check=True) -> str:
    r = subprocess.run(list(args), capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])} ... failed:\n{r.stdout}\n{r.stderr}")
    return r.stdout.strip()


def rpc(url: str, method: str, params: list):
    req = urllib.request.Request(url, data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                                       "params": params}).encode(),
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as f:
        doc = json.load(f)
    if "error" in doc:
        raise RuntimeError(f"{method}: {doc['error']}")
    return doc["result"]


def hx(v: int, nbits: int) -> str:
    return "0x" + v.to_bytes((nbits + 7) // 8, "little").hex()


def tapeout(url: str, cpu: str, trans: str, tap: bytes, name: str) -> dict:
    nl = tnl.check(tap, 96, 112, None)
    before = int(sh("cast", "call", cpu, "nextId()(uint256)", "--rpc-url", url).split()[0])
    sh("cast", "send", trans, "mint(uint256,uint256)", "0", str(nl.n_nand), "--value", MINT_FEE,
       "--unlocked", "--from", DEV, "--rpc-url", url)
    sh("cast", "send", trans, "mint(uint256,uint256)", "1", str(nl.n_latch), "--value", MINT_FEE,
       "--unlocked", "--from", DEV, "--rpc-url", url)
    out = sh("cast", "send", cpu, "tapeout(bytes,uint32,uint32)", "0x" + tap.hex(), "96", "112",
             "--value", TAPEOUT_FEE, "--unlocked", "--from", DEV, "--rpc-url", url, "--json")
    rcpt = json.loads(out)
    cid = before + 1
    after = int(sh("cast", "call", cpu, "nextId()(uint256)", "--rpc-url", url).split()[0])
    assert after == cid, (before, after)
    info = sh("cast", "call", cpu, "circuitInfo(uint256)(uint32,uint32,uint32,uint32)", str(cid), "--rpc-url", url).split("\n")
    n_in, n_out, n_state, gates = (int(v.split()[0]) for v in info)
    assert (n_in, n_out, n_state, gates) == (96, 112, nl.n_latch, nl.n_nand + nl.n_latch), info
    chain_nl = sh("cast", "call", cpu, "netlist(uint256)(bytes)", str(cid), "--rpc-url", url)
    assert bytes.fromhex(chain_nl[2:]) == tap, "on-chain netlist differs from the local bytes"
    bal = [int(sh("cast", "call", trans, "balanceOf(address,uint256)(uint256)", DEV, str(i), "--rpc-url", url).split()[0])
           for i in (0, 1)]
    assert bal == [0, 0], f"transistors left after tape-out: {bal}"
    return {"name": name, "id": cid, "nNand": nl.n_nand, "nLatch": nl.n_latch, "gateCount": gates,
            "bytes": len(tap), "keccak256": "0x" + tnl.keccak256(tap).hex(),
            "tapeoutGasUsed": int(rcpt["gasUsed"], 16), "tapeoutTx": rcpt["transactionHash"]}


def step_gas(url: str, cpu: str, cid: int, s: int, x: int, n_state: int) -> int:
    data = sh("cast", "calldata", "step(uint256,bytes,bytes)", str(cid), hx(s, n_state), hx(x, 96))
    return int(rpc(url, "eth_estimateGas", [{"from": DEV, "to": cpu, "data": data}]), 16)


def step_call(url: str, cpu: str, cid: int, s: int, x: int, n_state: int):
    out = sh("cast", "call", cpu, "step(uint256,bytes,bytes)(bytes,bytes)", str(cid), hx(s, n_state), hx(x, 96),
             "--rpc-url", url).split("\n")
    return (int.from_bytes(bytes.fromhex(out[0][2:]), "little"), int.from_bytes(bytes.fromhex(out[1][2:]), "little"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--block", type=int, default=72373000)
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--port", type=int, default=8546)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--keep", action="store_true", help="leave anvil running")
    a = ap.parse_args(argv)
    url = f"http://127.0.0.1:{a.port}"
    out_dir = os.path.join(CHIPS, "out")

    anvil = subprocess.Popen(["anvil", "--fork-url", UPSTREAM, "--fork-block-number", str(a.block), "--port", str(a.port),
                              "--chain-id", "196", "--gas-limit", "300000000", "--silent"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(120):
            try:
                if int(rpc(url, "eth_blockNumber", []), 16) >= a.block:
                    break
            except Exception:
                time.sleep(0.5)
        else:
            raise RuntimeError("anvil did not come up")
        result = {"format": "covenant-fork-test/1", "chainId": 196, "forkBlock": a.block, "upstream": UPSTREAM,
                  "factory": FACTORY, "note": "local anvil fork; nothing was sent to mainnet"}
        assert rpc(url, "eth_getCode", [DEV, "latest"]) == "0x", "the test account must have no code"
        rpc(url, "anvil_setBalance", [DEV, hex(10 ** 19)])
        rpc(url, "anvil_impersonateAccount", [DEV])
        free = sh("cast", "call", FACTORY, "cpuAt(uint256)(address)", "0", "--rpc-url", url)
        ft = sh("cast", "call", free, "transistors()(address)", "--rpc-url", url)
        cap = int(sh("cast", "call", ft, "supplyCap()(uint256)", "--rpc-url", url).split()[0])
        minted = int(sh("cast", "call", ft, "minted()(uint256)", "--rpc-url", url).split()[0])
        result["freeTestProcessor"] = {"circuits": free, "supplyCap": cap, "minted": minted,
                                       "usable": cap - minted >= 2000}
        print(f"cpuAt(0) {free}: supplyCap {cap}, minted {minted} -> {'usable' if cap - minted >= 2000 else 'exhausted'}")

        # 1. a throwaway processor on the fork, through the real factory
        rc = json.loads(sh("cast", "send", FACTORY, "createCPU(string,string,string,uint256,uint256)",
                           "CovenantForkTest", "CFT", "local fork test", "100000", "0", "--value", DEPLOY_FEE,
                           "--unlocked", "--from", DEV, "--rpc-url", url, "--json"))
        topic = sh("cast", "keccak", "CPUCreated(address,address,address,string,uint256,uint256)")
        log = next(lg for lg in rc["logs"] if lg["topics"][0] == topic)
        cpu = sh("cast", "to-check-sum-address", "0x" + log["topics"][1][-40:])
        trans = sh("cast", "to-check-sum-address", "0x" + log["topics"][2][-40:])
        impl = sh("cast", "call", sh("cast", "call", FACTORY, "circuitBeacon()(address)", "--rpc-url", url),
                  "implementation()(address)", "--rpc-url", url)
        code_hash = sh("cast", "keccak", sh("cast", "code", impl, "--rpc-url", url))
        result["processor"] = {"circuits": cpu, "transistors": trans, "implementation": impl,
                               "implementationCodeHash": code_hash}
        print(f"processor {cpu} (transistors {trans}), implementation {impl} code hash {code_hash}")

        # 2-3. tape-outs
        chips = {}
        for name, path in (("fg", os.path.join(out_dir, "fg.tap")),
                           ("glutton", os.path.join(CHIPS, "cells", "glutton", "glutton.tap")),
                           ("glutton512", os.path.join(CHIPS, "cells", "glutton", "glutton512.tap"))):
            with open(path, "rb") as f:
                tap = f.read()
            chips[name] = tapeout(url, cpu, trans, tap, name)
            chips[name]["tap"] = tap
            c = chips[name]
            print(f"taped out {name}: id {c['id']}, {c['nNand']} NAND + {c['nLatch']} LATCH, {c['bytes']} bytes, "
                  f"tape-out gas {c['tapeoutGasUsed']:,}")

        # 4. step gas
        rng = random.Random(a.seed)
        cid = chips["fg"]["id"]
        t = sc.run_named("noisy")
        samples = [(0, 0)] + [(r.s_before, r.x) for r in t.rows[10:200:19]] + \
                  [(rng.getrandbits(64), rng.getrandbits(96)) for _ in range(6)] + [((1 << 64) - 1, (1 << 96) - 1)]
        gas = [step_gas(url, cpu, cid, s, x, 64) for s, x in samples]
        data_len = len(sh("cast", "calldata", "step(uint256,bytes,bytes)", str(cid), hx(0, 64), hx(0, 96))) // 2 - 1
        result["stepGas"] = {"method": "eth_estimateGas of step(id, state, inputs) from an EOA (includes the 21,000 "
                                       "base and calldata)", "samples": len(gas), "min": min(gas), "max": max(gas),
                             "mean": round(sum(gas) / len(gas)), "calldataBytes": data_len,
                             "perGate": round(sum(gas) / len(gas) / chips["fg"]["gateCount"], 1)}
        gg = step_gas(url, cpu, chips["glutton"]["id"], 0, 0, 1)
        result["gluttonStepGas"] = gg
        print(f"step gas (Flow Governor, {len(gas)} samples): min {min(gas):,} max {max(gas):,} mean {sum(gas) // len(gas):,} "
              f"= {result['stepGas']['perGate']} per gate;  Glutton {gg:,}")

        # 5. differential test: chain versus tapc.sim, then chain versus the model
        import witness as wit
        w = wit.build()
        i = lambda h: int.from_bytes(bytes.fromhex(h[2:]), "little")
        extra = []
        s = 0
        for h in w["tour"]["inputs"]:
            extra.append({"kind": "tour", "state": s.to_bytes(8, "little").hex(), "inputs": h[2:]})
            s, _ = fg.step(s, i(h))
        for key in ("reachA", "reachB"):
            extra.append({"kind": "witness", "state": w[key]["state"][2:], "inputs": w["x"][2:]})
        S = sc.scenarios()
        for name in S:
            tr = sc.run_named(name)
            for r in tr.rows:
                extra.append({"kind": "scenario", "state": r.s_before.to_bytes(8, "little").hex(),
                              "inputs": r.x.to_bytes(12, "little").hex()})
        with open(os.path.join(out_dir, "fg.manifest.json"), "r", encoding="utf-8") as f:
            manifest = json.load(f)
        ev_path = os.path.join(out_dir, "fg.difftest.jsonl")
        r = difftest.run([url], cpu, cid, n=a.n, seed=a.seed, out_path=ev_path, manifest=manifest,
                         local_tap=chips["fg"]["tap"], extra_vectors=extra, gas_cap=250_000_000,
                         progress=lambda m: print("  " + m, flush=True))
        model_bad = 0
        n_rows = 0
        with open(ev_path, "r", encoding="utf-8") as f:
            for line in f:
                row = json.loads(line)
                if row.get("type") != "vector":
                    continue
                n_rows += 1
                s0 = int.from_bytes(bytes.fromhex(row["state"]), "little")
                x0 = int.from_bytes(bytes.fromhex(row["inputs"]), "little")
                ns, y = fg.step(s0, x0)
                if (row.get("chainNewState") != ns.to_bytes(8, "little").hex()
                        or row.get("chainOutputs") != y.to_bytes(14, "little").hex()):
                    model_bad += 1
        result["difftest"] = {"vectors": r.n, "matchedSimulator": r.matched, "mismatched": r.mismatched,
                              "errors": r.errors, "kinds": r.header.get("kinds"),
                              "chainVersusModelMismatches": model_bad, "chainVersusModelVectors": n_rows,
                              "callsPerEthCall": r.per_call, "seconds": round(r.seconds, 1),
                              "localNetlistMatches": r.header.get("localNetlistMatches"),
                              "evidence": os.path.relpath(ev_path, os.path.dirname(CHIPS))}
        print(f"difftest: {r.matched}/{r.n} on-chain answers equal the simulator, {r.mismatched} mismatched, "
              f"{r.errors} not checked; versus the Python model: {model_bad} mismatches on {n_rows}")

        # 6. the witness, by two plain calls
        na, ya = step_call(url, cpu, cid, i(w["reachA"]["state"]), i(w["x"]), 64)
        nb, yb = step_call(url, cpu, cid, i(w["reachB"]["state"]), i(w["x"]), 64)
        wit_ok = (ya == i(w["outA"]["y"]) and yb == i(w["outB"]["y"]) and na == i(w["outA"]["newState"])
                  and nb == i(w["outB"]["newState"]) and (ya ^ yb) & ((1 << 91) - 1) != 0)
        result["witness"] = {"ok": wit_ok, "x": w["x"], "stateA": w["reachA"]["state"], "stateB": w["reachB"]["state"],
                             "routeA": w["outA"]["route"], "routeB": w["outB"]["route"]}
        print(f"witness on chain: {'OK' if wit_ok else 'FAILED'}: one input word, routes "
              f"{w['outA']['route']['modeName']} vs {w['outB']['route']['modeName']}")

        # Glutton: a short differential test and its constant demands
        for name in ("glutton", "glutton512"):
            c = chips[name]
            gr = difftest.run([url], cpu, c["id"], n=300, seed=a.seed, local_tap=c["tap"], gas_cap=250_000_000,
                              out_path=os.path.join(CHIPS, "cells", "glutton", f"{name}.difftest.jsonl"))
            ns, y = step_call(url, cpu, c["id"], 0, 0, 1)
            o = km.unpack_output(y)
            c["difftest"] = {"vectors": gr.n, "matched": gr.matched, "mismatched": gr.mismatched, "errors": gr.errors}
            c["demands"] = {k: o[k] for k in ("T_BUY", "T_ALLOW", "V_ALLOW", "REL", "CEIL")}
            print(f"{name}: difftest {gr.matched}/{gr.n}; demands {c['demands']}")
        for c in chips.values():
            c.pop("tap")
        result["chips"] = chips
        ok = (r.ok and model_bad == 0 and wit_ok and all(c.get("difftest", {"mismatched": 0, "errors": 0})["mismatched"] == 0
                                                         and c.get("difftest", {"errors": 0})["errors"] == 0
                                                         for c in chips.values()))
        result["ok"] = ok
        with open(os.path.join(out_dir, "fg.fork.json"), "w", encoding="utf-8") as f:
            json.dump(result, f, indent=1)
            f.write("\n")
        print("wrote", os.path.join(out_dir, "fg.fork.json"), "- OK" if ok else "- FAILED")
        return 0 if ok else 1
    finally:
        if not a.keep:
            anvil.terminate()
            try:
                anvil.wait(timeout=10)
            except subprocess.TimeoutExpired:
                anvil.kill()


if __name__ == "__main__":
    sys.exit(main())
