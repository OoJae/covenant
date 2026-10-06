# launch-check: notes

The last check before a human signs the irreversible IGNIX launch of a Covenant token. Two commands, both given
the transaction the wallet is about to send (`--tx @tx.json`, the `eth_sendTransaction` parameters a page hook
captured, or `--from --to --value --data` as the popup shows them) and the deployment record
(`--deployment deployments/xlayer.json`, nested; the flat `deploy/rehearsal.json` also works). The day-of steps
are in `../README.md`.

While `deployments/xlayer.json` does not record signing session 2 (`evaluator`, `core`, `flagship`), both commands
refuse at once with `signing session 2 is not deployed yet: ... records no evaluator (...), core (...), flagship
(...)` and exit code 1: there is no kernel to check a launch against.

| File | Role |
|---|---|
| `launch-check.ts` | decodes the calldata, reads the chain at one block, prints one PASS / FAIL line per check |
| `simulate.ts` | runs the exact transaction on a fork in forge (`sim/`), then bind, an outsider's buy, one epoch, settle |
| `decode.ts` | createToken decoder / encoder and the platform's signed digest |
| `kernel-abi.ts` | the ONLY description of the kernel and KernelFactory ABI the tools use (both tools import it) |
| `deployment.ts` | reads a deployment file, nested (`deployments/xlayer.json`) or flat (`deploy/rehearsal.json`), and names the missing parts of session 2 |
| `checks.ts`, `chain.ts`, `args.ts` | the checks as pure functions, the chain reads, the arguments |
| `sim/` | Foundry project: `src/LaunchSim.sol` (the harness), `test/Live.t.sol` (what simulate.ts runs), `test/ReplayOB.t.sol` and `test/MockKernelLaunch.t.sol` (proofs of the harness) |
| `payto-check.ts` | read-only check of an address proposed as the Architect's x402 `PAY_TO`: only the deployment's v2 kernel, bound, quoting in USD₮0, passes; prints the off-chain conditions of `contracts/core-v2/NOTES.md` section 9, step 6 |
| `test/usdt0.test.ts` | the USD₮0 mode (kernel v2) offline: the choice of kernel, the deployment keys, the refusal matrix for the new quote |
| `test/rehearsal-v2.test.ts` | the USD₮0 mode against the real kernel v2 contracts on a fork (opt-in, `REHEARSE=1`; see "Kernel v2" below) |

## What launch-check checks

From the calldata (selector `0xef44bdf2`; layout of `contracts/probes/src/interfaces/IIgnix.sol`):
`to` is the IgnixManager proxy `0x96B5...C309`; the selector; the arguments decode the way Solidity decodes them and
are the canonical encoding (nothing hidden after them); template 3 (Directed); the vault recipient
(`abi.decode(vaultData, (address))`) is the kernel; quote native OKB; venue 1; curve fees 100 / 100; tax 300 / 300
bps (or the values of `--expected`); protection 8,640,000 s; `firstBuy` 0; `msg.value` equal to the listing fee
alone; anti-snipe off; no founder round. Name, ticker, metadata URI, graduation target, listing fee, salt, factory
argument and deadline are printed for the human (they become checks when `--expected` names them).

From the chain, all at one block: chain id 196; the deadline leaves at least 3 minutes, measured against the later
of the chain's clock and this machine's; the platform signature recovers to `IgnixManager.signer()` over the digest
of this calldata, this sender, this chain, `POOL_FEE()` and `LAUNCH_FACTORY()` (so a mis-copied byte or the wrong
wallet fails); the factory argument is `REGISTRY.factoryOf(templateId)`; launches are not paused; the kernel has
code, is not bound (`token() == 0`), its envelope's launcher is `--from`, it was created by the deployment's
KernelFactory (`isKernel`), its globals name the deployment's KernelFactory, Fab, SealedVM, the IgnixManager and the
deployment's Circuits; the Circuits is a TapeOut processor (`isCPU`) whose `transistors()` is the deployment's; the
kernel holds its chip (`Circuits.ownerOf(chipId) == kernel`), which is the deployment's chip.

With a deployment file that is 34 checks. A check that could not be performed is a FAIL, never a pass. Without
`--deployment` the KernelFactory is unknown, so the verdict cannot be PASS.

## What simulate checks

