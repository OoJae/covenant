"""Synthesis driver: Verilog core -> NAND-only netlist -> TAP-20 bytes.

Chip source convention: one pure combinational module

    module <name>_core(input [S-1:0] s, input [NIN-1:0] x, output [S-1:0] ns, output [NOUT-1:0] y);

(no `s`/`ns` for a combinational chip). Yosys elaborates and optimises it, ABC maps it onto a liberty library
whose cells are all priced in NAND records, and `tapc.pack` expands the cells into records.

A *recipe* is one (library, ABC script, front-end options) combination. `recipe="auto"` runs a small portfolio
of recipes and keeps the netlist with the fewest NAND records (ties go to the earlier recipe), so the build
stays deterministic: same sources + same pinned wheel -> same bytes -> same keccak.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Optional

from . import pack as packer
from . import yosys
from .cells import liberty_text


class SynthError(RuntimeError):
    pass


# Ripple-carry replacement for Yosys's default Brent-Kung $lcu. A ripple chain is the smallest adder in NAND
# records (9 per full adder); Brent-Kung trades gates for depth, and depth costs nothing on chain.
RIPPLE_LCU = """\
// tapc: ripple-carry technology mapping rule for $lcu (fewest gates; depth is free on chain).
(* techmap_celltype = "$lcu" *)
module _80_tapc_lcu_ripple (P, G, CI, CO);
	parameter WIDTH = 2;
	(* force_downto *)
	input [WIDTH-1:0] P, G;
	input CI;
	(* force_downto *)
	output [WIDTH-1:0] CO;
	wire [1023:0] _TECHMAP_DO_ = "proc; opt -fast";
	integer i;
	(* force_downto *)
	reg [WIDTH-1:0] c;
	always @* begin
		c[0] = G[0] | (P[0] & CI);
		for (i = 1; i < WIDTH; i = i + 1)
			c[i] = G[i] | (P[i] & c[i-1]);
	end
	assign CO = c;
