#!/usr/bin/env bash
# Reproducible-build check for every contract Covenant deployed on X Layer mainnet (chain 196).
#
#   deploy/verify-bytecode.sh                 build, compare, print the table
#   deploy/verify-bytecode.sh --keep          keep the scratch build directory (its path is printed)
#   deploy/verify-bytecode.sh --json FILE     also write the full result as JSON
#   deploy/verify-bytecode.sh --workdir DIR   build in DIR (must be empty or absent) and keep it; used by
#                                             deploy/verify-explorers.sh, which submits from that build
#   XLAYER_RPC_URL=<url> deploy/verify-bytecode.sh
#   DEPLOYMENTS=<file> deploy/verify-bytecode.sh   compare against another deployments record
#
# What it does, for each package at the commit deployments/xlayer.json records for it:
#   1. exports that commit's sources with `git archive` into a scratch directory (the working tree, its
#      uncommitted changes and contracts/*/lib are not used);
#   2. clones the pinned libraries at their release tags from GitHub (forge-std v1.17.0; OpenZeppelin Contracts
#      v5.4.0 for contracts/issuance, v5.7.0 for contracts/evaluator and contracts/core, as each package's
#      README/NOTES pins them; for contracts/evaluator also OpenZeppelin Contracts Upgradeable v5.7.0, which only
#      its test tree uses) and prints the commit each tag resolved to;
#   3. builds src/ with the commit's own foundry.toml (solc 0.8.28, cancun, 200 runs, legacy pipeline);
#   4. reads the chain (eth_getCode, eth_getTransactionByHash, eth_getTransactionReceipt, eth_call only) and
#      compares:
#        - creation code: the local creation bytecode must be the exact prefix of the deployment transaction's
#          input, and the rest of the input must decode to the constructor arguments the broadcast record and
#          deployments/xlayer.json name. Contracts created inside a constructor (TeamRegistry, KeeperTank, the
#          Kernel implementation) are checked by their address (CREATE from the parent at the expected nonce)
#          and by their local creation code appearing inside the parent's on-chain creation code;
#        - runtime code: on-chain code against the local deployedBytecode, byte for byte, after copying the
#          on-chain values into the immutable slots listed in the build's immutableReferences; every immutable
#          value is then checked against what the constructor arguments say it must be. Metadata is compared
#          too (core builds with bytecode_hash = none; evaluator and issuance with the default ipfs hash, so for
#          those a MATCH also means the metadata hash, and therefore every source file the contract is compiled
#          from, is identical). KernelFactory pins that only the broadcast record names (beacon, impl0Hash, wokb)
#          are also tied to facts on chain;
#        - the flagship kernel clone: OpenZeppelin's ERC-1167 clone with immutable args, its implementation, its
#          abi.encode(Globals, Envelope) arguments against the factory's immutables, the Fab's chip record and
#          the creation transaction, its CREATE2 address, `predict` and `isKernel` on the factory;
#        - the netlists: each chip the Fab taped out (2, the Flow Governor; 3 and 4, the Glutton demo chips) has an
#          SSTORE2 snapshot, 0x00 followed by the netlist; its bytes must equal the committed netlist file at the
#          commit deployments/xlayer.json records, hash to Fab.chipInfo's netlistHash, and equal TapeOut's own copy
#          (Circuits.netlist). The probe, circuit 1, was taped out directly on TapeOut: Circuits.netlist(1) must
#          equal chips/probe/probe.hex.
#
# Read-only: no transaction is sent, no key is read, nothing is written in the repository (the scratch
# directory is under $TMPDIR and removed on exit unless --keep). Needs: git, forge (Foundry 1.8+), python3
# (3.9+), network access to GitHub and to the RPC.
#
# Exit status: 0 when every Covenant row is MATCH, 1 otherwise. The processor's two contracts (Transistors,
# Circuits) are listed as NOT CHECKED: TapeOut's factory created them from TapeOut's code, not from this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="${DEPLOYMENTS:-$ROOT/deployments/xlayer.json}" # DEPLOYMENTS=<file>: check another record (e.g. a negative test)
RPC="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
KEEP=0
JSON_OUT=
WORKDIR=
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --json) JSON_OUT="$2"; shift ;;
    --workdir) WORKDIR="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "verify-bytecode.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$JSON_OUT" in ''|/*) ;; *) JSON_OUT="$PWD/$JSON_OUT" ;; esac

for tool in git forge python3; do
  command -v "$tool" >/dev/null || { echo "verify-bytecode.sh: $tool is required" >&2; exit 2; }
