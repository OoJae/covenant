#!/usr/bin/env bash
# Source verification of Covenant's X Layer mainnet contracts on the explorers: prepared by default, submitted only
# when a person runs it with --submit and confirms on the terminal.
#
#   deploy/verify-explorers.sh                      dry run: build, check, write the packages, print the commands
#   deploy/verify-explorers.sh --status             also read each address's current status (OKLink, Sourcify)
#   deploy/verify-explorers.sh --out DIR            write the packages into DIR (default: a new directory in $TMPDIR)
#   deploy/verify-explorers.sh --only Fab,Lens      restrict to some contracts
#   OKLINK_API_KEY=... deploy/verify-explorers.sh --submit oklink     SUBMIT to OKLink (asks for confirmation)
#   deploy/verify-explorers.sh --submit sourcify                      SUBMIT to Sourcify (asks for confirmation)
#
# Every run first runs deploy/verify-bytecode.sh into a scratch build and stops unless every Covenant row is MATCH:
# nothing is prepared or submitted for code that does not reproduce. For each contract it then writes
#   <Name>.standard-json.json   the exact solc standard-JSON input forge submits (forge --show-standard-json-input)
#   <Name>.args.hex             the ABI-encoded constructor arguments (empty when there are none), taken from the
#                               creation transaction's input on chain, or for contracts created in a constructor,
#                               from what that constructor passes
#   <Name>.cmd.txt              the forge commands for OKLink and Sourcify, and the OKLink web-form settings
# and compiles the standard-JSON input with solc 0.8.28 itself: the creation bytecode must equal the build that
# matched the chain (byte for byte, metadata included), so the package is known to verify before it is sent.
#
# Explorers (see docs/VERIFY.md for the evidence):
#   OKLink    the explorer behind www.oklink.com/x-layer and web3.okx.com/explorer/x-layer; Foundry's
#             `--verifier oklink` against .../verify-source-code-plugin/XLAYER; needs an OKLink API key.
#   Sourcify  supports chain 196; no key. Its result shows on sourcify.dev, not on OKLink.
# There is no Blockscout instance and no Etherscan support for chain 196.
#
# Not submitted by this script: the flagship kernel clone (OpenZeppelin's ERC-1167 proxy with appended arguments;
# it has no Solidity source of its own, deploy/verify-bytecode.sh checks it), and the processor's Transistors and
# Circuits (TapeOut's code).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="${DEPLOYMENTS:-$ROOT/deployments/xlayer.json}"
RPC="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
OKLINK_URL="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER"
SOLC_LONG="v0.8.28+commit.7893614a"
SUBMIT=
STATUS=0
OUT=
ONLY=
while [ $# -gt 0 ]; do
  case "$1" in
    --submit) SUBMIT="$2"; shift ;;
    --status) STATUS=1 ;;
    --out) OUT="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --dry-run) ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "verify-explorers.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$SUBMIT" in
  ''|sourcify) ;;
  oklink) [ -n "${OKLINK_API_KEY:-}" ] || { echo "verify-explorers.sh: --submit oklink needs OKLINK_API_KEY" >&2; exit 2; } ;;
  *) echo "verify-explorers.sh: --submit takes oklink or sourcify" >&2; exit 2 ;;