On a fork (forge `vm.createSelectFork`) of `--rpc` (default rpc.xlayer.tech; a local anvil fork works) at the latest
block, run at the later of the chain's and this machine's clock:
0. the kernel belongs to the deployment: `isKernel`, its globals (factory, IgnixManager, Circuits, Fab, SealedVM,
   chip), the Fab taped out its chip, it holds the chip NFT, envelope launcher == sender, buys enabled, and
   `Lens.preflight` ran the chip on both evaluators within the kernel's step gas with the same answer;
1. the launcher sends the exact calldata and value; it must succeed and return one address;
2. the Manager's `TokenCreated` event names that token, this creator and a vault; `vaultOf(token)` is that vault;
3. `vault.RECIPIENT()` is the kernel, `vault.TOKEN()` the token, the creator the launcher; nothing was bought
   (no `Trade` event, `sold == 0`, the launcher holds no token, the vault holds no tax); quote native; anti-snipe 0;
   no founder round;
4. `kernel.bind(token)` from an UNRELATED address succeeds (so the keeper can bind), and afterwards
   `KernelFactory.kernelOf(token)` is the kernel;
5. an unrelated address buys 1 OKB: the vault receives exactly `1 OKB * taxBuyBps / 10000`;
6. after warping to the next epoch, `settle()` from an unrelated address writes exactly one record whose epoch and
   time are the settled ones, whose flags do not say the claim failed, whose inflow is the tax that was in the vault;
   the vault paid the kernel its whole balance (`Claimed`), and the kernel's balance is before + claimed tax minus
   its own curve buy.

Any deviation stops the run with a `sim:` message. The full simulation requires `--deployment`;
`--skip-kernel-checks` (create only) is a harness self-test and never a pass (exit code 2).

## Kernel v2: the USD₮0 mode

Kernel v2 (`contracts/core-v2`, `chips/INTERFACE-V2.md`) binds only an IGNIX Directed token **quoted in USD₮0**
(`0x779Ded0c9e1022225f8E0630b35a9b54bE713736`). `deploy/launch-kernel-v2.sh` records it in `deployments/xlayer.json`
as `coreV2` (KernelFactoryV2, its KernelV2 implementation, LensV2, the quote and its 33-bit code shift) and
`flagshipV2` (the v2 chip and kernel); `deploy/rehearse-v2.sh` writes the same in the flat format (`kernelFactoryV2`,
`lensV2`, `kernelV2`, `chipIdV2`, `quoteV2`, `quoteShiftV2`).

**Which kernel a launch is checked against** (`chooseGeneration` in `args.ts`, the same in both commands): kernel v2
only when the launch's quote is USD₮0 (the expected-values file's `quote`, else the calldata's) **and** the deployment
file names a complete kernel v2. Anything else is checked against kernel v1, whose rule refuses every quote but native
OKB. So a USD₮0 launch can pass only against the deployment's v2 kernel, an OKB launch only against its v1 kernel, and
no other quote passes at all. The default kernel (`--kernel` absent) is that generation's flagship.

**What changes in the USD₮0 mode** (every other check is kernel v1's, unchanged):
- `quote is USD₮0 (the v2 kernel's quote asset)` replaces `quote is native OKB`;
- `msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0)` replaces `msg.value is the listing fee alone`: for an
  ERC-20 quote the Manager reverts `BadValue()` on any value and pulls `listingFee + firstBuy` with `transferFrom`
  (verified in the vendored `IgnixManager.createToken`); `firstBuy` must still be 0;
- `kernel was created by the Covenant KernelFactoryV2 (isKernel)`, and the kernel's globals (`GlobalsV2`, 19 words)
  must name the deployment's KernelFactoryV2, Fab, SealedVM and the IgnixManager;
- new: `kernel quotes in USD₮0 with the 33-bit code shift (globals().quote, globals().quoteShift)`;
- new: `launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager)` (a fee of 0 passes);
- amounts (first buy, listing fee, graduation target) are shown in USD₮0, 6 decimals.

`simulate.ts` runs the same steps on the fork with the v2 deployment: the kernel's GlobalsV2 (quote and shift must be
the deployment's), the vault and the curve quoted in USD₮0, an unrelated address buys 10 USD₮0 (credited with
`deal` on the fork; no team wallet pays or buys anything), and step 6 reads every balance in USD₮0, the vault's
`Claimed` event naming USD₮0 as the asset.