done
# A FOUNDRY_* variable in the caller's environment (a profile, an optimizer override) would change the build.
for v in $(env | sed -n 's/^\(FOUNDRY_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done

if [ -n "$WORKDIR" ]; then
  mkdir -p "$WORKDIR"
  [ -z "$(ls -A "$WORKDIR")" ] || { echo "verify-bytecode.sh: --workdir $WORKDIR is not empty" >&2; exit 2; }
  WORK="$(cd "$WORKDIR" && pwd)"
  KEEP=1
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-verify.XXXXXX")
fi
cleanup() { if [ "$KEEP" = 1 ]; then echo "build left in $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

commit_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["commit"])' "$LIVE" "$1"; }
ISS_COMMIT=$(commit_of issuance)
EVAL_COMMIT=$(commit_of evaluator)
CORE_COMMIT=$(commit_of core)

# package  commit  openzeppelin-contracts tag
BUILDS="issuance $ISS_COMMIT v5.4.0
evaluator $EVAL_COMMIT v5.7.0
core $CORE_COMMIT v5.7.0"

clone_tag() { # repo tag dest
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "https://github.com/$1" "$3"
  printf '  %-48s %-8s -> %s\n' "$1" "$2" "$(git -C "$3" rev-parse HEAD)"
}

echo "Covenant reproducible-build check, chain 196, RPC $RPC"
echo "scratch: $WORK"
while read -r pkg commit oz; do
  git -C "$ROOT" cat-file -e "$commit^{commit}" 2>/dev/null \
    || { echo "verify-bytecode.sh: commit $commit is not in this clone (git fetch --unshallow?)" >&2; exit 2; }
  dir="$WORK/$pkg"
  mkdir -p "$dir"
  git -C "$ROOT" archive "$commit" "contracts/$pkg" contracts/vendor | tar -x -C "$dir"
  proj="$dir/contracts/$pkg"
  echo "[$pkg] sources at $commit; libraries:"
  mkdir -p "$proj/lib"
  clone_tag foundry-rs/forge-std v1.17.0 "$proj/lib/forge-std"
  clone_tag OpenZeppelin/openzeppelin-contracts "$oz" "$proj/lib/openzeppelin-contracts"
  # contracts/evaluator's README also installs the upgradeable package: its test tree (never deployed) compiles
  # TapeOut's vendored sources with it. src/ does not import it; it is installed so that forge commands that load
  # the whole project (deploy/verify-explorers.sh) resolve every import.
  [ "$pkg" != evaluator ] || clone_tag OpenZeppelin/openzeppelin-contracts-upgradeable "$oz" "$proj/lib/openzeppelin-contracts-upgradeable"
  log="$WORK/$pkg.build.log"
  if ! (cd "$proj" && forge build src --ast >"$log" 2>&1); then
    echo "verify-bytecode.sh: forge build failed for $pkg; log follows" >&2; cat "$log" >&2; exit 1
  fi
  echo "[$pkg] built: $(grep -E 'Compiling|Compiler run' "$log" | tr '\n' ' ')"
done <<<"$BUILDS"


RPC="$RPC" WORK="$WORK" LIVE="$LIVE" ROOT="$ROOT" JSON_OUT="$JSON_OUT" python3 - <<'PY'
import json, os, sys, time, urllib.request

RPC, WORK, LIVE, ROOT, JSON_OUT = (os.environ[k] for k in ("RPC", "WORK", "LIVE", "ROOT", "JSON_OUT"))
D = json.load(open(LIVE))

# ---------------------------------------------------------------- keccak-256 (no third-party module needed)
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1

def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M if n else v

def _permute(A):
    for rc in _RC:
        C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
        Dd = [C[(x - 1) % 5] ^ _rol(C[(x + 1) % 5], 1) for x in range(5)]
        A = [[A[x][y] ^ Dd[x] for y in range(5)] for x in range(5)]
        B = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                B[y][(2 * x + 3 * y) % 5] = _rol(A[x][y], _ROT[x][y])
        A = [[B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        A[0][0] ^= rc
    return A

def keccak(data: bytes) -> bytes:
    rate = 136
    p = bytearray(data) + b"\x01"
    p += b"\x00" * (-len(p) % rate)
    p[-1] |= 0x80
    A = [[0] * 5 for _ in range(5)]
    for off in range(0, len(p), rate):
        for i in range(rate // 8):
            A[i % 5][i // 5] ^= int.from_bytes(p[off + 8 * i: off + 8 * i + 8], "little")
        A = _permute(A)
    return b"".join(A[i % 5][i // 5].to_bytes(8, "little") for i in range(4))

assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

# ---------------------------------------------------------------- chain access (read-only)
def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(6):
        try:
            req = urllib.request.Request(RPC, data=body, headers={"content-type": "application/json",
                                                                   "user-agent": "covenant-verify-bytecode"})
            with urllib.request.urlopen(req, timeout=60) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(f"{method}: {out['error']}")
            return out["result"]
        except Exception as e:  # rate limits and transient errors: back off and retry
            if attempt == 5:
                raise
            time.sleep(2 + 3 * attempt)

def h2b(x):
    x = x[2:] if x.startswith("0x") else x
    return bytes.fromhex(x)

def code(addr):
    return h2b(rpc("eth_getCode", [addr, "latest"]))

def call(to, data):
    return h2b(rpc("eth_call", [{"to": to, "data": "0x" + data.hex()}, "latest"]))

def sel(sig):
    return keccak(sig.encode())[:4]

def word_addr(a):
    return b"\x00" * 12 + h2b(a)

def addr_of(word):
    return "0x" + word[12:].hex()

def create_addr(sender, nonce):
    assert 1 <= nonce <= 0x7f
    return "0x" + keccak(bytes([0xD6, 0x94]) + h2b(sender) + bytes([nonce]))[12:].hex()

def create2_addr(deployer, salt, initcode):
    return "0x" + keccak(b"\xff" + h2b(deployer) + salt + keccak(initcode))[12:].hex()

def same(a, b):
    return a.lower() == b.lower()

# ---------------------------------------------------------------- build artifacts
def artifact(pkg, file, name):
    return json.load(open(os.path.join(WORK, pkg, "contracts", pkg, "out", file, name + ".json")))

_names = {}
def immutable_names(pkg):
    """AST id -> name of every immutable state variable in the package's build."""
    if pkg in _names:
        return _names[pkg]
    out, m = os.path.join(WORK, pkg, "contracts", pkg, "out"), {}
    def walk(n):
        if isinstance(n, dict):
            if n.get("nodeType") == "VariableDeclaration" and n.get("mutability") == "immutable":
                m[str(n["id"])] = n["name"]
            for v in n.values():
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    for d, _, files in os.walk(out):
        if "build-info" in d:
            continue
        for f in files:
            if f.endswith(".json"):
                walk(json.load(open(os.path.join(d, f))).get("ast"))
    _names[pkg] = m
    return m

def cbor_tail(b):
    """The CBOR metadata solc appends: {'solc': 'x.y.z', 'ipfs': <34 bytes>?} or None."""
    if len(b) < 2:
        return None
    n = int.from_bytes(b[-2:], "big")
    blob = b[-2 - n:-2]
    out, i = {}, 0
    try:
        if blob[0] & 0xE0 != 0xA0:
            return None
        count, i = blob[0] & 0x1F, 1
        for _ in range(count):
            kl = blob[i] & 0x1F; key = blob[i + 1: i + 1 + kl].decode(); i += 1 + kl
            t = blob[i]
            if t & 0xE0 == 0x40:  # byte string
                if t & 0x1F == 24:
                    vl, i = blob[i + 1], i + 2
                else:
                    vl, i = t & 0x1F, i + 1
                val = blob[i: i + vl]; i += vl
            elif t in (0xF4, 0xF5):
                val, i = (t == 0xF5), i + 1
            else:
                return None
            out[key] = val
    except Exception:
        return None
    if "solc" in out and len(out["solc"]) == 3:
        out["solc"] = ".".join(str(x) for x in out["solc"])
    if "ipfs" in out:
        alphabet, num, s = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz", int.from_bytes(out["ipfs"], "big"), ""
        while num:
            num, r = divmod(num, 58); s = alphabet[r] + s
        out["ipfs"] = s
    return out

def describe_meta(m):
    if m is None:
        return "no CBOR metadata"
    return f"solc {m.get('solc')}" + (f", ipfs {m['ipfs']}" if "ipfs" in m else ", no metadata hash")

# ---------------------------------------------------------------- checks
rows, results = [], []

class Row:
    def __init__(self, name, addr, pkg, commit):
        self.name, self.addr, self.pkg, self.commit = name, addr, pkg, commit
        self.checks, self.fail, self.unchecked = [], [], []
        self.creation = self.runtime = "-"
    def ok(self, cond, msg):
        (self.checks if cond else self.fail).append(("ok " if cond else "FAIL ") + msg)
        return cond
    def note(self, msg):
        self.checks.append("   " + msg)
    @property
    def verdict(self):
        if self.fail:
            return "MISMATCH"
        if self.unchecked:
            return "NOT CHECKED"
        return "MATCH"

def runtime_check(row, art, onchain, expected_imm):
    """Byte-for-byte after filling immutables from chain; then each immutable against its expected value."""
    local = h2b(art["deployedBytecode"]["object"])
    refs = art["deployedBytecode"].get("immutableReferences") or {}
    names = immutable_names(row.pkg)
    row.note(f"runtime: {len(onchain)} bytes on chain, {len(local)} bytes built, {len(refs)} immutable(s), "
             f"keccak on chain {keccak(onchain).hex()[:16]}...")
    if not row.ok(len(local) == len(onchain), f"runtime length: {len(onchain)} bytes on chain, {len(local)} built"):
        row.runtime = "MISMATCH (length)"
        return
    filled, consistent = bytearray(local), True
    values = {}
    for ast_id, places in refs.items():
        vals = {onchain[p["start"]: p["start"] + p["length"]] for p in places}
        if len(vals) != 1:
            consistent = False
        v = onchain[places[0]["start"]: places[0]["start"] + places[0]["length"]]
        for p in places:
            filled[p["start"]: p["start"] + p["length"]] = v
            if any(local[p["start"]: p["start"] + p["length"]]):
                consistent = False
        values[names.get(ast_id, "ast#" + ast_id)] = v
    row.ok(consistent, "every reference of each immutable holds one value (and is zero in the build)")
    exact = bytes(filled) == onchain
    if not exact:
        diff = next(i for i in range(len(onchain)) if filled[i] != onchain[i])
        meta_on, meta_loc = cbor_tail(onchain), cbor_tail(bytes(filled))
        n_on = int.from_bytes(onchain[-2:], "big") + 2
        body_same = bytes(filled[:-n_on]) == onchain[:-n_on]
        row.ok(False, f"runtime code differs from byte {diff}" +
               (" (only in the CBOR metadata: on chain " + describe_meta(meta_on) + "; built " +
                describe_meta(meta_loc) + ")" if body_same else ""))
        row.runtime = "MISMATCH (metadata only)" if body_same else "MISMATCH"
    else:
        row.ok(True, "runtime code identical to the build with immutables filled; metadata: "
               + describe_meta(cbor_tail(onchain)))
        row.runtime = "MATCH"
    if not consistent:  # the bytes agree once filled, but the build's immutable slots were not what solc leaves
        row.runtime = "MISMATCH (immutable slot)"
    for name, v in sorted(values.items()):
        exp = expected_imm.get(name)
        if exp is None:
            row.ok(False, f"immutable {name} = 0x{v.hex()} has no expected value in this script")
            row.runtime = "MISMATCH (unexplained immutable)"
        elif not row.ok(v == exp, f"immutable {name} = 0x{v[-20:].hex() if v[:12] == bytes(12) else v.hex()}"
                        + ("" if v == exp else f", expected 0x{exp.hex()}")):
            row.runtime = "MISMATCH (immutable value)"
    for name in sorted(set(expected_imm) - set(values)):
        row.ok(False, f"expected immutable {name} is not in the build's immutableReferences")

def creation_tx(row, art, txhash, n_args, expected_args):
    """Local creation bytecode == prefix of the creation transaction's input; the rest are the arguments."""
    tx = rpc("eth_getTransactionByHash", [txhash])
    rc = rpc("eth_getTransactionReceipt", [txhash])
    row.note(f"creation tx {txhash} block {int(rc['blockNumber'], 16)}")
    row.ok(tx["to"] is None and rc["contractAddress"] and same(rc["contractAddress"], row.addr)
           and rc["status"] == "0x1", "transaction is a successful contract creation of this address")
    row.ok(same(tx["from"], D["deployer"]), f"sent by the recorded deployer {D['deployer']}")
    inp, local = h2b(tx["input"]), h2b(art["bytecode"]["object"])
    if inp[: len(local)] == local:
        args = inp[len(local):]
        row.ok(len(args) == 32 * n_args, f"creation code: exact prefix of the transaction input "
               f"({len(local)} bytes), followed by {len(args)} bytes = {n_args} constructor argument word(s)")
        words = [args[i: i + 32] for i in range(0, len(args), 32)]
        for i, (label, exp) in enumerate(expected_args):
            if i < len(words):
                row.ok(words[i] == exp, f"constructor arg {label} = 0x{words[i].hex()}"
                       + ("" if words[i] == exp else f", expected 0x{exp.hex()}"))
        row.creation = "MATCH" if not row.fail else "MISMATCH (args)"
        return inp, words
    diff = next((i for i in range(min(len(inp), len(local))) if inp[i] != local[i]), min(len(inp), len(local)))
    row.ok(False, f"creation code differs from the transaction input at byte {diff} of {len(local)}")
    row.creation = "MISMATCH"
    return inp, []

def inner_creation(row, art, parent_addr, parent_input, nonce):
    local = h2b(art["bytecode"]["object"])
    row.ok(same(create_addr(parent_addr, nonce), row.addr),
           f"address is CREATE({parent_addr}, nonce {nonce})")
    found = local in parent_input
    row.ok(found, f"local creation code ({len(local)} bytes) is embedded in the parent's on-chain creation code")
    row.creation = "MATCH (embedded in parent)" if found else "MISMATCH"

W = lambda a: word_addr(a)
iss, ev, core, flag = D["issuance"], D["evaluator"], D["core"], D["flagship"]

def broadcast_args(pkg, script, name):
    p = os.path.join(ROOT, "contracts", pkg, "broadcast", script, "196", "run-latest.json")
    for t in json.load(open(p))["transactions"]:
        if t.get("transactionType") == "CREATE" and t.get("contractName") == name:
            return t.get("arguments") or []
    raise KeyError(name)

def tx_for(addr, hashes):
    for h in hashes:
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc.get("contractAddress") and same(rc["contractAddress"], addr):
            return h
    raise KeyError(addr)

def b32(x):
    return h2b(x).rjust(32, b"\x00") if len(h2b(x)) == 20 else h2b(x).ljust(32, b"\x00")

S = {}  # values one check hands to a later one

def check(name, addr, pkg, commit):
    """Runs the decorated check for one row; an exception (an RPC failure, a missing file) fails that row."""
    def wrap(fn):
        r = Row(name, addr() if callable(addr) else addr, pkg, commit)
        try:
            fn(r)
        except Exception as ex:
            r.ok(False, f"check could not complete: {type(ex).__name__}: {ex}")
            if r.creation == "-":
                r.creation = "NOT CHECKED"
            if r.runtime == "-":
                r.runtime = "NOT CHECKED"
        rows.append(r)
        return fn
    return wrap

# ---- issuance: Splitter, TeamRegistry, KeeperTank
@check("Splitter", iss["splitter"], "issuance", iss["commit"])
def _(r):
    a = artifact("issuance", "Splitter.sol", "Splitter")
    bargs = broadcast_args("issuance", "Ignite.s.sol", "Splitter")
    r.ok(same(bargs[1], D["deployer"]) and h2b(bargs[2]) == h2b(iss["commit"]),
         "broadcast record: maintainer is the deployer, commit is the one built here")
    S["splitter_input"], _w = creation_tx(r, a, iss["splitterTx"], 3, [
        ("factory (TapeOut CircuitFactory)", W(bargs[0])),
        ("maintainer", W(D["deployer"])),
        ("commit (bytes20)", h2b(iss["commit"])[:20].ljust(32, b"\x00")),
    ])
    runtime_check(r, a, code(r.addr), {
        "TRANSISTORS": W(iss["transistors"]), "CIRCUITS": W(iss["circuits"]), "TANK": W(iss["keeperTank"]),
        "MAINTAINER": W(D["deployer"]), "REGISTRY": W(iss["teamRegistry"]),
    })

@check("TeamRegistry", iss["teamRegistry"], "issuance", iss["commit"])
def _(r):
    a = artifact("issuance", "TeamRegistry.sol", "TeamRegistry")
    inner_creation(r, a, iss["splitter"], S["splitter_input"], 1)
    runtime_check(r, a, code(r.addr), {})
    isteam = call(r.addr, sel("isTeam(address)") + W(D["deployer"]))
    r.ok(int.from_bytes(isteam, "big") == 1, "isTeam(deployer) is true (constructor argument founder = deployer)")

@check("KeeperTank", iss["keeperTank"], "issuance", iss["commit"])
def _(r):
    a = artifact("issuance", "KeeperTank.sol", "KeeperTank")
    inner_creation(r, a, iss["splitter"], S["splitter_input"], 2)
    runtime_check(r, a, code(r.addr), {"SPLITTER": W(iss["splitter"])})

# ---- evaluator: SealedVM, Fab
@check("SealedVM", ev["sealedVM"], "evaluator", ev["commit"])
def _(r):
    a = artifact("evaluator", "SealedVM.sol", "SealedVM")
    creation_tx(r, a, tx_for(r.addr, ev["txs"]), 0, [])
    runtime_check(r, a, code(r.addr), {})

@check("Fab", ev["fab"], "evaluator", ev["commit"])
def _(r):
    a = artifact("evaluator", "Fab.sol", "Fab")
    creation_tx(r, a, tx_for(r.addr, ev["txs"]), 2, [("circuits", W(iss["circuits"])),
                                                     ("transistors", W(iss["transistors"]))])
    runtime_check(r, a, code(r.addr), {"CIRCUITS": W(iss["circuits"]), "TRANSISTORS": W(iss["transistors"])})

# ---- core: KernelFactory, Kernel implementation, Lens
BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"  # EIP-1967 beacon slot
KF_PINS =["manager", "v2Router", "wokb", "circuits", "fab", "sealedVM", "beacon", "impl0", "impl0Hash"]

@check("KernelFactory", core["kernelFactory"], "core", core["commit"])
def _(r):
    a = artifact("core", "KernelFactory.sol", "KernelFactory")
    bargs = broadcast_args("core", "DeployCore.s.sol", "KernelFactory")
    exp_args = [(l, b32(v)) for l, v in zip(KF_PINS, bargs)]
    r.ok(len(bargs) == 9 and same(bargs[3], iss["circuits"]) and same(bargs[4], ev["fab"])
         and same(bargs[5], ev["sealedVM"]), "broadcast record: circuits, fab and sealedVM are Covenant's recorded ones")
    S["factory_input"], words = creation_tx(r, a, tx_for(r.addr, core["txs"]), 9, exp_args)
    imm = {l: w for (l, w) in exp_args}
    imm["kernelImpl"] = W(core["kernelImpl"])
    runtime_check(r, a, code(r.addr), imm)
    # Six pins come only from the broadcast record above; tie them to facts on chain that cannot change.
    beacon_of_circuits = h2b(rpc("eth_getStorageAt", [iss["circuits"], BEACON_SLOT, "latest"]))
    r.ok(imm["beacon"] == beacon_of_circuits, "pin beacon = the EIP-1967 beacon of Covenant's Circuits")
    r.ok(imm["impl0Hash"] == keccak(code(addr_of(imm["impl0"]))), "pin impl0Hash = keccak256 of impl0's code")
    r.ok(imm["wokb"] == call(addr_of(imm["v2Router"]), sel("WETH()")), "pin wokb = v2Router.WETH()")
    # informational only: the manager is a proxy and TapeOut may upgrade its beacon
    r.note("pin v2Router " + ("=" if imm["v2Router"] == call(addr_of(imm["manager"]), sel("V2_ROUTER02()")) else "!=")
           + " manager.V2_ROUTER02() today; pin impl0 "
           + ("=" if imm["impl0"] == call(addr_of(imm["beacon"]), sel("implementation()")) else "!=")
           + " beacon.implementation() today")

@check("Kernel (implementation)", core["kernelImpl"], "core", core["commit"])
def _(r):
    a = artifact("core", "Kernel.sol", "Kernel")
    inner_creation(r, a, core["kernelFactory"], S["factory_input"], 1)
    runtime_check(r, a, code(r.addr), {"SELF": W(core["kernelImpl"])})

@check("Lens", core["lens"], "core", core["commit"])
def _(r):
    a = artifact("core", "Lens.sol", "Lens")
    creation_tx(r, a, tx_for(r.addr, core["txs"]), 1, [("factory", W(core["kernelFactory"]))])
    runtime_check(r, a, code(r.addr), {"FACTORY": W(core["kernelFactory"])})

# ---- the flagship kernel: an ERC-1167 clone with immutable args (OpenZeppelin Clones v5.7.0)
ENV_T = "(address,uint32,address,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,bool,address)"

@check("Kernel clone (flagship, chip 2)", flag["kernel"], "core", core["commit"])
def _(r):
    kf = core["kernelFactory"]
    oc = code(r.addr)
    PRE, POST = h2b("363d3d373d3d3d363d73"), h2b("5af43d82803e903d91602b57fd5bf3")
    r.note(f"runtime: {len(oc)} bytes on chain = 45-byte ERC-1167 proxy + {len(oc) - 45} bytes of immutable args")
    r.ok(oc[:10] == PRE and oc[30:45] == POST, "bytes 0..45 are OpenZeppelin's ERC-1167 minimal proxy")
    r.ok(same("0x" + oc[10:30].hex(), core["kernelImpl"]),
         f"proxy delegates to the Kernel implementation {core['kernelImpl']}")
    args = oc[45:]
    r.ok(len(args) == 32 * 32, "args are 32 words: abi.encode(Globals (18 static fields), Envelope (14 static fields))")
    gl = ["manager", "v2Router", "wokb", "factory", "circuits", "fab", "sealedVM", "beacon", "impl0", "impl0Hash",
          "snapshot", "netlistHash", "chipId", "nState", "gateCount", "netlistLen", "stepFloor", "sealedFloor"]
    G = S["globals"] = {k: args[i * 32:(i + 1) * 32] for i, k in enumerate(gl)}
    e = [args[(18 + i) * 32:(19 + i) * 32] for i in range(14)]
    for k in KF_PINS:  # read from the factory itself, so this check does not depend on the factory's row
        r.ok(G[k] == call(kf, sel(k + "()")), f"Globals.{k} = KernelFactory.{k}()")
    r.ok(G["factory"] == W(kf), "Globals.factory = the KernelFactory")
    chip = int.from_bytes(G["chipId"], "big")
    r.ok(chip == flag["chipId"], f"Globals.chipId = {chip}")
    ci = call(ev["fab"], sel("chipInfo(uint256)") + G["chipId"])
    r.ok(ci[0:32] == G["snapshot"] and ci[32:64] == G["netlistHash"] and ci[64:96] == G["nState"]
         and ci[96:128] == G["gateCount"], "Globals.snapshot, netlistHash, nState, gateCount = Fab.chipInfo(chipId)")
    r.ok(G["netlistHash"] == h2b(flag["netlistKeccak256"]), "Globals.netlistHash = deployments' netlistKeccak256")
    gc, ns = int.from_bytes(G["gateCount"], "big"), int.from_bytes(G["nState"], "big")
    r.ok(int.from_bytes(G["stepFloor"], "big") == 200_000 + 2_600 * gc + 800 * ns
         and int.from_bytes(G["sealedFloor"], "big") == 40_000 + 200 * (gc - ns) + 400 * ns,
         f"stepFloor and sealedFloor follow the factory's formulas for {gc} gates, {ns} latches")
    # the creation transaction: create(Envelope, chipId, salt) on the factory
    txh = flag["txs"][1]
    tx, rc = rpc("eth_getTransactionByHash", [txh]), rpc("eth_getTransactionReceipt", [txh])
    inp = h2b(tx["input"])
    r.ok(same(tx["to"], kf) and inp[:4] == sel("create(" + ENV_T + ",uint256,bytes32)") and rc["status"] == "0x1"
         and len(inp) == 4 + 16 * 32, f"creation tx {txh}: a successful KernelFactory.create")
    salt = inp[4 + 15 * 32: 4 + 16 * 32]
    r.ok([inp[4 + 32 * i: 36 + 32 * i] for i in range(14)] == e,
         "Envelope in the clone = the envelope the creation transaction passed")
    r.ok(inp[4 + 14 * 32: 4 + 15 * 32] == G["chipId"], "chipId in the clone = the transaction's chipId")
    el = ["launcher", "epochLen", "allowancePayee", "capT", "capV", "allowCumBps", "ceilMax", "relMax", "floorRel",
          "floorMin", "fallbackEpochs", "fbAllow", "buyEnabled", "sink"]
    r.note("envelope: " + ", ".join(
        f"{k}={addr_of(v) if k in ('launcher', 'allowancePayee', 'sink') else int.from_bytes(v, 'big')}"
        for k, v in zip(el, e)))
    r.ok(same(addr_of(e[2]), flag["allowancePayee"]), "envelope allowancePayee = deployments' allowancePayee")
    initcode = h2b("61") + len(oc).to_bytes(2, "big") + h2b("3d81600a3d39f3") + oc
    r.ok(same(create2_addr(kf, salt, initcode), r.addr),
         "CREATE2(factory, salt, OpenZeppelin's clone initcode + on-chain runtime) = this address")
    pred = call(kf, sel("predict(" + ENV_T + ",uint256,bytes32)") + inp[4:])
    r.ok(same(addr_of(pred), r.addr), "KernelFactory.predict(envelope, chipId, salt) returns this address today")
    r.ok(int.from_bytes(call(kf, sel("isKernel(address)") + W(r.addr)), "big") == 1,
         "KernelFactory.isKernel(this) is true")
    r.creation = "MATCH (CREATE2 address)" if not r.fail else "MISMATCH"
    r.runtime = "MATCH (proxy + args)" if not r.fail else "MISMATCH"

# ---- netlists: the bytes on chain against the committed netlist files
def committed(commit, path):
    import subprocess
    return h2b(subprocess.check_output(["git", "-C", ROOT, "show", f"{commit}:{path}"]).decode().strip())

def netlist_from_circuits(chip):
    """Circuits.netlist(chip) -> bytes (TapeOut's own copy, made by Circuits.tapeout)."""
    ret = call(iss["circuits"], sel("netlist(uint256)") + chip.to_bytes(32, "big"))
    n = int.from_bytes(ret[32:64], "big")
    return ret[64:64 + n]

def fab_snapshot_row(label, chip, commit, path, recorded_hash=None):
    @check(label, "?", "chips", commit)
    def _(r):
        r.ok(int.from_bytes(call(ev["fab"], sel("isChip(uint256)") + chip.to_bytes(32, "big")), "big") == 1,
             f"Fab.isChip({chip}) is true")
        ci = call(ev["fab"], sel("chipInfo(uint256)") + chip.to_bytes(32, "big"))
        r.addr, nh = addr_of(ci[0:32]), ci[32:64]
        sc = code(r.addr)
        want = committed(commit, path)
        r.ok(sc[:1] == b"\x00", "snapshot code starts with the STOP byte SSTORE2 prepends")
        r.ok(sc[1:] == want, f"snapshot bytes = {path} at commit {commit[:7]} ({len(want)} bytes)")
        r.ok(keccak(sc[1:]) == nh, f"keccak256(snapshot netlist) = Fab.chipInfo netlistHash 0x{nh.hex()}")
        if recorded_hash:
            r.ok(nh == h2b(recorded_hash), "netlistHash = the hash deployments/xlayer.json records")
        r.ok(netlist_from_circuits(chip) == want, f"Circuits.netlist({chip}), TapeOut's copy, is the same bytes")
        G = S.get("globals")
        if chip == flag["chipId"] and G:
            r.ok(G["snapshot"] == ci[0:32] and len(sc) - 1 == int.from_bytes(G["netlistLen"], "big"),
                 "the kernel clone's Globals.snapshot and netlistLen name this snapshot")
        r.creation = "n/a (written by Fab.tapeoutChip)"
        r.runtime = "MATCH (bytes = committed file)" if not r.fail else "MISMATCH"

@check("Chip 1 netlist, in Circuits (probe)", iss["circuits"], "chips", iss["commit"])
def _(r):
    want = committed(iss["commit"], "chips/probe/probe.hex")
    got = netlist_from_circuits(D["probe"]["circuitId"])
    r.ok(got == want, f"Circuits.netlist({D['probe']['circuitId']}) = chips/probe/probe.hex at commit "
         f"{iss['commit'][:7]} ({len(want)} bytes)")
    r.ok(keccak(got) == h2b(D["probe"]["netlistKeccak256"]), "keccak256 = the probe hash deployments/xlayer.json records")
    r.creation = "n/a (taped out through TapeOut's Circuits.tapeout)"
    r.runtime = "MATCH (bytes = committed file)" if not r.fail else "MISMATCH"

fab_snapshot_row("Chip 2 netlist, Fab snapshot (Flow Governor)", flag["chipId"], flag["commit"], "chips/out/fg.hex",
                 flag["netlistKeccak256"])
pre = D.get("prelaunch")
if pre:
    fab_snapshot_row("Chip 3 netlist, Fab snapshot (Glutton)", pre["gluttonChipId"], pre["commit"],
                     "chips/cells/glutton/glutton.hex")
    fab_snapshot_row("Chip 4 netlist, Fab snapshot (Glutton512)", pre["glutton512ChipId"], pre["commit"],
                     "chips/cells/glutton/glutton512.hex")

# ---- not built here: the processor, TapeOut's beacon proxies. Compared with another processor of the same factory
# (0x933F.../0x0F24..., a processor the evaluator's fork tests used as a stand-in, see contracts/evaluator/NOTES.md).
TAPEOUT_FACTORY = "0x1f09DAeFA827f02CBb40967cc91b259763760761"
for name, addr, other in [("Transistors (processor CVNT)", iss["transistors"], "0x0F243eD0f164C9693fe95ba7e678A7b2c799bF4B"),
                          ("Circuits (processor CVNT)", iss["circuits"], "0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a")]:
    r = Row(name, addr, "-", "-")
    r.unchecked.append("not Covenant source: TapeOut's CircuitFactory created it inside the Splitter's constructor, "
                       "from TapeOut's code (see contracts/vendor/tapeout-xlayer), so there is no Covenant build to compare")
    try:
        mine, theirs = code(addr), code(other)
        r.note(f"runtime keccak {keccak(mine).hex()}, {len(mine)} bytes")
        r.note(("same" if mine == theirs else "DIFFERENT") + f" runtime code as {other}, the matching contract of "
               "another processor of the same factory")
        r.note("EIP-1967 beacon slot: " + addr_of(h2b(rpc("eth_getStorageAt", [addr, BEACON_SLOT, "latest"]))))
        if "Circuits" in name:
            cpu = lambda a: int.from_bytes(call(TAPEOUT_FACTORY, sel("isCPU(address)") + W(a)), "big") == 1
            r.note(f"CircuitFactory.isCPU: this {cpu(addr)}, the other {cpu(other)}")
    except Exception as ex:
        r.note(f"informational reads failed: {ex}")
    r.creation = r.runtime = "not built here"
    rows.append(r)

# ---------------------------------------------------------------- report
for r in rows:
    print(f"\n== {r.name}  {r.addr}" + (f"  ({r.pkg} @ {r.commit[:7]})" if r.pkg != "-" else ""))
    for c in r.checks + r.fail:
        print("   " + c)
    for u in r.unchecked:
        print("   NOT CHECKED: " + u)

w = [max(len(x) for x in col) for col in zip(*[(r.name, r.addr, r.creation, r.runtime, r.verdict) for r in rows])]
hdr = ("Contract", "Address", "Creation code", "Runtime code", "Verdict")
w = [max(a, len(b)) for a, b in zip(w, hdr)]
line = lambda cells: "| " + " | ".join(c.ljust(n) for c, n in zip(cells, w)) + " |"
print("\n" + line(hdr))
print("|" + "|".join("-" * (n + 2) for n in w) + "|")
for r in rows:
    print(line((r.name, r.addr, r.creation, r.runtime, r.verdict)))
covenant = [r for r in rows if r.pkg != "-"]
bad = [r for r in covenant if r.verdict != "MATCH"]
print(f"\n{len(covenant) - len(bad)} of {len(covenant)} Covenant rows MATCH; "
      f"{sum(1 for r in rows if r.pkg == '-')} row(s) not built here (TapeOut's code).")
if JSON_OUT:
    json.dump([{"contract": r.name, "address": r.addr, "package": r.pkg, "commit": r.commit, "creation": r.creation,
                "runtime": r.runtime, "verdict": r.verdict, "checks": r.checks, "failures": r.fail,
                "unchecked": r.unchecked} for r in rows], open(JSON_OUT, "w"), indent=2)
    print(f"JSON written to {JSON_OUT}")
sys.exit(1 if bad else 0)
PY
