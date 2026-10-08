# Checking the deployed code

Two scripts let anyone check that what runs on X Layer (chain 196) is the source in this repository, and let the
team publish that source on the explorers. Both read the chain only; neither sends a transaction or reads a key.

| Script | What it does | Needs |
|---|---|---|
| `deploy/verify-bytecode.sh` | Rebuilds every Covenant contract from the commit `deployments/xlayer.json` records for it and compares it with the chain, byte for byte | git, Foundry 1.8+, python3 3.9+, network access to GitHub and an X Layer RPC |
| `deploy/verify-explorers.sh` | Runs the check above, then prepares the explorer submissions. Dry run by default; submits only with `--submit` and a typed confirmation | the same; no key (section 2) |

## 1. Reproducible build: `deploy/verify-bytecode.sh`

```sh
deploy/verify-bytecode.sh                  # prints a check list per contract, then the table below
deploy/verify-bytecode.sh --json out.json  # the same, also as JSON
XLAYER_RPC_URL=https://xlayerrpc.okx.com deploy/verify-bytecode.sh
```

How it works:

1. **Sources.** For each package it exports the commit recorded in `deployments/xlayer.json` with `git archive`
   into a scratch directory: `contracts/issuance` at `9e99885`, `contracts/evaluator` and `contracts/core` at
   `b54cb86`, `contracts/core-v2` (kernel v2, USD₮0 quote) at `a9c3c22`. Kernel v2 compiles kernel v1's
   `KernelMath`, `TradeMath`, `SafeCall` and interfaces from `../core/src` (its `foundry.toml` remaps `core/`
   there), so `contracts/core` and `contracts/evaluator` are exported from `a9c3c22` too. `contracts/core/src` is
   the same at `b54cb86` and `a9c3c22`. The working tree, uncommitted changes and the local `contracts/*/lib` are
   not used. If a recorded commit does not contain the package, the package is not built and its rows fail.
2. **Libraries.** It clones the pinned release tags from GitHub and prints the commit each tag resolved to:
   forge-std `v1.17.0` (`f3dae6e6`), OpenZeppelin Contracts `v5.4.0` (`c64a1edb`) for issuance and `v5.7.0`
   (`cab19933`) for evaluator, core and core-v2, as each package's README or NOTES pins them. For core-v2 they
   go into `contracts/core/lib`, where its `foundry.toml` (`libs = ["../core/lib"]`) looks for them.
3. **Build.** `forge build src` with the commit's own `foundry.toml`: solc 0.8.28, `evm_version = "cancun"`,
   optimizer 200 runs, legacy pipeline. Any `FOUNDRY_*` variable in the caller's environment is cleared first.
