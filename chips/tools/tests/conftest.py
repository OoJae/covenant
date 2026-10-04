"""Shared fixtures. Run from chips/tools:  ../.venv/bin/python -m pytest

Markers:
  live   needs the X Layer public RPC (read-only eth_call). Deselect offline with -m "not live".
"""
import json
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
CHIPS = TOOLS.parent
VENDOR = CHIPS / "vendor" / "tap-20"
PROBE = CHIPS / "probe"
RTL = Path(__file__).resolve().parent / "rtl"

for p in (str(TOOLS), str(VENDOR)):
    if p not in sys.path:
        sys.path.insert(0, p)


@pytest.fixture(scope="session")
def vectors():
    with open(VENDOR / "vectors.json", "r", encoding="utf-8") as f:
        return json.load(f)


@pytest.fixture(scope="session")
def reference():
    import reference as R          # chips/vendor/tap-20/reference.py (MIT, unmodified)
    return R


@pytest.fixture(scope="session")
def build_root(tmp_path_factory):
    return tmp_path_factory.mktemp("tapc")


def make_resolver(refs):
    """Resolver for the `refs` list of a vectors.json entry."""
    from tapc import netlist as N
    table = {}
    for r in refs:
        table[(bytes.fromhex(r["cpu"][2:]), r["id"])] = N.check(N.from_hex(r["netlist"]), r["nIn"], r["nOut"])
    return lambda cpu, cid: table.get((cpu, cid))
