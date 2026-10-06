# Checking the deployed code

Two scripts let anyone check that what runs on X Layer (chain 196) is the source in this repository, and let the
team publish that source on the explorers. Both read the chain only; neither sends a transaction or reads a key.

| Script | What it does | Needs |
|---|---|---|
| `deploy/verify-bytecode.sh` | Rebuilds every Covenant contract from the commit `deployments/xlayer.json` records for it and compares it with the chain, byte for byte | git, Foundry 1.8+, python3 3.9+, network access to GitHub and an X Layer RPC |
| `deploy/verify-explorers.sh` | Runs the check above, then prepares the explorer submissions. Dry run by default; submits only with `--submit` and a typed confirmation | the same; an OKLink API key to submit to OKLink |

## 1. Reproducible build: `deploy/verify-bytecode.sh`

```sh
deploy/verify-bytecode.sh                  # prints a check list per contract, then the table below
deploy/verify-bytecode.sh --json out.json  # the same, also as JSON
XLAYER_RPC_URL=https://xlayerrpc.okx.com deploy/verify-bytecode.sh
```

How it works:

1. **Sources.** For each package it exports the commit recorded in `deployments/xlayer.json` with `git archive`
   into a scratch directory: `contracts/issuance` at `9e99885`, `contracts/evaluator` and `contracts/core` at
   `b54cb86`. The working tree, uncommitted changes and the local `contracts/*/lib` are not used.
2. **Libraries.** It clones the pinned release tags from GitHub and prints the commit each tag resolved to:
   forge-std `v1.17.0` (`f3dae6e6`), OpenZeppelin Contracts `v5.4.0` (`c64a1edb`) for issuance and `v5.7.0`
   (`cab19933`) for evaluator and core, as each package's README or NOTES pins them.
3. **Build.** `forge build src` with the commit's own `foundry.toml`: solc 0.8.28, `evm_version = "cancun"`,
   optimizer 200 runs, legacy pipeline. Any `FOUNDRY_*` variable in the caller's environment is cleared first.