4. **Compare**, with `eth_getCode`, `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_getStorageAt`
   and `eth_call`:
   - **Creation code.** For a contract the deployer created directly, the local creation bytecode must be the
     exact prefix of the creation transaction's input. The rest of the input must be exactly the constructor
     arguments, and each one must equal what `deployments/xlayer.json` and the broadcast record name. For a
     contract created inside a constructor (TeamRegistry and KeeperTank by the Splitter, the Kernel
     implementation by the KernelFactory, the KernelV2 implementation by the KernelFactoryV2), its address must
     be `CREATE(parent, nonce)` at the expected nonce, and its local creation code must appear inside the
     parent's on-chain creation code.
   - **Runtime code.** The on-chain code must equal the local `deployedBytecode` byte for byte, after the
     on-chain values are copied into the immutable slots the build lists (`immutableReferences`). Every reference
     to an immutable must hold the same value, and each value must be the one the constructor arguments require.
     For example, the Splitter's `TANK` must be the KeeperTank, and the Kernel implementation's `SELF` must be
     its own address. An immutable the script has no expected value for counts as a mismatch. The KernelFactory
     pins that only the broadcast record names are also tied to the chain: `beacon` must be the EIP-1967 beacon
     of Covenant's Circuits, `impl0Hash` the keccak-256 of `impl0`'s code, and `wokb` the router's `WETH()`.
     KernelFactoryV2 has ten constructor arguments (`manager, v2Router, quote, quoteShift, circuits, fab,
     sealedVM, beacon, impl0, impl0Hash`) and eleven immutables (those and `kernelImpl`). `quote` and
     `quoteShift` must be the USD₮0 address and the shift 33 that `deployments/xlayer.json` records, and `quote`
     must answer `decimals()` = 6. `beacon` and `impl0Hash` are tied to the chain as for v1, and `manager`,
     `v2Router`, `beacon`, `impl0` and `impl0Hash` must equal kernel v1's KernelFactory immutables. The script
     also prints the USD₮0/WOKB pool price the deploy script reads, at the block before the deployment and
     today, with the nearest whole shift (33 at both on 2026-10-06). That is information only: the shift is a
     deployment choice, not part of the code.
   - **Metadata.** It is compared along with the rest of the code. Issuance and evaluator are built with
     solc's default IPFS metadata hash, so a MATCH there also means every source file the contract is compiled
     from, and every compiler setting, is identical. Core and core-v2 are built with `bytecode_hash = "none"`, so
     for them the match covers the compiled code, and the CBOR tail names only the compiler version.
   - **The flagship kernel** `0xB722…d356` is OpenZeppelin's ERC-1167 clone with immutable arguments (v5.7.0
     `Clones`). The script checks that the first 45 bytes are that proxy and that it delegates to the Kernel
     implementation. It decodes the appended `abi.encode(Globals, Envelope)` and compares it with the factory's
     pins, the Fab's chip record and the `create` transaction's envelope. It recomputes the CREATE2 address from
     the factory, the salt and the clone's initcode, and calls `predict` and `isKernel` on the factory.
   - **The v2 flagship kernel** `0xd50A…dD75` is the same OpenZeppelin clone of the KernelV2 implementation
     `0x0d75…CAd5`, with 33 words of arguments: `abi.encode(GlobalsV2, Envelope)`, where `GlobalsV2` has 19
     fields (`quote` in place of `wokb`, and `quoteShift` last). The script checks the proxy bytes and the
     implementation, each of the ten pins against the KernelFactoryV2 getter of the same name, `factory`,
     `codeShift()` = 264, the chip record of chip 5 in the Fab, the `netlistHash` recorded for it, the
     `stepFloor` and `sealedFloor` formulas, and the envelope against the `create` transaction. The envelope must
     also equal `LaunchChipV2.referenceEnvelope(launcher, allowancePayee)` as committed at `a9c3c22`, with the
     deployer as launcher and the Architect agent wallet `0xbe50…6da0` as allowance payee. Then it checks the
     CREATE2 address, `predict` and `isKernel`, and that `Circuits.ownerOf(5)` is this kernel. It prints
     `token()`: `0x0` when this run was made on 2026-10-06. The kernel was bound to `ARCH` (`0x7F53…EEEE`) later
     that day, so the script prints that address now.
   - **Netlists.** For chips 2, 3, 4 and 5 the Fab's SSTORE2 snapshot must be `0x00` followed by the committed
     netlist file (`chips/out/fg.hex` for chips 2 and 5, `chips/cells/glutton/glutton.hex`, `glutton512.hex` at
     the recorded commits). It must also hash to the Fab's `netlistHash` and equal TapeOut's own copy
     (`Circuits.netlist`). For chips 2 and 5 the Fab's `manifestHash` must be the one `deployments/xlayer.json`
     records, and the snapshot must be the one the kernel clone's `Globals.snapshot` and `netlistLen` name. Chip
     5 is a second tape-out of the same Flow Governor bytes as chip 2, at its own snapshot address. The probe,
     chip 1, must equal `chips/probe/probe.hex`.

The script exits 0 only when every Covenant row is a MATCH.

### Result on 2026-10-06