esac
for tool in git forge cast python3; do
  command -v "$tool" >/dev/null || { echo "verify-explorers.sh: $tool is required" >&2; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/covenant-verify-explorers.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [ -z "$OUT" ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/covenant-verify-packages.XXXXXX"); fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# 1. The reproducible-build check, into a build this script then submits from.
echo "== deploy/verify-bytecode.sh"
if ! "$ROOT/deploy/verify-bytecode.sh" --workdir "$WORK/build" --json "$WORK/bytecode.json" >"$WORK/bytecode.log" 2>&1; then
  cat "$WORK/bytecode.log"
  echo "verify-explorers.sh: the bytecode check did not pass; nothing is prepared or submitted." >&2
  exit 1
fi
sed -n '/^| Contract/,$p' "$WORK/bytecode.log"

# 2. The contracts: name, package, source path, address, creation transaction (empty: created in a constructor),
#    constructor signature, and the source of its arguments.
python3 - "$LIVE" "$ROOT" >"$WORK/contracts.tsv" <<'PY'
import json, os, sys
D = json.load(open(sys.argv[1])); root = sys.argv[2]
iss, ev, core = D["issuance"], D["evaluator"], D["core"]
def bargs(pkg, script, name):
    p = os.path.join(root, "contracts", pkg, "broadcast", script, "196", "run-latest.json")
    return next(t.get("arguments") or [] for t in json.load(open(p))["transactions"]
                if t.get("transactionType") == "CREATE" and t.get("contractName") == name)
rows = [
    ("Splitter", "issuance", "src/Splitter.sol:Splitter", iss["splitter"], iss["splitterTx"], "constructor(address,address,bytes20)", "tx"),
    ("TeamRegistry", "issuance", "src/TeamRegistry.sol:TeamRegistry", iss["teamRegistry"], "", "constructor(address)", D["deployer"]),
    ("KeeperTank", "issuance", "src/KeeperTank.sol:KeeperTank", iss["keeperTank"], "", "", ""),
    ("SealedVM", "evaluator", "src/SealedVM.sol:SealedVM", ev["sealedVM"], ev["txs"][0], "", "tx"),
    ("Fab", "evaluator", "src/Fab.sol:Fab", ev["fab"], ev["txs"][1], "constructor(address,address)", "tx"),
    ("KernelFactory", "core", "src/KernelFactory.sol:KernelFactory", core["kernelFactory"], core["txs"][0],
     "constructor(address,address,address,address,address,address,address,address,bytes32)", "tx"),
    ("Kernel", "core", "src/Kernel.sol:Kernel", core["kernelImpl"], "", "", ""),
    ("Lens", "core", "src/Lens.sol:Lens", core["lens"], core["txs"][1], "constructor(address)", "tx"),
]
for r in rows:
    print("\t".join(x if x else "-" for x in r))
PY

SOLC=
for c in "$HOME/Library/Application Support/svm/0.8.28/solc-0.8.28" "$HOME/.svm/0.8.28/solc-0.8.28"; do
  [ -x "$c" ] && SOLC="$c" && break
done
[ -n "$SOLC" ] || { echo "verify-explorers.sh: solc 0.8.28 not found in Foundry's svm directory" >&2; exit 1; }

echo
echo "== packages in $OUT"
selected=()
while IFS=$'\t' read -r name pkg path addr tx sig argsrc; do
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
  selected+=("$name")
  proj="$WORK/build/$pkg/contracts/$pkg"
  file="${path%%:*}"; cname="${path##*:}"
  # constructor arguments
  args=""
  if [ "$sig" != "-" ]; then
    if [ "$argsrc" = "tx" ]; then
      args=$(python3 - "$RPC" "$tx" "$proj/out/$(basename "$file")/$cname.json" <<'PY'
import json, sys, urllib.request
rpc, tx, art = sys.argv[1:]
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionByHash", "params": [tx]}).encode()
inp = json.load(urllib.request.urlopen(urllib.request.Request(rpc, data=body, headers={"content-type": "application/json"}), timeout=60))["result"]["input"]
code = json.load(open(art))["bytecode"]["object"]
assert inp.startswith(code), "creation code is not a prefix of the transaction input"
print("0x" + inp[len(code):])
PY
)
    else
      args=$(cast abi-encode "$sig" "$argsrc")
    fi
  fi
  printf '%s' "$args" >"$OUT/$name.args.hex"
  # the standard-JSON input forge would submit (no network: the verifier URL is never contacted)
  if ! (cd "$proj" && forge verify-contract "$addr" "$path" --chain 196 --verifier oklink --verifier-url http://127.0.0.1:9/ \
     --compiler-version "$SOLC_LONG" --num-of-optimizations 200 --evm-version cancun --show-standard-json-input) \
     >"$OUT/$name.standard-json.json" 2>"$WORK/$name.forge.err"; then
    cat "$WORK/$name.forge.err" >&2; echo "verify-explorers.sh: forge could not produce the input for $name" >&2; exit 1
  fi
  # compile it with solc itself and compare with the build that matched the chain
  (cd "$proj" && "$SOLC" --standard-json --allow-paths . <"$OUT/$name.standard-json.json") >"$WORK/$name.solc.json"
  check=$(python3 - "$WORK/$name.solc.json" "$proj/out/$(basename "$file")/$cname.json" "$file" "$cname" <<'PY'
import json, sys
out, art, file, name = sys.argv[1:]
o = json.load(open(out))
errs = [e["formattedMessage"].splitlines()[0] for e in o.get("errors", []) if e["severity"] == "error"]
if errs:
    print("FAIL solc: " + errs[0]); sys.exit()
got = o["contracts"][file][name]["evm"]["bytecode"]["object"]
want = json.load(open(art))["bytecode"]["object"][2:]
meta = json.loads(o["contracts"][file][name]["metadata"])
s = meta["settings"]
print(("ok" if got == want else "FAIL") + f" standard JSON compiles to the matched build's creation code ({len(got) // 2} bytes);"
      f" solc {meta['compiler']['version']}, optimizer {s['optimizer']}, evm {s['evmVersion']},"
      f" bytecodeHash {s['metadata'].get('bytecodeHash', 'ipfs')}, viaIR {s.get('viaIR', False)}")
PY
)
  echo "  $name ($addr, $pkg): $check"
  case "$check" in ok*) ;; *) echo "verify-explorers.sh: the package for $name does not reproduce the build; stopping" >&2; exit 1 ;; esac
  {
    echo "# $name at $addr (contracts/$pkg, commit from deployments/xlayer.json); run inside contracts/$pkg at that commit"
    echo "# with the pinned libraries installed (deploy/verify-bytecode.sh --workdir DIR builds exactly that tree)."
    echo
    echo "# OKLink (shows on www.oklink.com/x-layer and web3.okx.com/explorer/x-layer). Needs OKLINK_API_KEY."
    echo "forge verify-contract $addr $path --chain 196 \\"
    echo "  --verifier oklink --verifier-url $OKLINK_URL --verifier-api-key \"\$OKLINK_API_KEY\" \\"
    echo "  --compiler-version $SOLC_LONG --num-of-optimizations 200 --evm-version cancun \\"
    [ -z "$args" ] || echo "  --constructor-args $args \\"
    echo "  --watch --retries 10 --delay 15"
    echo
    echo "# Sourcify (no key; shows on sourcify.dev, not on OKLink)."
    echo "forge verify-contract $addr $path --chain 196 --verifier sourcify \\"
    [ "$tx" = "-" ] || echo "  --creation-transaction-hash $tx \\"
    echo "  --watch"
    echo
    echo "# By hand on OKLink's verify-contract page, if it offers a standard-JSON-input option (not tried from here):"
    echo "#   compiler $SOLC_LONG, input file $name.standard-json.json, contract $path,"
    echo "#   constructor arguments (ABI-encoded, without 0x): ${args#0x}"
  } >"$OUT/$name.cmd.txt"