4. **Compare**, with `eth_getCode`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_getStorageAt`
   and `eth_call`:
   - **Creation code.** For a contract the deployer created directly, the local creation bytecode must be the
     exact prefix of the creation transaction's input. The rest of the input must be exactly the constructor
     arguments, and each one must equal what `deployments/xlayer.json` and the broadcast record name. For a
     contract created inside a constructor (TeamRegistry and KeeperTank by the Splitter, the Kernel
     implementation by the KernelFactory), its address must be `CREATE(parent, nonce)` at the expected nonce,
     and its local creation code must appear inside the parent's on-chain creation code.
   - **Runtime code.** The on-chain code must equal the local `deployedBytecode` byte for byte, after the
     on-chain values are copied into the immutable slots the build lists (`immutableReferences`). Every reference
     to an immutable must hold the same value, and each value must be the one the constructor arguments require.
     For example, the Splitter's `TANK` must be the KeeperTank, and the Kernel implementation's `SELF` must be
     its own address. An immutable the script has no expected value for counts as a mismatch. The KernelFactory
     pins that only the broadcast record names are also tied to the chain: `beacon` must be the EIP-1967 beacon
     of Covenant's Circuits, `impl0Hash` the keccak-256 of `impl0`'s code, and `wokb` the router's `WETH()`.
   - **Metadata.** It is compared along with the rest of the code. Issuance and evaluator are built with
     solc's default IPFS metadata hash, so a MATCH there also means every source file the contract is compiled
     from, and every compiler setting, is identical. Core is built with `bytecode_hash = "none"`, so for core the match covers the
     compiled code, and the CBOR tail names only the compiler version.
   - **The flagship kernel** `0xB722…d356` is OpenZeppelin's ERC-1167 clone with immutable arguments (v5.7.0
     `Clones`). The script checks that the first 45 bytes are that proxy and that it delegates to the Kernel
     implementation. It decodes the appended `abi.encode(Globals, Envelope)` and compares it with the factory's
     pins, the Fab's chip record and the `create` transaction's envelope. It recomputes the CREATE2 address from
     the factory, the salt and the clone's initcode, and calls `predict` and `isKernel` on the factory.
   - **Netlists.** For chips 2, 3 and 4 the Fab's SSTORE2 snapshot must be `0x00` followed by the committed
     netlist file (`chips/out/fg.hex`, `chips/cells/glutton/glutton.hex`, `glutton512.hex` at the recorded
     commits). It must also hash to the Fab's `netlistHash` and equal TapeOut's own copy (`Circuits.netlist`).
     The probe, chip 1, must equal `chips/probe/probe.hex`.

The script exits 0 only when every Covenant row is a MATCH.

### Result on 2026-10-06

```
| Contract                                     | Address                                    | Creation code                                      | Runtime code                   | Verdict     |
|----------------------------------------------|--------------------------------------------|----------------------------------------------------|--------------------------------|-------------|
| Splitter                                     | 0xB87101F7426BA9175E0a944d3e763dC69B19867f | MATCH                                              | MATCH                          | MATCH       |
| TeamRegistry                                 | 0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| KeeperTank                                   | 0xb89BCe53822a99503A937C22974F1224D9Ab6352 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| SealedVM                                     | 0x19c248cf463c1e167121e52b77aba7ec68cbe47b | MATCH                                              | MATCH                          | MATCH       |
| Fab                                          | 0xdcac8c47af534dc0cde30f60056bce7d63a79afe | MATCH                                              | MATCH                          | MATCH       |
| KernelFactory                                | 0xaaa75144304cf81cc7cf513f434e00980d1803ad | MATCH                                              | MATCH                          | MATCH       |
| Kernel (implementation)                      | 0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| Lens                                         | 0xee63eb34f4b7a16a188d3d14075b9bb6a8aa5ea2 | MATCH                                              | MATCH                          | MATCH       |
| Kernel clone (flagship, chip 2)              | 0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356 | MATCH (CREATE2 address)                            | MATCH (proxy + args)           | MATCH       |
| Chip 1 netlist, in Circuits (probe)          | 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b | n/a (taped out through TapeOut's Circuits.tapeout) | MATCH (bytes = committed file) | MATCH       |
| Chip 2 netlist, Fab snapshot (Flow Governor) | 0x227ad858fe6462b21ca8cc4d5b3e72a3023e891f | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Chip 3 netlist, Fab snapshot (Glutton)       | 0x63d6c8c1ec1cfb5dbde6225ef10b1c7b717a516b | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Chip 4 netlist, Fab snapshot (Glutton512)    | 0x8e85694c5e2d02e97f0750f06b122ebc24e58aa0 | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Transistors (processor CVNT)                 | 0xC372dc307eFE4B551c866A79F582D692A373960A | not built here                                     | not built here                 | NOT CHECKED |
| Circuits (processor CVNT)                    | 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b | not built here                                     | not built here                 | NOT CHECKED |

13 of 13 Covenant rows MATCH; 2 row(s) not built here (TapeOut's code).
```

### What it does not show

- **The processor's Transistors and Circuits.** TapeOut's `CircuitFactory` created both inside the Splitter's
  constructor, from TapeOut's code, so this repository has no build to compare them with. The script only
  reports that their runtime code (295-byte beacon proxies) is identical to the matching contracts of another
  processor from the same factory, and which beacons they point to.
- **The compiler and the libraries are trusted as published.** Foundry fetches solc 0.8.28 through svm, and the
  libraries come from their GitHub release tags.
- **Netlists are compared with the committed files, not rebuilt from the RTL.** `make -C chips/rtl check`
  checks the committed Flow Governor bytes against the model and the proofs (see `chips/rtl/Makefile`).
- **A check that can fail.** With `DEPLOYMENTS=<copy with core.commit set to de6d4c4>` (an earlier core), the
  script reports KernelFactory and Lens as MISMATCH and exits 1. The Kernel implementation still matches,
  because `Kernel.sol` did not change between those commits.

## 2. Explorers for X Layer (checked 2026-10-06)

| Explorer | Can verify source | Key | Shows where | Evidence |
|---|---|---|---|---|
| **OKLink** (`www.oklink.com/x-layer`) | Yes. Foundry `--verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER`; OKX's Hardhat plugin `@okxweb3/hardhat-explorer-verify` posts to the same URL | **Yes**: an OKLink API key, according to OKX's X Layer verification guide, OKLink's API docs ("apply for OKLink API key") and Foundry's OKLink example. Not tried without one, because trying means submitting. A read-only status query (`action=checkverifystatus`) to the plugin URL gets the same answer with no key and with a made-up one, so only a submission would confirm the requirement | OKLink, and the OKX Wallet explorer below | Foundry 1.8.3 lists `oklink` as a verifier. The plugin's `ChainConfig.ts` maps chain 196 to that URL with `browserURL: https://www.oklink.com/xlayer`. chainid.network lists OKLink as the only explorer for chain 196 |
| **OKX Wallet explorer** (`web3.okx.com/explorer/x-layer`) | Not on its own: it shows OKLink's records | (OKLink's) | Same as OKLink | The page loads OKLink's front-end bundles (`oklink-nav`, `oklink-data.js`). Its contract endpoint returned the same verified record for the Uniswap V2 router `0x182a…0f59` as OKLink's read API (UniswapV2Router02, v0.6.6, 999,999 runs). For the Splitter it returns `verifyStatus: "unverified"`. `www.okx.com/web3/explorer/xlayer/...` redirects there |
| **Sourcify** | Yes. Chain 196 is `supported: true` in `https://sourcify.dev/server/chains`; `forge verify-contract --verifier sourcify --chain 196` | No | sourcify.dev and its API only. **Not on OKLink** | 7 of 8 contracts sampled from Sourcify's chain-196 list (verified between 2026-09-22 and 2026-10-06) are unverified on OKLink. The eighth was verified on both |
| Blockscout | No instance for chain 196 | n/a | n/a | Not in Blockscout's chain registry (`chains.blockscout.com/api/chains`, 646 entries). Not in chainid.network's explorer list for 196 |
| Etherscan (API v2) | No | n/a | n/a | `api.etherscan.io/v2/chainlist`: 63 chains, chain 196 is not one of them |

**Current status.** No Covenant contract is verified on any explorer yet. OKLink's read API
(`/api/v5/explorer/contract/verify-contract-info?chainShortName=XLAYER&contractAddress=…`, which answers without a
key) returns `data: []` for all eleven addresses: the eight contracts, the kernel clone, Transistors and Circuits.
The Uniswap V2 router, used as a control, returns its verified record. Sourcify's lookup returns no match for any
of the eight. Judges who follow the site's links land on OKLink, so OKLink is the verification that counts there.

## 3. Submitting: `deploy/verify-explorers.sh`

```sh
deploy/verify-explorers.sh                    # dry run: build, check, write packages, print the commands
deploy/verify-explorers.sh --status           # also print each address's OKLink and Sourcify status (read-only)
deploy/verify-explorers.sh --out DIR          # where the packages go (default: a new directory under $TMPDIR)
OKLINK_API_KEY=... deploy/verify-explorers.sh --submit oklink    # a person, at a terminal
deploy/verify-explorers.sh --submit sourcify                     # a person, at a terminal
```

1. It runs `deploy/verify-bytecode.sh` into a scratch build and stops unless every Covenant row is a MATCH.
   Nothing is prepared for code that does not reproduce.
2. For each of the eight contracts it writes three files:
   - `<Name>.standard-json.json`: the exact solc input forge submits (`forge verify-contract
     --show-standard-json-input`, with the verifier URL set to a closed local port so nothing is sent).
   - `<Name>.args.hex`: the constructor arguments. For a direct deployment they are cut from the creation
     transaction's input on chain. For TeamRegistry they are `abi.encode(deployer)`, what the Splitter's
     constructor passes.
   - `<Name>.cmd.txt`: the forge commands for OKLink and for Sourcify.
3. It compiles each standard-JSON input with solc 0.8.28 itself and requires the creation bytecode to equal the
   build that matched the chain, metadata included. On 2026-10-06 all eight passed. Each package was therefore
   known to reproduce the deployed bytes before anything was sent.
4. With `--submit oklink|sourcify` it asks on the terminal (`/dev/tty`) for the words `submit <target>`, then
   runs `forge verify-contract … --watch` for each contract. Without a terminal it refuses. The prompt stops
   accidental and non-interactive runs; it cannot tell a person from a program that drives a pseudo-terminal.
   The script has not been run with `--submit`.

Settings each OKLink submission carries: compiler `v0.8.28+commit.7893614a`, optimizer on with 200 runs,
`evm_version` cancun, no via-IR, the metadata setting of the package's `foundry.toml`, and the constructor
arguments below.

| Contract | Constructor arguments |
|---|---|
| Splitter | `(address factory, address maintainer, bytes20 commit)` = TapeOut CircuitFactory `0x1f09…0761`, deployer `0x84cE…E34D`, `9e9988576c1eb5ed1cb29c6b410444c368e3943e` |
| TeamRegistry | `(address founder)` = deployer |
| KeeperTank, SealedVM, Kernel | none |
| Fab | `(address circuits, address transistors)` = `0xaC90…EF0b`, `0xC372…960A` |
| KernelFactory | `(manager, v2Router, wokb, circuits, fab, sealedVM, beacon, impl0, impl0Hash)`, as in `contracts/core/broadcast/DeployCore.s.sol/196/run-latest.json` |
| Lens | `(address factory)` = KernelFactory |

Not submitted, by design:

- **The kernel clone.** It is OpenZeppelin's ERC-1167 proxy bytes followed by data, and has no Solidity source
  of its own. `verify-bytecode.sh` checks it. Whether OKLink labels it as a minimal proxy of the verified Kernel
  implementation has not been tested.
- **Transistors and Circuits.** They are TapeOut's code.

Not yet known, because only a submission shows it:

- Whether OKLink accepts the three contracts created inside a constructor (TeamRegistry, KeeperTank, Kernel).
  Their creation code appears only inside the parent's creation transaction.
- Whether Sourcify rates the core contracts `exact_match` or only `match`. With `bytecode_hash = "none"` there
  is no metadata hash to tie the sources to the bytecode.

## Credits

The checks rely on OpenZeppelin Contracts (MIT): `Clones` gives the kernel clone its layout,
`ReentrancyGuardTransient`, `Strings` and the receiver interfaces are compiled into the contracts.
forge-std (MIT/Apache-2.0) is installed because the packages pin it; no deployed contract uses it. TapeOut's sources (MIT, `contracts/vendor/tapeout-xlayer`) are
not built by these scripts. The keccak-256 inside `verify-bytecode.sh` is a plain implementation of the
Keccak-f[1600] permutation, checked against the empty-input test vector each time the script runs.