```
| Contract                                         | Address                                    | Creation code                                      | Runtime code                   | Verdict     |
|--------------------------------------------------|--------------------------------------------|----------------------------------------------------|--------------------------------|-------------|
| Splitter                                         | 0xB87101F7426BA9175E0a944d3e763dC69B19867f | MATCH                                              | MATCH                          | MATCH       |
| TeamRegistry                                     | 0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| KeeperTank                                       | 0xb89BCe53822a99503A937C22974F1224D9Ab6352 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| SealedVM                                         | 0x19c248cf463c1e167121e52b77aba7ec68cbe47b | MATCH                                              | MATCH                          | MATCH       |
| Fab                                              | 0xdcac8c47af534dc0cde30f60056bce7d63a79afe | MATCH                                              | MATCH                          | MATCH       |
| KernelFactory                                    | 0xaaa75144304cf81cc7cf513f434e00980d1803ad | MATCH                                              | MATCH                          | MATCH       |
| Kernel (implementation)                          | 0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| Lens                                             | 0xee63eb34f4b7a16a188d3d14075b9bb6a8aa5ea2 | MATCH                                              | MATCH                          | MATCH       |
| Kernel clone (flagship, chip 2)                  | 0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356 | MATCH (CREATE2 address)                            | MATCH (proxy + args)           | MATCH       |
| KernelFactoryV2                                  | 0x231c0174ebb69789813f6ecb625b4626e69a82c1 | MATCH                                              | MATCH                          | MATCH       |
| KernelV2 (implementation)                        | 0x0d75d4c11e4770257b2bbf2d1E0Cb78f5B50CAd5 | MATCH (embedded in parent)                         | MATCH                          | MATCH       |
| LensV2                                           | 0x3ebe9e9cbc67d6a008c55d20294357521d28b049 | MATCH                                              | MATCH                          | MATCH       |
| Kernel clone v2 (flagship, chip 5)               | 0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75 | MATCH (CREATE2 address)                            | MATCH (proxy + args)           | MATCH       |
| Chip 1 netlist, in Circuits (probe)              | 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b | n/a (taped out through TapeOut's Circuits.tapeout) | MATCH (bytes = committed file) | MATCH       |
| Chip 2 netlist, Fab snapshot (Flow Governor)     | 0x227ad858fe6462b21ca8cc4d5b3e72a3023e891f | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Chip 3 netlist, Fab snapshot (Glutton)           | 0x63d6c8c1ec1cfb5dbde6225ef10b1c7b717a516b | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Chip 4 netlist, Fab snapshot (Glutton512)        | 0x8e85694c5e2d02e97f0750f06b122ebc24e58aa0 | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Chip 5 netlist, Fab snapshot (Flow Governor, v2) | 0x028b40499143334fa8fbf9d8670ae970a0aff573 | n/a (written by Fab.tapeoutChip)                   | MATCH (bytes = committed file) | MATCH       |
| Transistors (processor CVNT)                     | 0xC372dc307eFE4B551c866A79F582D692A373960A | not built here                                     | not built here                 | NOT CHECKED |
| Circuits (processor CVNT)                        | 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b | not built here                                     | not built here                 | NOT CHECKED |

18 of 18 Covenant rows MATCH; 2 row(s) not built here (TapeOut's code).
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
  because `Kernel.sol` did not change between those commits. For kernel v2, two runs on 2026-10-06, each exit 1
  with 15 of 18 rows MATCH:
  - `coreV2.commit` set to `b54cb86` (the v1 core commit, which has no `contracts/core-v2`): KernelFactoryV2,
    KernelV2 and LensV2 are MISMATCH ("contracts/core-v2 was not built").
  - `coreV2.commit` set to a commit made only in a scratch clone of this repository, identical to `a7a5403`
    except that `KernelMathV2.AMOUNT_MAX` is `type(uint128).max - 1`: KernelFactoryV2 is MISMATCH in its
    creation code (it embeds KernelV2's creation code; its runtime still matches), and KernelV2 and LensV2 are
    MISMATCH in both (runtime 20,969 and 15,628 bytes built against 20,900 and 15,590 on chain).

  In both runs the v2 kernel clone and chip 5 rows still match. They are checked against the chain and the
  committed files, not against the core-v2 build.
- **A commit is checked by its content.** No earlier commit has a different `contracts/core-v2`: the package
  was added in `35e31cc` and its sources have not changed since. A record naming `35e31cc` would therefore
  also MATCH. What a MATCH proves is that the sources at the recorded commit compile to the code on chain.
- **The kernel v2 clone's state is read today.** `Circuits.ownerOf(5)`, `predict` and `token()` are read at
  the latest block. The clone's code and arguments cannot change, but binding the kernel to a token later changes
  what `token()` returns.

## 2. Explorers for X Layer (checked 2026-10-06; sources published 2026-10-07)

| Explorer | Can verify source | Key | Shows where | Evidence |
|---|---|---|---|---|
| **OKLink** (`www.oklink.com/x-layer`) | Yes. Foundry `--verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER`; OKX's Hardhat plugin `@okxweb3/hardhat-explorer-verify` posts to the same URL | **No**, in practice. OKX's guide, OKLink's API docs ("apply for OKLink API key") and Foundry's example ask for one, but OKLink's account and API-key pages are gone (`/account/my-api` returns 404, and the site has no sign-in). On 2026-10-07 the plugin URL accepted and verified all eleven submissions sent with the placeholder key `none` | OKLink, and the OKX Wallet explorer below | Foundry 1.8.3 lists `oklink` as a verifier. The plugin's `ChainConfig.ts` maps chain 196 to that URL with `browserURL: https://www.oklink.com/xlayer`. chainid.network lists OKLink as the only explorer for chain 196 |
| **OKX Wallet explorer** (`web3.okx.com/explorer/x-layer`) | Not on its own: it shows OKLink's records | (OKLink's) | Same as OKLink | The page loads OKLink's front-end bundles (`oklink-nav`, `oklink-data.js`). Its contract endpoint returned the same verified record for the Uniswap V2 router `0x182a…0f59` as OKLink's read API (UniswapV2Router02, v0.6.6, 999,999 runs). For the Splitter it returns `verifyStatus: "unverified"`. `www.okx.com/web3/explorer/xlayer/...` redirects there |
| **Sourcify** | Yes. Chain 196 is `supported: true` in `https://sourcify.dev/server/chains`; `forge verify-contract --verifier sourcify --chain 196` | No | sourcify.dev and its API only. **Not on OKLink** | 7 of 8 contracts sampled from Sourcify's chain-196 list (verified between 2026-09-22 and 2026-10-06) are unverified on OKLink. The eighth was verified on both |
| Blockscout | No instance for chain 196 | n/a | n/a | Not in Blockscout's chain registry (`chains.blockscout.com/api/chains`, 646 entries). Not in chainid.network's explorer list for 196 |
| Etherscan (API v2) | No | n/a | n/a | `api.etherscan.io/v2/chainlist`: 63 chains, chain 196 is not one of them |