done <"$WORK/contracts.tsv"
[ ${#selected[@]} -gt 0 ] || { echo "verify-explorers.sh: --only matched no contract" >&2; exit 2; }

echo
echo "== commands (also in $OUT/<Name>.cmd.txt)"
for name in "${selected[@]}"; do echo; sed -n '/^# OKLink (/,/--watch --retries/p' "$OUT/$name.cmd.txt"; done

# 3. Optional: what the explorers say today (read-only GETs, no key).
if [ "$STATUS" = 1 ]; then
  echo
  echo "== current status (OKLink verify-contract-info, Sourcify v2 lookup)"
  python3 - "$WORK/contracts.tsv" "$ONLY" <<'PY'
import json, sys, time, urllib.error, urllib.request
only = [x for x in sys.argv[2].split(",") if x]
def get(u):
    try:
        return json.load(urllib.request.urlopen(urllib.request.Request(u, headers={"user-agent": "covenant-verify"}), timeout=30))
    except urllib.error.HTTPError as e:  # Sourcify answers 404 with a JSON body for an unverified address
        try:
            return json.loads(e.read())
        except Exception:
            return {"http": e.code}
for line in open(sys.argv[1]):
    name, _, _, addr = line.rstrip("\n").split("\t")[:4]
    if only and name not in only:
        continue
    for attempt in range(8):  # OKLink answers 50011 "Too Many Requests" after a few calls
        ok = get(f"https://www.oklink.com/api/v5/explorer/contract/verify-contract-info?chainShortName=XLAYER&contractAddress={addr}")
        if ok.get("code") != "50011":
            break
        time.sleep(13)
    sf = get(f"https://sourcify.dev/server/v2/contract/196/{addr}")
    okv = ("verified as " + ok["data"][0].get("contractName", "?")) if ok.get("data") else (
        "not verified" if ok.get("code") == "0" else f"answer {ok}")
    print(f"  {name:14} {addr}  OKLink: {okv:28} Sourcify: {sf.get('match') or 'not verified'}")
    time.sleep(13)
PY
fi

# 4. Submission: only with --submit, only after a person confirms on the terminal.
if [ -z "$SUBMIT" ]; then
  echo
  echo "Dry run: nothing was submitted. Packages are in $OUT."
  echo "To submit, a person runs: deploy/verify-explorers.sh --submit oklink   (with OKLINK_API_KEY set)"
  echo "                      or: deploy/verify-explorers.sh --submit sourcify"
  exit 0
fi
if ! (exec 3<>/dev/tty) 2>/dev/null; then
  echo "verify-explorers.sh: --submit asks for confirmation on a terminal, and there is none; nothing was submitted." >&2
  exit 2
fi
exec 3<>/dev/tty
printf '\nThis PUBLISHES the source of %d contract(s) (%s) to %s.\nType "submit %s" to continue: ' \
  "${#selected[@]}" "${selected[*]}" "$SUBMIT" "$SUBMIT" >&3
read -r answer <&3 || answer=
exec 3>&-
[ "$answer" = "submit $SUBMIT" ] || { echo "Not confirmed; nothing was submitted."; exit 1; }

failed=()
while IFS=$'\t' read -r name pkg path addr tx sig argsrc; do
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; then continue; fi
  proj="$WORK/build/$pkg/contracts/$pkg"
  args=$(cat "$OUT/$name.args.hex")
  cmd=(forge verify-contract "$addr" "$path" --chain 196)
  if [ "$SUBMIT" = oklink ]; then
    cmd+=(--verifier oklink --verifier-url "$OKLINK_URL" --verifier-api-key "$OKLINK_API_KEY"
          --compiler-version "$SOLC_LONG" --num-of-optimizations 200 --evm-version cancun --retries 10 --delay 15)
    [ -z "$args" ] || cmd+=(--constructor-args "$args")
  else
    cmd+=(--verifier sourcify)
    [ "$tx" = "-" ] || cmd+=(--creation-transaction-hash "$tx")
  fi
  echo; echo "== $name $addr -> $SUBMIT"
  (cd "$proj" && "${cmd[@]}" --watch) || failed+=("$name")
done <"$WORK/contracts.tsv"
echo
if [ ${#failed[@]} -gt 0 ]; then echo "Failed: ${failed[*]}"; exit 1; fi
echo "Submitted. Check with: deploy/verify-explorers.sh --status"