endmodule
"""

# ABC scripts. Yosys wraps each one as: read_blif; read_lib -w cells.lib; <script>; write_blif.
# Every command here is deterministic (no time limits, no random seeds).
_COMPRESS = ("balance -l; resub -K 6 -l; rewrite -l; resub -K 6 -N 2 -l; refactor -l; resub -K 8 -l; balance -l; "
             "resub -K 8 -N 2 -l; rewrite -l; resub -K 10 -l; rewrite -z -l; resub -K 10 -N 2 -l; balance -l; "
             "resub -K 12 -l; refactor -z -l; resub -K 12 -N 2 -l; rewrite -z -l; balance -l")
_RESYN2 = "balance; rewrite; refactor; balance; rewrite; rewrite -z; balance; refactor -z; rewrite -z; balance"
ABC_SCRIPTS = {
    # the script the project's design notes first proposed
    "area": "strash; ifraig; dc2; dc2; dch -f; map -a; topo",
    # keep the structure Yosys produced (ripple chains, shared XORs); only map it
    "keep": "strash; map -a; topo",
    "keep-dch": "strash; dch -f; map -a; topo",
    "dc2x4": "strash; ifraig; dc2; dc2; dc2; dc2; dch -f; map -a; topo",
    # heavier AIG compression (ABC's compress2rs) before mapping
    "compress": f"strash; ifraig; {_COMPRESS}; dch -f; map -a; topo",
    "compress2": f"strash; ifraig; {_COMPRESS}; {_COMPRESS}; dch -f; map -a; topo",
    "compress-nodch": f"strash; ifraig; {_COMPRESS}; map -a; topo",
    "dc2-compress": f"strash; ifraig; dc2; dc2; {_COMPRESS}; dch -f; map -a; topo",
    # map, turn the mapped network back into an AIG, and map again with choices
    "compress-remap": f"strash; ifraig; {_COMPRESS}; dch -f; map -a; strash; dch -f; map -a; topo",
    "resyn2x2": f"strash; ifraig; {_RESYN2}; {_RESYN2}; dch -f; map -a; topo",
    # the newer cut-based mapper in area mode
    "nf": "strash; ifraig; dc2; dc2; &get -n; &dch -f; &nf -a; &put; topo",
}


@dataclass(frozen=True)
class Recipe:
    name: str
    library: Optional[str]            # a key of cells.LIBRARIES, or None for `abc -g NAND`
    script: Optional[str] = "area"    # a key of ABC_SCRIPTS
    ripple: bool = True               # ripple-carry $lcu instead of Brent-Kung
    hier: bool = False                # map each module on its own, flatten afterwards (keeps block names)
    share: bool = True                # run alumacc / share / wreduce / peepopt before mapping


RECIPES = {r.name: r for r in [
    # --- baselines, kept for the record (see chips/tools/NOTES.md) ---
    # the configuration first planned: INV + NAND2 both area 1 (plus the BUF that ABC insists on), default adders
    Recipe("nand-area", "nand", "area", ripple=False),
    Recipe("nand-ripple", "nand", "area"),
    # the fallback named in the task: ABC's built-in gate library restricted to NAND
    Recipe("g-nand", None, None, ripple=False),
    Recipe("g-nand-ripple", None, None),
    # --- macro-cell libraries (every cell priced in NAND records), ripple adders ---
    Recipe("xor-area", "xor", "area"),
    Recipe("basic-area", "basic", "area"),
    Recipe("rich-area", "rich", "area"),
    Recipe("rich-keep", "rich", "keep"),
    Recipe("rich-keep-dch", "rich", "keep-dch"),
    Recipe("rich-dc2x4", "rich", "dc2x4"),
    Recipe("rich-compress", "rich", "compress"),
    Recipe("rich-compress2", "rich", "compress2"),
    Recipe("rich-compress-nodch", "rich", "compress-nodch"),
    Recipe("rich-dc2-compress", "rich", "dc2-compress"),
    Recipe("rich-compress-remap", "rich", "compress-remap"),
    Recipe("rich-resyn2x2", "rich", "resyn2x2"),
    Recipe("rich-nf", "rich", "nf"),
    Recipe("arith-area", "arith", "area"),
]}

# What `recipe="auto"` tries, in tie-break order. No recipe wins everywhere (chips/tools/NOTES.md has the table),
# each one takes about two seconds on a 1,700-gate core, so the portfolio runs them all and keeps the smallest.
AUTO_PORTFOLIO = ["rich-compress", "rich-area", "rich-keep", "xor-area", "rich-compress2", "rich-dc2-compress",
                  "rich-compress-remap", "rich-dc2x4", "rich-keep-dch", "rich-resyn2x2", "rich-compress-nodch",
                  "rich-nf"]
FALLBACK_RECIPE = "g-nand-ripple"


@dataclass
class RecipeResult:
    recipe: str
    ok: bool
    seconds: float = 0.0
    n_nand: int = 0
    n_latch: int = 0
    n_bytes: int = 0
    keccak256: str = ""
    cells: dict = field(default_factory=dict)
    error: str = ""
    packed: Optional[packer.Packed] = None
    work: str = ""


@dataclass
class SynthResult:
    name: str
    packed: packer.Packed
    recipe: str
    results: list                 # RecipeResult for every recipe tried
    paths: dict
    seconds: float

    def summary(self) -> str:
        m = self.packed.manifest
        lines = [f"{self.name}: nIn {m['nIn']}  nOut {m['nOut']}  nState {m['nState']}  "
                 f"NAND {m['nNand']}  LATCH {m['nLatch']}  gates {m['gateCount']}  bytes {m['bytes']}  "
                 f"depth {m['depth']}",
                 f"keccak256 {m['keccak256']}",
                 f"recipe {self.recipe}  ({self.seconds:.1f} s total)"]
        for r in self.results:
            if r.ok:
                lines.append(f"  {'*' if r.recipe == self.recipe else ' '} {r.recipe:20s} NAND {r.n_nand:6d}  "
                             f"{r.seconds:6.1f} s  cells {_fmt_cells(r.cells)}")
            else:
                lines.append(f"    {r.recipe:20s} FAILED: {r.error.splitlines()[-1] if r.error else '?'}")
        return "\n".join(lines)


def _fmt_cells(cells: dict) -> str:
    return " ".join(f"{k}:{v}" for k, v in cells.items()) or "-"


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def yosys_script(recipe: Recipe, sources: list, top: str, blif: str) -> str:
    """The Yosys script for one recipe. `sources` are file names relative to the working directory."""
    L = [f"read_verilog -sv {' '.join(sources)}",
         f"hierarchy -check -top {top}",
         "proc"]
    if not recipe.hier:
        L.append("flatten")
    # the coarse and fine stages of Yosys's own `synth` script, minus fsm (a core has no registers)
    L += ["opt_expr", "opt_clean", "check -assert", "opt -nodffe -nosdff"]
    if recipe.share:
        L += ["wreduce", "peepopt", "opt_clean", "alumacc", "share", "opt"]
    L += ["memory -nomap", "opt_clean",            # case tables become ROMs in proc; map them to logic
          "opt -fast -full", "memory_map", "opt -full",
          "techmap -map +/techmap.v -map ripple_lcu.v" if recipe.ripple else "techmap",
          "opt -fast"]
    if recipe.library is None:
        L.append("abc -g NAND")
    else:
        L.append("abc -liberty cells.lib -script map.abc")
    if recipe.hier:
        L.append("flatten")
    L += ["opt_clean -purge", "stat", f"write_blif -gates {blif}"]
    return "\n".join(L) + "\n"


def _run_recipe(recipe: Recipe, sources: list, top: str, name: str, work: str, pack_kw: dict,
                timeout: Optional[float]) -> RecipeResult:
    t0 = time.perf_counter()
    res = RecipeResult(recipe.name, False, work=work)
    try:
        if os.path.isdir(work):
            shutil.rmtree(work)
        os.makedirs(work)
        local = []
        for i, src in enumerate(sources):
            dst = f"src{i}_{os.path.basename(src)}"
            shutil.copyfile(src, os.path.join(work, dst))
            local.append(dst)
        with open(os.path.join(work, "ripple_lcu.v"), "w", encoding="utf-8") as f:
            f.write(RIPPLE_LCU)
        if recipe.library is not None:
            with open(os.path.join(work, "cells.lib"), "w", encoding="utf-8") as f:
                f.write(liberty_text(recipe.library))
            with open(os.path.join(work, "map.abc"), "w", encoding="utf-8") as f:
                f.write(ABC_SCRIPTS[recipe.script] + "\n")
        blif = f"{name}.blif"
        run = yosys.run_script(yosys_script(recipe, local, top, blif), work, tag="synth", timeout=timeout)
        blif_path = os.path.join(work, blif)
        if not os.path.exists(blif_path):
            raise SynthError("yosys wrote no BLIF:\n" + "\n".join(run.log.strip().splitlines()[-15:]))
        p = packer.pack_blif_file(blif_path, name=name, **pack_kw)
        res.ok = True
        res.packed = p
        res.n_nand, res.n_latch = p.netlist.n_nand, p.netlist.n_latch
        res.n_bytes = len(p.data)
        res.keccak256 = p.manifest["keccak256"]
        res.cells = p.stats["cells"]
    except Exception as e:                     # a failed recipe must not sink the portfolio
        res.error = f"{type(e).__name__}: {e}"
    res.seconds = time.perf_counter() - t0
    return res


def synthesize(sources, name: str, out_dir: Optional[str] = None, top: Optional[str] = None,
               recipe: str = "auto", build_dir: Optional[str] = None, pins: Optional[dict] = None,
               state: tuple = ("s", "ns"), in_port: str = "x", out_port: str = "y",
               n_in: Optional[int] = None, n_out: Optional[int] = None, timeout: Optional[float] = 1800,
               jobs: int = 4, hier: bool = False, max_bytes: Optional[int] = None) -> SynthResult:
    """Synthesise a core and write <name>.tap / .hex / .manifest.json / .map.json into out_dir.

    recipe: "auto" (portfolio, smallest wins), a recipe name, or a comma-separated list of names.
    hier:   map each Verilog module separately so every gate keeps the instance path it came from (shown as
            `block` in <name>.map.json). Costs gates: ABC no longer optimises across module boundaries.
    """
    t0 = time.perf_counter()
    sources = [os.path.abspath(s) for s in ([sources] if isinstance(sources, str) else list(sources))]
    for s in sources:
        if not os.path.isfile(s):
            raise SynthError(f"no such source file: {s}")
    top = top or f"{name}_core"
    names = AUTO_PORTFOLIO if recipe == "auto" else [r.strip() for r in recipe.split(",") if r.strip()]
    unknown = [r for r in names if r not in RECIPES]
    if unknown:
        raise SynthError(f"unknown recipe(s) {unknown}; known: {', '.join(RECIPES)}")
    recipes = [RECIPES[r] for r in names]
    if hier:
        recipes = [Recipe(r.name, r.library, r.script, r.ripple, True, r.share) for r in recipes]
    build_dir = os.path.abspath(build_dir or os.path.join(out_dir or ".", "build"))
    pack_kw = dict(state=state, in_port=in_port, out_port=out_port, n_in=n_in, n_out=n_out, pins=pins)

    yosys.version()                                           # warms the wasm cache once, not once per job
    def job(r):
        return _run_recipe(r, sources, top, name, os.path.join(build_dir, r.name), pack_kw, timeout)

    if len(recipes) > 1 and jobs > 1:
        with ThreadPoolExecutor(max_workers=min(jobs, len(recipes))) as ex:
            results = list(ex.map(job, recipes))
    else:
        results = [job(r) for r in recipes]

    good = [r for r in results if r.ok]
    if not good and recipe == "auto":                         # last resort named in the task
        fb = _run_recipe(RECIPES[FALLBACK_RECIPE], sources, top, name,
                         os.path.join(build_dir, FALLBACK_RECIPE), pack_kw, timeout)
        results.append(fb)
        good = [fb] if fb.ok else []
    if not good:
        raise SynthError("every recipe failed:\n" + "\n".join(f"  {r.recipe}: {r.error}" for r in results))
    best = min(good, key=lambda r: (r.n_nand, results.index(r)))
    p = best.packed

    build = {
        "top": top, "recipe": best.recipe, "library": RECIPES[best.recipe].library,
        "abcScript": ABC_SCRIPTS.get(RECIPES[best.recipe].script) if RECIPES[best.recipe].library else "abc -g NAND",
        "ripple": RECIPES[best.recipe].ripple, "hier": hier,
        "yosys": yosys.short_version(), "packages": yosys.package_versions(),
        "sources": [{"file": os.path.basename(s), "sha256": _sha256(s)} for s in sources],
    }
    p.manifest["build"] = build
    if max_bytes is not None and len(p.data) > max_bytes:
        raise SynthError(f"netlist is {len(p.data)} bytes, above the limit of {max_bytes}")

    paths = {}
    if out_dir:
        paths = packer.write_outputs(p, out_dir)
    report = {
        "name": name, "chosen": best.recipe,
        "recipes": [{"recipe": r.recipe, "ok": r.ok, "seconds": round(r.seconds, 3), "nNand": r.n_nand,
                     "nLatch": r.n_latch, "bytes": r.n_bytes, "keccak256": r.keccak256, "cells": r.cells,
                     "error": r.error} for r in results],
    }
    os.makedirs(build_dir, exist_ok=True)
    with open(os.path.join(build_dir, f"{name}.synth.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(report, indent=1) + "\n")
    return SynthResult(name, p, best.recipe, results, paths, time.perf_counter() - t0)