**Current status (2026-10-07).** All eleven Covenant contracts are verified on OKLink and on Sourcify. Before
the submissions, on 2026-10-06 and again on 2026-10-07, `deploy/verify-explorers.sh --status` reported "not verified"
on both for all eleven. After them, OKLink's read API (`/api/v5/explorer/contract/verify-contract-info?chainShortName=XLAYER&contractAddress=…`,
which answers without a key) returned each record with compiler `v0.8.28+commit.7893614a` and 200 optimizer runs.
It also lists both kernel clones as proxies (`proxy: 1`) whose implementation is the verified Kernel or KernelV2, so a
reader who opens a kernel's address on OKLink sees that implementation's source.

| Contract | Address | OKLink | Sourcify |
|---|---|---|---|
| Splitter | `0xB87101F7426BA9175E0a944d3e763dC69B19867f` | verified | exact_match |
| TeamRegistry | `0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699` | verified | exact_match |
| KeeperTank | `0xb89BCe53822a99503A937C22974F1224D9Ab6352` | verified | exact_match |
| SealedVM | `0x19c248cf463c1e167121e52b77aba7ec68cbe47b` | verified | exact_match |
| Fab | `0xdcac8c47af534dc0cde30f60056bce7d63a79afe` | verified | exact_match |
| KernelFactory | `0xaaa75144304cf81cc7cf513f434e00980d1803ad` | verified | match |
| Kernel (implementation) | `0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1` | verified | match |
| Lens | `0xee63eb34f4b7a16a188d3d14075b9bb6a8aa5ea2` | verified | match |
| KernelFactoryV2 | `0x231c0174ebb69789813f6ecb625b4626e69a82c1` | verified | match |
| KernelV2 (implementation) | `0x0d75d4c11e4770257b2bbf2d1E0Cb78f5B50CAd5` | verified | match |
| LensV2 | `0x3ebe9e9cbc67d6a008c55d20294357521d28b049` | verified | match |
| Kernel clone v1 (CVREF) | `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356` | proxy of Kernel | not submitted |
| Kernel clone v2 (ARCH) | `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75` | proxy of KernelV2 | not submitted |

Sourcify's `match` means the executable bytecode is identical and there is no metadata hash to compare: core and
core-v2 build with `bytecode_hash = "none"`. Resubmitting KernelFactory with its exact standard-JSON package changed
nothing ("already verified … didn't yield a better match"). Transistors and Circuits are TapeOut's code and were not
submitted.