**Refusal matrix for the new quote, offline** (`test/usdt0.test.ts`, the CLI against a table chain with both kernels):

| Change to a good USD₮0 launch | launch-check FAIL lines |
|---|---|
| recipient = the v1 kernel | vault recipient is the kernel |
| an OKB launch to the v2 kernel | vault recipient is the kernel |
| another ERC-20 (WOKB) to the v2 kernel | vault recipient is the kernel; quote is native OKB (the zero address) |
| the deployment names no v2 kernel | quote is native OKB (the zero address) (its detail says a USD₮0 launch needs the v2 kernel) |
| msg.value 1 wei | msg.value is 0 (a USD₮0 launch pays its listing fee in USD₮0) |
| a first buy of 5 USD₮0 | firstBuy is 0 (no team buy) |
| listing fee 1 USD₮0, no allowance to the Manager | launcher can pay the USD₮0 listing fee (balance and allowance to the IgnixManager) |
| `--kernel` the v1 kernel (and recipient it) | kernel is the one the deployment names; isKernel (KernelFactoryV2); the globals checks NOT CHECKED |
| the v2 kernel's shift is 32, or its quote WOKB | kernel quotes in USD₮0 with the 33-bit code shift |
| the v2 kernel was not created by the KernelFactoryV2 | kernel was created by the Covenant KernelFactoryV2 (isKernel) |
| the v2 kernel is already bound | kernel is not bound yet (token() is the zero address) |
| the v2 kernel answers kernel v1's globals | the globals checks NOT CHECKED |
| the expected-values file pins OKB | vault recipient is the kernel; quote is native OKB (the zero address) |
| the expected-values file pins USD₮0, the deployment has no v2 kernel | refused before any check (exit code 2) |

**Against the real contracts on a fork** (`REHEARSE=1 node --test tools/launch-check/test/rehearsal-v2.test.ts`):
`deploy/rehearse-v2.sh` deploys KernelFactoryV2, LensV2 and the Flow Governor's v2 kernel on its own anvil fork (its
plan goes to a scratch file, never `deploy/rehearsal-v2.json`); with the platform signer replaced on that fork only,
both commands pass on a USD₮0 launch built for the deployer, with the flat plan and with `deployments/xlayer.json`
completed by `coreV2` and `flagshipV2`; the matrix above is refused against the real kernels, `simulate` included
where it can see the change; the launch is sent to the fork, an unrelated address binds, and both commands refuse it
afterwards. The same test then has the keeper (dry run) and the live KeeperTank settle the v2 kernel, and runs
`audit-team` on the fork (results in "Verified facts").

**PAY_TO.** `payto-check.ts` (below) checks, read-only, an address someone proposes as the Architect's `PAY_TO`:
it passes only for the deployment's v2 kernel once it is bound.

## What it cannot see

- **What the wallet actually sends.** Both commands check the data the human copies. If the wallet signs something
  other than what it displays, nothing here can tell. Copy the raw hex from the confirmation itself.
- **Changes between the check and the block that includes the transaction.** The IgnixManager is an upgradeable proxy
  whose owner can pause launches, rotate the signer or change behaviour at any time; the checks and the simulation
  describe the chain at the block they read.