## 3. Submitting: `deploy/verify-explorers.sh`

```sh
deploy/verify-explorers.sh                    # dry run: build, check, write packages, print the commands
deploy/verify-explorers.sh --status           # also print each address's OKLink and Sourcify status (read-only)
deploy/verify-explorers.sh --out DIR          # where the packages go (default: a new directory under $TMPDIR)
deploy/verify-explorers.sh --submit oklink                      # a person, at a terminal
deploy/verify-explorers.sh --submit sourcify                     # a person, at a terminal
```

1. It runs `deploy/verify-bytecode.sh` into a scratch build and stops unless every Covenant row is a MATCH.
   Nothing is prepared for code that does not reproduce.
2. For each of the eleven contracts (the eight above, and KernelFactoryV2, KernelV2 and LensV2) it writes three
   files:
   - `<Name>.standard-json.json`: the exact solc input forge submits (`forge verify-contract
     --show-standard-json-input`, with the verifier URL set to a closed local port so nothing is sent).
   - `<Name>.args.hex`: the constructor arguments. For a direct deployment they are cut from the creation
     transaction's input on chain. For TeamRegistry they are `abi.encode(deployer)`, what the Splitter's
     constructor passes.
   - `<Name>.cmd.txt`: the forge commands for OKLink and for Sourcify.
3. It compiles each standard-JSON input with solc 0.8.28 itself and requires the creation bytecode to equal the
   build that matched the chain, metadata included. On 2026-10-06 all eleven passed. Each package was therefore
   known to reproduce the deployed bytes before anything was sent.
4. With `--submit oklink|sourcify` it asks on the terminal (`/dev/tty`) for the words `submit <target>`, then
   runs `forge verify-contract … --watch` for each contract. Without a terminal it refuses. The prompt stops
   accidental and non-interactive runs; it cannot tell a person from a program that drives a pseudo-terminal.
   The 2026-10-07 submissions, made at the user's request, did not go through this prompt, because the session
   that sent them had no terminal. They ran the same forge commands as each package's `<Name>.cmd.txt` (OKLink
   with `--verifier-api-key none`, Sourcify with the creation transaction where the contract has its own), from a
   `deploy/verify-bytecode.sh --workdir` build in which every row was a MATCH.

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
| KernelFactoryV2 | `(manager, v2Router, quote, uint256 quoteShift, circuits, fab, sealedVM, beacon, impl0, impl0Hash)` = kernel v1's manager `0x96B5…C309` and router `0x182a…0f59`, USD₮0 `0x779D…3736`, `33`, Circuits, Fab, SealedVM, and kernel v1's beacon, `impl0` and `impl0Hash`, as in `contracts/core-v2/broadcast/DeployCoreV2.s.sol/196/run-latest.json` |
| KernelV2 | none |
| LensV2 | `(address factory)` = KernelFactoryV2 |

Not submitted, by design:

- **The two kernel clones** (v1 `0xB722…d356`, v2 `0xd50A…dD75`). Each is OpenZeppelin's ERC-1167 proxy bytes
  followed by data, and has no Solidity source of its own. `verify-bytecode.sh` checks them. OKLink lists each
  as a proxy of the verified implementation (section 2).
- **Transistors and Circuits.** They are TapeOut's code.

What the 2026-10-07 submissions showed:

- OKLink accepted the four contracts created inside a constructor (TeamRegistry, KeeperTank, Kernel, KernelV2)
  from the bytecode alone; no creation transaction was needed.
- OKLink and Sourcify both accepted core-v2's `../core/` source paths.
- Sourcify rates the core and core-v2 contracts `match`, not `exact_match`, as expected with `bytecode_hash = "none"`.

## Credits

The checks rely on OpenZeppelin Contracts (MIT): `Clones` gives both kernel clones their layout,
`ReentrancyGuardTransient`, `Strings` and the receiver interfaces are compiled into the contracts.
forge-std (MIT/Apache-2.0) is installed because the packages pin it; no deployed contract uses it. TapeOut's sources (MIT, `contracts/vendor/tapeout-xlayer`) are
not built by these scripts. The keccak-256 inside `verify-bytecode.sh` is a plain implementation of the
Keccak-f[1600] permutation, checked against the empty-input test vector each time the script runs.