- **The deployment file's honesty.** The addresses in it are trusted. Check them once against the receipts of the
  signing sessions. (The kernel's own globals must agree with the file, which catches a file that mixes deployments.)
- **The chip's behaviour over its life.** The simulation runs one settle; the Lens preflight runs one step on each
  evaluator. Proofs about the chip are elsewhere (`chips/`).
- **Name, ticker and metadata.** They are printed with invisible characters escaped, but only compared when
  `--expected` names them. The human compares them with what was typed.
- **The wallet popup itself.** The steps in `../README.md` for copying the hex data were not tried on the OKX
  Wallet extension; the field name differs between wallets.

## Verified facts

| Fact | Verified by |
|---|---|
| `0xef44bdf2` is `keccak256("createToken((string,string,string,bytes32,address,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint256,uint256,uint16,uint32,bytes32),uint16,bytes,uint64,address,uint8,uint64,bytes)")[0:4]` (checked when `decode.ts` loads). | `OFFLINE=1 node --test tools/launch-check/test/decode.test.ts` |
| The decoder reproduces the real OB launch (`contracts/probes/vendor-cache/tx-create-OB.json`, block 71,350,520) field for field, re-encodes it byte for byte, and its platform signature recovers to `IgnixManager.signer()`; the same holds for 144 real Directed launches. | `OFFLINE=1 node --test tools/launch-check/test/decode.test.ts`; against the live chain: `node --test tools/launch-check/test/live.test.ts` |
| Replaying the exact OB calldata on a fork of block 71,350,519 gives the real token `0x9955...eeee`, the real vault, the 10 logs of the real receipt byte for byte, and the real gas used (3,499,861). | `forge test --root tools/launch-check/sim --match-contract ReplayOB` (3 passed, 2026-10-06) |
| The harness accepts a correct launch through the live IgnixManager and refuses each bad one (recipient, first buy, anti-snipe, launcher, chip not held, bound kernel, no code, expired signature, wrong sender, wrong value, a kernel the deployment's factory did not create, a kernel that refuses the vault's payment). | `forge test --root tools/launch-check/sim --match-contract MockKernelLaunch` (18 passed, 2026-10-06) |
| IGNIX itself refuses a Directed launch with tax 0 / 0 (`BadValue()`), so the kernel's `BindCheck(6)` cannot be reached through IGNIX. | `forge test --root tools/launch-check/sim --match-test without_tax` |
| The platform signer is `0x6EFa1Fad18900B929Fe6782fd3eaBeac2563416A`, stored in slot 5 of the proxy; `POOL_FEE()` = 3000; `LAUNCH_FACTORY()` = `0x5Fe101CaED11883eE133eb3Ffd013F0CD27Bb9D3`; `REGISTRY()` = `0xCE65471A6c6950e17f4B527b20b0aF8a8f905311`, whose `factoryOf(3)` is `0x48509800895d5735fDC93367aE925579eeFF24aE`. | `cast storage 0x96b51c57e5346d0c0198899243cf851d1e23c309 5`, `cast call ... "signer()(address)"` etc. on https://rpc.xlayer.tech, 2026-10-06 (block 72,516,574) |
| IGNIX's OB launch was mined 1,795 s before the deadline it was signed with: the platform's signature window is about 30 minutes. | decode the fixture: `deadline - block.timestamp` of `test/fixtures/ob-launch.json` |
| The struct layouts and every function signature in `kernel-abi.ts` match `chips/INTERFACE.md` (revision 2), `contracts/core/src/interfaces/IKernelV1.sol`, `IKernelExt.sol`, `KernelFactory.sol` and the copies in `sim/src/Interfaces.sol` (Envelope 14 fields; Record 14 fields ending in `nativeIn`; Globals 18 fields ending in `stepFloor`, `sealedFloor`); the step gas formulas equal the factory's constants. | `OFFLINE=1 node --test tools/launch-check/test/kernel-abi.test.ts` |
| With the live record: `deployments/xlayer.json` at 12:43 UTC on 2026-10-06 (evaluator and core recorded, flagship not yet), both commands refuse at once: `signing session 2 is not deployed yet: ... records no flagship (the flagship chip and its kernel)`, exit code 1. | `node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json --tx @tx.json` and the same with `simulate.ts` |
| Against the MAINNET SealedVM, Fab, KernelFactory and Lens (a fork taken after the user deployed them; `deploy/rehearse.sh` rehearsed only the flagship: chip 2, kernel `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356`): launch-check passes 34 of 34 with the flat rehearsal file and with `deployments/xlayer.json` completed by the rehearsed flagship (`--tx @tx.json`); simulate passes; the refusal matrix below holds; audit-team on the fork is CLEAN (13 transactions of the deployer, the TeamRegistry's entry 0 is the deployer). | `REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts` (2026-10-06, 130 s) |
| Against the REAL contracts deployed by `deploy/rehearse.sh` on a local fork (commit 9e99885, fork of block 72,518,527; kernel `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356`, chip 2: 1,952 gates, 64 latches, step gas 5,326,400 and 443,200): launch-check passes 34 of 34 checks; simulate passes (Lens preflight: TapeOut 4,496,308 gas of 5,326,400, sealed 326,054 of 443,200; createToken 3,423,480 gas; the first settle took the 0.03 OKB of tax as inflow, credited 0.00375 OKB of allowance and bought for 0.01875 OKB, flags 0); every corrupted field is refused; the transaction sent to the fork creates the token simulate predicted; an unrelated address binds; both commands then refuse. | `REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts` (2026-10-06; transcript written to `$REHEARSAL_TRANSCRIPT`) |

## The rehearsal test

`test/rehearsal.test.ts` (opt-in: `REHEARSE=1`) runs `deploy/rehearse.sh`, which works in its own scratch copy of
the contracts (it never touches `contracts/*/broadcast`, where the real mainnet records are committed), rehearses on
its own anvil fork whatever `deployments/xlayer.json` does not already record on chain (today: evaluator, core,
flagship), and writes `deploy/rehearsal.json`; the test restores that file afterwards, because
`deploy/launch-kernel.sh` reads it as its plan. `test/rehearsal/anvil` is put first on PATH so that the anvil node
rehearse.sh starts outlives the script (rehearse.sh kills the wrapper, not the node); the test then uses that same
fork, on its own free port, and kills the node at the end. On the fork only, it replaces the platform signer
(slot 5 of the Manager, as `contracts/probes/test/ProbeBase.sol` does) with a throwaway test signer, builds the
calldata for the deployer (the rehearsal kernel's launcher), and runs: launch-check with the flat rehearsal file;
launch-check and simulate with `deployments/xlayer.json` completed by the rehearsed session 2 and the transaction as
`--tx @tx.json`; launch-check with the real `deployments/xlayer.json` (refused while session 2 is absent); the
refusal matrix below; the transaction on the fork; a bind by an unrelated address; both commands again (refused);
and `audit-team` against the fork with the deployment file.

Refusal matrix (each field corrupted alone; "re-signed": the test platform signs the corrupted launch, as ignix.bot
would sign what its form was given):

| Corrupted field | launch-check FAIL lines | simulate |
|---|---|---|
| `to`: the router instead of the Manager | to is the IgnixManager proxy; platform signature | not run |
| selector: buyTo instead of createToken | function selector; calldata decodes; and 15 dependent checks NOT CHECKED | not run |
| templateId 0 (re-signed) | templateId is 3; vault factory argument is the registered template factory | not run |
| vault recipient: the deployer (re-signed) | vault recipient is the kernel | sim: the vault RECIPIENT is not the kernel |
| quote: an ERC-20 (re-signed) | quote is native OKB | not run |
| venue 0 (re-signed) | venue is 1 | not run |
| curve fees 50 / 100 (re-signed) | curve fees are 100 / 100 bps | not run |
| tax 100 / 100 (re-signed) | buy tax and sell tax are the expected values | not run |
| protection 1 day (re-signed) | protection period is the expected value | not run |
| firstBuy 0.4 OKB, value 0.4 OKB (re-signed) | firstBuy is 0; msg.value is the listing fee alone | sim: tokens were sold inside createToken (a first buy) |
| value 1 wei above the listing fee | msg.value is the listing fee alone | not run |
| anti-snipe 50 % for 30 min (re-signed) | anti-snipe is off | sim: anti-snipe is on (the kernel skips buys while it is) |
| founder round (re-signed) | no founder round | sim: a founder round is open |
| deadline 2 minutes away (re-signed) | signature deadline has at least 3 minutes left | not run |
| one byte of the salt mis-copied | platform signature is valid for this launcher and this calldata | not run |
| 3 extra bytes after the arguments | calldata carries nothing beyond its arguments | not run |
| `--from`: another wallet (re-signed for it) | kernel's envelope launcher is --from | sim: the kernel's envelope launcher is not the sender of createToken |
| `--from`: another wallet with the deployer's signature | platform signature; kernel's envelope launcher is --from | not run |
| `--kernel`: the Fab (a contract, not a kernel) | vault recipient; kernel is the one the deployment names; isKernel; and 8 kernel checks NOT CHECKED | refused before forge (exit code 2) |
| the same good transaction after it was mined and bound | kernel is not bound yet | sim: createToken reverted (the token already exists) |

Tests: `OFFLINE=1 node --test tools/launch-check/test/*.test.ts` (offline), without `OFFLINE` they also read
X Layer and run forge; `forge test --root tools/launch-check/sim` (forks X Layer).
