# Web and packages: notes

Scope: `packages/tap20`, `packages/chain`, `packages/dieshot`, `web`. Written 2026-10-04; kernel pages, judge guide, trust model and design pass added 2026-10-06; kernel v2 (USD₮0 quote) support added 2026-10-06 (section 3.6).
Everything here reads X Layer mainnet (chain 196) with `eth_call` only. Nothing sends a transaction, holds a key or loads a wallet library.

## 1. What exists

| Path | What it is |
|---|---|
| `packages/tap20` | TAP-20 parser, well-formedness check (section 3), one-beat simulator, LSB-first bit packing, REF support (sync resolver, plus `load()` that fetches a REF closure asynchronously). No runtime dependencies. |
| `packages/chain` | JSON-RPC client over `fetch` (failover, batches of at most 10), hand-written ABI codec for the TapeOut read calls and Multicall3 `aggregate3`, typed call descriptors, `readAll` (many calls in one request). keccak256 and EIP-55 in a separate entry, `@covenant/chain/keccak`. Covenant's own read surface (Kernel, KernelFactory, Lens, Fab, IGNIX Manager/vault/token, TeamRegistry, Safe owners, Multicall3 timestamp and balance; kernel v2's `RecordV2`/`GlobalsV2`, `quote()`, `quoteShift()`, the KernelFactoryV2 pins, ERC-20 `allowance`, USD₮0 `isBlocked`) in a third entry, `@covenant/chain/kernel`. No runtime dependencies. |
| `packages/dieshot` | Deterministic floorplan (`layout`, `layoutHash`), optional block map packed by a squarified treemap (`decodeBlockMap`), Canvas 2D renderer with `animate(previousSignals, signals, stateBefore, stateAfter)`. No runtime dependencies. |
| `web` | Vite + Preact + TypeScript site, hash routes: `#/`, `#/p/:processor`, `#/c/:processor/:id`, `#/k/:kernel` (vault), `#/k/:kernel/:n` (audit one settle), `#/hostile`, `#/judge`, `#/trust`. Only runtime dependency: `preact`. |

The three packages are consumed as TypeScript source (`exports` point at `src/index.ts`; relative imports carry the `.ts` extension). Vite, vitest and plain `node file.ts` (Node 26 strips types) all run them without a build step. The code uses erasable syntax only (no enums, no parameter properties), which `tsc` enforces.

Files worth knowing in `web/`:

- `src/config.ts`: every Covenant address comes from `../deployments/xlayer.json` (written by the deploy scripts after reading each contract back from the chain), so a contract appears on the site the moment that file names it. `COVENANT` holds them (null until deployed), including kernel v2's `kernelFactoryV2`, `kernelImplV2`, `lensV2` (from `.coreV2`), `chipIdV2`, `kernelV2` (from `.flagshipV2`) and the Architect's recorded `architectPayTo` (from `.architect.payTo`); `ADDR` keeps the old shape for the circuit reader.
- `vite.config.ts`: a small plugin drops the `.site` section of `deployments/xlayer.json` from the bundle (section 3.6). With `COVENANT_FORK` set at build or dev time, the fork fixture's file replaces it, the fork's RPC replaces the public endpoints, and `SIMULATION` is non-null (every page then shows a SIMULATION banner).
- `src/addresses.json`: only what is not a deployment: `{factory, rpc, gluttonChipId}` (a test checks the keys). `gluttonChipId` stays null unless a Glutton is taped out on mainnet next to the flagship chip; it switches the hostile page's on-chain shadow run on.
- `src/kernel/model.ts`: the kernel's arithmetic in TypeScript (lg8/exp8, word layouts, the routing with clamps K1T..K5, the fallback word), and kernel v2's code shift (`lg8s`, `exp8s`, `route(..., shift)`, `minAmountForCode`). A port of `chips/golden/kernel_model.py` and `kernel_model_v2.py`; passes every vector of `chips/golden/vectors.json` and `vectors_v2.json`, and every settle of `vectors_v2_settles.jsonl`.
- `src/kernel/chip.ts`: what an output word means in human terms; the Flow Governor's state fields, modes and flags (copied from `chips/out/fg.fields.json`, a test checks the copy); `chips/out/fg.witness.json` (imported).
- `src/kernel/sim.ts` (on demand): `chips/out/fg.hex` and the two Glutton netlists bundled and stepped by `@covenant/tap20`; `shadowRun` ports `Lens._shadowOne`.
- `src/kernel/code.ts`: what a browser can prove from `eth_getCode`: the kernel is an ERC-1167 clone with immutable arguments; a scan of the implementation for DELEGATECALL/CALLCODE/SELFDESTRUCT and owner/upgrade/pause/approve/transfer selectors.
- `src/data/kernel.ts`: the kernel pages' data path, with no DOM (`detectKernel`, `loadVault`, `loadRecords`, `loadCounterfactual`, `loadNetlist`, `loadAudit`, `loadShadowChip`). Pages, `scripts/verify-kernel.ts`, `test/fork.test.ts` call the same functions. `kindOf` tells kernel v1 from kernel v2 (section 3.6).
- `src/components/TwoStates.tsx`: the landing page's demonstration (same inputs, two reachable states, two routes).
- `src/routes/Vault.tsx`, `Audit.tsx`, `Hostile.tsx` (on demand, one chunk); `Judge.tsx`, `Trust.tsx` (on demand, another chunk).
- `src/data/processor.ts`, `src/data/circuit.ts`, `src/routes/Circuit.tsx`: the circuit reader, unchanged in substance.
- `scripts/check-budget.mjs`: fails the build if the output breaks the size budget or is not self-contained. Now also counts every script the entry imports statically (see 3.5).
- `scripts/verify-live.ts`: the circuit reader from a terminal. `scripts/verify-kernel.ts`: the landing demonstration and every record of a kernel, four ways, from a terminal.
- `scripts/fork-fixture.sh`: the local fork with a kernel v1 and a kernel v2 that have records (section 2).

## 2. How to run

From the repository root, after `pnpm install` has been run once:

```
pnpm --filter web dev                  # http://localhost:5173
pnpm --filter web build                # typecheck, vite build, budget check; output in web/dist
pnpm --filter web test                 # 69 tests: 49 offline, 10 live against X Layer, 10 against the fork fixture (skipped unless COVENANT_FORK is set)
pnpm --filter web test:offline         # SKIP_LIVE=1
pnpm --filter web verify:live          # node scripts/verify-live.ts; prints MATCH per beat
pnpm --filter web verify:live -- 0xProcessor 3     # one circuit of your choice

pnpm --filter @covenant/tap20 test     # 67 tests, 11 live
pnpm --filter @covenant/chain test     # 100 tests, 11 live
pnpm --filter @covenant/chain size     # minified sizes, fails above the ceiling
pnpm --filter @covenant/dieshot test   # 42 tests, none need the network
# all four at once, no network
pnpm --filter @covenant/tap20 --filter @covenant/chain --filter @covenant/dieshot --filter web test:offline
pnpm --filter @covenant/tap20 --filter @covenant/chain --filter @covenant/dieshot --filter web typecheck
```

(`--filter "@covenant/*"` also matches the services, which share the scope.)

Kernel pages:

```
pnpm --filter web verify:kernel                   # node scripts/verify-kernel.ts: two-state demo on chip #2 + every record, MATCH or MISMATCH
pnpm --filter web verify:kernel -- 0xKernel        # another kernel of the same factory

web/scripts/fork-fixture.sh                        # build the fork fixture, kernel v1 and kernel v2 (about 15 minutes); anvil keeps running
V2=0 web/scripts/fork-fixture.sh                   # kernel v1 only, as before (EPOCHS, EPOCHS_V2, GRAD_EPOCHS_V2 set the epochs)
pnpm --filter web dev:fork                         # the site against it (COVENANT_FORK=web/.fork/deployment.json), SIMULATION banner on
pnpm --filter web test:fork                        # the data path against it: every record four ways, shadow run vs Lens, counterfactual
web/scripts/fork-fixture.sh stop                   # stop its anvil
```

The fork fixture: anvil forks X Layer at the latest block on a free port (refuses a port that already answers, and checks its own anvil process is alive); runs the signing steps that `deployments/xlayer.json` does not record yet (`forge script ... --unlocked` from the deployer, impersonated, in a scratch copy of `contracts/`; nothing under `contracts/` or `deploy/` is written, and no `broadcast/` folder of the repository is touched); tapes out the Glutton through the Fab from an unrelated address; makes a Directed launch whose recipient is the kernel, sent from the deployer (the envelope's launcher), first buy 0, tax 3% / 3%, with IGNIX's platform signer replaced on the fork by the keyless method of 3.6; binds from an unrelated address; then 12 epochs of buys (and some sells) by anvil test accounts with a two-epoch surge, a quiet spell and one skipped epoch, each closed by `settle()` from an unrelated address.

Then kernel v2 (USD₮0 quote), unless `V2=0`: `contracts/core-v2`'s `DeployCoreV2` (KernelFactoryV2 + LensV2; its price-band check reads the live V3 pool on the fork) and `LaunchChipV2` (the Flow Governor taped out again, a v2 kernel with the reference envelope, the chip moved to it; allowance payee an unrelated test account, since the KeeperTank cannot move USD₮0), from the deployer impersonated in the same scratch copy, unless the deployment file records them; a Directed launch quoted in USD₮0 (graduation 8,000 USD₮0) with the v2 kernel as recipient; bind; 12 curve epochs of USD₮0 buys and sells by test accounts plus $0.50 revenue payments to the kernel from an unrelated account (plain USD₮0 transfers, as an x402 settlement amounts to on chain); then an unrelated whale buys the rest of the curve, the token graduates to its token/USD₮0 pair, and 3 more epochs of pair trades and revenue payments are settled (the quote leg buys the token with that revenue and burns it). USD₮0 comes from `anvil_dealERC20` (or, failing that, from the V3 pool, impersonated). The fixture checks that the v2 kernel leaves no USD₮0 allowance to the Manager or the router.

It writes `web/.fork/deployment.json` (git-ignored): the deployment file's shape without `.site`, plus `fork: {rpc, block, token, records, v2: {token, records, graduatedAt}}`, `glutton: {chipId}`, and the v2 keys the deployment file will gain, `coreV2: {kernelFactory, kernelImpl, lens}` and `flagshipV2: {chipId, kernel}`. A fork build cannot be published by accident: `check-budget.mjs` rejects its RPC host.

## 3. Decisions

### 3.1 tap20

- `parse(bytes, nIn, nOut, resolve?)` makes two passes: the first checks opcodes and record lengths and counts records, and only then are typed arrays allocated (TAP-20 section 7.2: no allocation from an unvalidated count).
- A netlist is typed arrays: `op`, `a`, `b`, `out` (first signal of each record), `stateBase`, `latches`, plus `refs[]`. For a REF record, `b[e]` indexes `refs`.
- Errors are `Tap20Error` with a `code` per condition of section 3 (`bad-opcode`, `truncated`, `pins`, `too-few-signals`, `future-signal`, `latch-range`, `ref-unresolved`, `ref-arity`, `ref-size`, `size-overflow`, `too-many-signals`) and `limit` for caller-set bounds.
- `step(netlist, state, inputs)` takes and returns packed bytes exactly as `Circuits.step` does, and also returns `signals` (one byte per top-level signal) for the animation. `stepBits` is the same on unpacked bits. `evaluate` mirrors `eval` and refuses a circuit with state.
- State and inputs are read leniently, as section 5 requires: missing bytes are 0, extra bytes and padding bits are ignored. Outputs and new state are canonical.
- Section 7.1 bounds: evaluation refuses more than 4,194,304 gates or REF depth above 16 unless the caller raises the limits; `load()` also bounds the number of circuits fetched (256).
- A REF sub-circuit is simulated by recursion on its block of state. Its inner signals are not part of the top-level `signals`.

### 3.2 chain

- Calls are descriptors `{to, data, decode}` built by `factory(addr)`, `processor(addr)`, `transistors(addr)`, `blockNumber()`. `read(rpc, call)` is one direct `eth_call`; `readAll(rpc, calls)` packs them into Multicall3 `aggregate3` with `allowFailure`, 100 sub-calls per `eth_call`, at most 10 `eth_call`s per HTTP request. A failing sub-call comes back as an `Error` in its own slot.
- The cross-check on the circuit page uses `read` (a direct call to the processor), so the printed `cast call` asks exactly the same question.
- Failover: an HTTP request tries each endpoint in turn starting with the last one that answered, then goes round once more after 300 ms. It fails over on a network error, a timeout (20 s), a non-2xx status, a body that is not JSON, or a single error object in reply to a batch. A revert is final and is never retried. A node-side error on one call of a batch is retried once on the next endpoint, for that call only.
- Requests carry no `content-type` header, so the browser sends them as `text/plain` without a CORS preflight. Both endpoints answer that exactly as they answer `application/json` (checked with curl). An endpoint that returns a non-2xx status is asked again with `application/json` and from then on only that way. Reason: neither endpoint sets a preflight max-age, so every call would otherwise cost two round trips and two units of the rate limit. Confirmed in the browser's network log: only POSTs, no OPTIONS.
- Selectors are literals next to their signatures; `src/signatures.ts` lists them all and the tests recompute each with viem and with our own keccak.
- viem is a devDependency used only as a test oracle. It is not imported by any source file.

### 3.3 dieshot

- Levels: constants, inputs and LATCH outputs are 0; a NAND is 1 + max of its inputs; a REF is 1 + max of its inputs for every signal it produces.
- Logic area: rows `h` = least integer with `h*h*68 >= cells*50` (3,400 cells give 50 rows; the core is then 69 x 50: 67 columns of logic and 2 of register strip). Logic cells are sorted by (level, record index) with a stable counting sort and fill column-major. LATCH cells fill the block's right-most columns in record order. Constants and inputs are pads left of the core, outputs are pads right of it, with one empty column on each side. Fewer pads than rows are spread evenly over the height.
- Block map: runs of records name blocks; blocks are packed by a squarified treemap in block order on the cell grid. Aspect-ratio comparisons are exact (BigInt cross-multiplication). Each block must hold its logic columns plus its strip columns; if the packing does not fit, the core grows by one column or row and it is tried again. Records no run covers go to a block named `(unmapped)`.
- `layoutHash` = SHA-256 of `"covenant-dieshot-layout-v1"`, then `cols`, `rows`, signal count, output count as u32 big-endian, then (x, y) of every signal and every output pad as u16 big-endian. SHA-256 is implemented in the package (synchronous, works without WebCrypto).
- Rendering: one offscreen layer holds background, wires and dark cells. Wires are Manhattan paths in the 2 px gaps between cells, stroked one record at a time at 8% alpha so busy channels add up. Wires on the state loop (into or out of a LATCH) use a second colour. Wires from the two constants are not drawn. Each frame copies the layer and draws lit cells as one path per colour, then pulses.
- `animate` timeline (default 2.4 s): sweep from 5% to 70%, outputs resolve at 74%, clock edge at 82%. The wavefront reaches level `l` at a fraction that is half `l / (maxLevel + 1)` and half the share of cells below `l`, so neither one crowded level nor a long tail of sparse levels takes the whole sweep. In a single-block layout a thin line marks the front.
- `stateBefore` and `stateAfter` are packed bytes (as the chain passes them). The strip shows each LATCH's own state bit.
- The renderer takes `createCanvas`, `requestFrame`, `cancelFrame` and `dpr` as options so it can be tested without a DOM.

### 3.4 web

- No router library: `parseRoute` plus a `hashchange` listener.
- Only the landing page is in the entry. The circuit bench, the kernel pages (with the Flow Governor's netlist) and the two guides are scripts fetched on demand and prefetched 1.2 s after first paint (see 3.5 for the chunk accounting).
- The die shows the last beat that was run. Toggling an input or a state bit updates its pad or strip cell at once; the logic is recomputed when Clock is pressed. That keeps the picture equal to the plate.
- After a beat the new state becomes the state for the next beat. Pressing Clock twice with the same inputs is the "same inputs, two states" demonstration. A row of the beats table can be loaded back into the editors.
- The plate shows MATCH only when both the outputs and the new state returned by the chain equal the local ones. If the chain cannot be asked the plate says NOT CHECKED, never MATCH.
- "Not found" (the chain answered that the circuit or processor does not exist) is shown differently from "could not read the chain".
- Colours: page follows `prefers-color-scheme` unless the header toggle chose light or dark (a `data-theme` attribute, remembered in localStorage when allowed); the die has a dark and a light palette and switches live with either. `prefers-reduced-motion` skips the animation.
- All strings read from the chain (names, story) are rendered as text. Links are built only from addresses that passed a hex check.
- The icon is an inline `data:` SVG so no `/favicon.ico` request is made.

### 3.5 kernel pages

- **One source of truth for addresses**: `deployments/xlayer.json`. The site never names a Covenant address of its own; `addresses.json` lost `processor` and `probeCircuitId` (they are derived) and gained `gluttonChipId`. The Pages workflow now also runs when that file or a bundled chip file changes.
- **History** is `records(n)` and `cums(n)` through Multicall3, newest first, 20 per page; never `eth_getLogs`.
- **The three-way MATCH** of an audit page: the kernel's record, `Lens.replayOn(kernel, n, false)` (TapeOut's `Circuits.step`), `Lens.replayOn(kernel, n, true)` (SealedVM), and this browser's TAP-20 step of the netlist read from the chain (TapeOut's copy, the Fab's snapshot if that fails) from the previous record's state. The routed amounts are recomputed with `kernel/model.ts` from the stored outputs, inflow, reserve and totals (allowance room = `cums(n).allowPaidCum - allow`, as the Lens does). The replays are direct `eth_call`s, exactly what the printed `cast` lines ask.
- **The landing demonstration** is `chips/out/fg.witness.json`: input word `x`, states A (after 4 epochs) and B (after 6), both reached from zero by real kernel input words. The browser steps both and replays both histories; when the deployment file names the chip it also asks `Circuits.step` twice and shows MATCH only if outputs and new states equal the local ones. Before that it says the on-chain check runs once the chip is taped out.
- **"Nobody can change this" is stated only where code proves it**: the kernel's runtime code is checked to be the ERC-1167 proxy to the factory's `kernelImpl` followed by exactly `abi.encode(globals(), envelope())`; the implementation's code is walked opcode by opcode (push data and the CBOR metadata skipped) for DELEGATECALL, CALLCODE and SELFDESTRUCT, and searched (byte-aligned) for the selectors of owner(), transferOwnership, renounceOwnership, upgradeTo, upgradeToAndCall, pause(), unpause(), approve, transferFrom, both safeTransferFrom and setApprovalForAll. Live implementation 0x72e6…EDF1: 20,413 bytes, none found.
- **Trust page** reads the owners live: TapeOut's factory owner (a Safe, threshold and owner count read with `getThreshold()`/`getOwners()`), the beacon's owner, IgnixManager's owner, `KernelFactory.pinsLive()`. Every other statement is from `chips/INTERFACE.md` sections 7, 8, 12, 13 and `contracts/core/NOTES.md`.
- **Hostile page**: the Glutton's raw demand (its bytes stepped here), what the envelope lets through (shares after K2/K3, the per-settle and lifetime caps), a one-settle table with selectable tax and reserve for Glutton, Glutton512 and the Flow Governor, and a shadow run over every record of the flagship kernel. The shadow run is local (`shadowRun`, labelled "local simulation of the kernel's clip, tested against the golden vectors") and, when `COVENANT.gluttonChipId` is set, also `Lens.shadowChip`, compared step by step (MATCH plate).
- **Counterfactual** is `Lens.counterfactual` over records 1..count, paged with `counterfactualFrom` in pages of 400 so no `eth_call` grows too large.
- **Chunk accounting**: Vite 8 (rolldown) splits a module that the entry imports statically into its own chunk when a lazy chunk also imports it, so the entry is index.js plus the scripts it imports. `check-budget.mjs` used to count only the files index.html names; it now follows `import … from "./x.js"` through every script reached. That raised the measured entry (honestly) and is why the judge and trust pages moved behind `import()`.
- **RPC**: `createRpc` now also falls back to `application/json` when an endpoint answers the `text/plain` form with HTTP 200 and a request-level error (`-32600` / `-32700`, no id). Anvil does that; it closes the open item of 5 below for such endpoints.
- **Design**: a die-shot palette (logic gold = buy and lock, wire blue = allowance, latch teal = reserve) on a faint routing grid; chip-package cards; numbered section pins; one-sentence lede on every page; light and dark; every page checked at 360 px.

### 3.6 kernel v2 (USD₮0 quote)

Kernel v2 is `contracts/core-v2` (`chips/INTERFACE-V2.md`): a kernel for IGNIX Directed tokens quoted in USD₮0, with
revenue paid to the kernel routed as tax and the Flow Governor reused through a fixed code shift. It is not deployed;
the pages work with and without the keys `deployments/xlayer.json` will gain (`.coreV2 {kernelFactory, kernelImpl,
lens}`, `.flagshipV2 {chipId, kernel}`). Without them nothing v2 appears except where a page says it is not deployed.

- **v1 or v2 is decided by factory.** `kindOf` asks `isKernel(address)` of the kernel factory and of KernelFactoryV2
  (each only when the deployment file names it), in the same Multicall3 batch as the first reads. If neither created
  the address, the version is read from its answers (a v2 kernel answers `quoteShift()`), and the page says the
  factory is not one of ours, as before. `globals()` is read raw and decoded after the decision (18 words on v1, 19
  on v2), and `records(n)` with the version's decoder (`quoteIn` in place of `nativeIn`).
- **Each kernel is audited by its own factory's Lens.** LensV2 answers only for kernels of KernelFactoryV2 and the v1
  Lens only for kernel v1's (both revert `NotKernel` otherwise; a fork test checks this), so `loadAudit`,
  the counterfactual and the shadow run take the Lens from the kind. LensV2 has the v1 Lens's ABI.
- **Units.** On the curve a v2 kernel's regime asset is USD₮0, 6 decimals (symbol and decimals read from the quote;
  KernelFactoryV2 refuses any quote without 6 decimals); after graduation the project token, 18, as in v1. Every
  amount on the vault, audit and hostile pages is formatted in the regime's unit (`amount`, `Unit` in `kernel/chip.ts`).
- **The code shift is explained in the envelope section** (`CodeShift` in `components/EnvelopeWords.tsx`): amounts
  shown as `lg8(x << s) = lg8(x) + 8s`, why a whole number of bits, 1 OKB of the chip's calibration in USD₮0
  (`10^18 >> s`), the price band for which `s` is the nearest shift, the stated reference rate (135.895901 USD₮0 per
  OKB, block 72,530,000, only when `s` is 33), the codes of 1 USD₮0, one $0.50 call and a whole curve, and ceilMax in
  USD₮0. Every shift-dependent number is computed from the kernel's own `quoteShift()`. The envelope words read
  ceilMax as `exp8(ceilMax) >> s` and give the floor threshold exactly (`minAmountForCode`: the smallest reserve whose
  shifted code reaches floorMin, "any reserve" for the reference floorMin 1).
- **Revenue is shown as part of inflow**, never separately, because the kernel cannot tell it from tax: the vault page
  says inflow is "tax claimed from the vault plus USD₮0 paid to the kernel directly (revenue), routed as tax", and a
  "Revenue, routed as tax" section states the limits: routed only if paid to the kernel; payTo is a seller setting
  the operator can change without a trace on chain; after graduation the chip does not see revenue and a fixed rule
  buys and burns; self-payment by any team wallet is forbidden; USD₮0 sent to a never-bound kernel and foreign ERC-20s
  stay there. It shows the Architect's PAY_TO as `deployments/xlayer.json` records it and says that is a record, not
  something the chain proves (today: the agent wallet, so "not this kernel").
- **The Tether trust line.** The vault page reads `USD₮0.isBlocked(kernel)` live and states what Tether's owner can do
  (block, destroy, credits first after a destruction); the trust page has a "Tether, for a kernel v2" party (owner read
  live once a v2 factory is recorded); the judge page's check 8 prints the owner.
- **The code scan on a v2 kernel allows `approve`**: KernelV2 approves USD₮0 to the IgnixManager or the router for
  exactly one buy and resets it in the same settle, so the selector is in its bytes (checked: the only forbidden
  selector present in the 20,900-byte implementation). In its place the page reads the kernel's USD₮0 allowance to the
  Manager and to the router live and requires both to be zero.
- **Audit page.** The amounts are recomputed with the shift (`route(..., shift)`, shift 0 after graduation); the input
  codes are shown as `lg8 + 264` and checked against `lg8s` of the stored amounts; a graduated record shows the quote
  leg (`quoteIn`) and how to tell the two legs' shared buy flags apart (INTERFACE-V2 section 10).
- **Hostile page.** A kernel switch (v1 OKB / v2 USD₮0) for the one-settle table: on v2 the Flow Governor's input word
  carries shifted codes and the Glutton is capped at `exp8(ceilMax) >> s` (3.932160 USD₮0); and, once a v2 flagship is
  recorded, a second shadow run over its records with the shift, compared with `LensV2.shadowChip`.
- **Judge page.** Check 6 also covers the v2 token; check 8 ("Kernel v2 reads USD₮0 through a fixed shift") checks the
  factory's pins (quote, 6 decimals, shift, codeShift), the v2 kernel (by KernelFactoryV2, holds its chip, clean clone,
  no allowance left), every curve record's TAX/TAXCUM/RES against `lg8s`, LensV2 on the first and last settle, and
  prints `isBlocked` and USD₮0's owner. Until a v2 deployment is recorded it says so ("nothing to check yet").
- **`.site` is not bundled.** `deployments/xlayer.json` gained `.site` (the DeWEB publication's own record) after the
  last publish; bundled, its gateway host failed `check-budget.mjs`, so `pnpm --filter web build` (and the Pages
  workflow) failed on HEAD before this work. `deploy/publish-site.sh` already builds from the file without `.site`; a
  Vite plugin now drops it in every build, so a build from the full file and one from the file without `.site` bundle
  the same deployment data. It also removed 2.7 KB from the entry.
- **The fork fixture handles no key.** IgnixManager checks the platform signature with `ECDSA.recover` against
  `signer()` (storage slot 5). The fixture uses a fixed signature (r = the x coordinate of secp256k1's generator,
  s = 1, v = 27), asks the ecrecover precompile which address that recovers to for the launch's digest, and writes that
  address into the slot on the fork; nobody holds a key for it. Kernel v1's launch now uses the same method (it used
  anvil's public test key 0 before). Revenue on the fork is a plain USD₮0 `transfer` to the kernel from an unrelated
  account: what an x402 settlement amounts to on chain (the EIP-3009 path itself is in `contracts/core-v2`'s fork tests).

## 4. Verified

All on 2026-10-04 from this machine, read-only.

### 4.1 Chain facts

- `rpc.xlayer.tech` and `xlayerrpc.okx.com`: chain id `0xc4`; CORS `access-control-allow-origin: *`; headers advertise 7 requests per second; a batch of 10 is one request against that limit; a batch of 11 returns HTTP 200 with a single error object, code -32014 `too many RPC calls in batch request`.
- A revert arrives as JSON-RPC error code 3 with the revert data in `error.data`.
- Factory `0x1f09daefa827f02cbb40967cc91b259763760761`: `cpuCount()` = 275; `cpuAt(0)` = `0x839bdD6fa7A66416A609A735e11DE5411B98574e` (name `OnlyTestXLayer`); `isCPU(address)` exists (selector `0x5f5a364f`).
- **`nextId()` on X Layer is the highest existing circuit id, not the next free one.** Checked on three processors: `circuitInfo(nextId)` answers and `circuitInfo(nextId + 1)` reverts `no circuit` (processor 0: 103; LoteGate: 3; Trivium: 1). TAP-20 section 6 describes it as "the id the next taped-out circuit will get". The processor page asks for ids 1..nextId and drops any that do not exist, so the list is right under either reading.
- Multicall3 is deployed at `0xcA11bde05977b3631167028862bE2a173976CA11` (3,808 bytes of code); `getBlockNumber()` works inside `aggregate3`.
- Gas for one `step` by `cast estimate`: Trivium #1 7,098,083 (3,035 gates), LoteGate #3 11,404,148 (4,863 gates): about 2,340 gas per gate. With the 50M `eth_call` cap, the free cross-check works up to roughly 21,000 gates. The circuit page warns above that.
- **REF exists in the wild.** Processor 0 circuit 4 (and its neighbours) is a single REF record to `0xf044d395c91e77459e6b2155015e14f0dd9b349f` #102 (processor `BEM OTC`, 8 NAND + 2 LATCH). It is a 3-state cycle with no inputs.
- Both large circuits have their LATCH records first, like the Covenant chip shape.

| Circuit | Shape | Bytes | keccak256 of the netlist | Die (cells) | Levels | layoutHash |
|---|---|---|---|---|---|---|
| Trivium #1 `0x933F…Db5a` | 161 in, 1 out, 288 state, 3,035 gates | 20,381 | `0x68c5f5d81225f000849f0ae9aaf594753a8a124f78dadc590a053811ea783960` | 71 x 48 | 33 | `b060dce833f3dfa593985762a0a27d8311fc6e19a9557bad273c6b3be744f834` |
| LoteGate #3 `0xAa13…AF21` | 133 in, 199 out, 243 state, 4,863 gates | 33,312 | `0x0478369b8e75c51870734f6d64712c071d97640b4d9457595bdf3a5bff474f53` | 91 x 60 | 76 | `9c581dd87d710d6eef7940bcfe33671331c946d89608a83923792a49ef8b5ea2` |
| OnlyTestXLayer #1 `0x839b…574e` | 2 in, 1 out, no state, 4 gates (XOR) | 28 | `0x564b93679937b8cbafd5ae8fd11f7caf200606f267f1cdb37a38f95e361b2a0f` | 7 x 2 | 3 | `ee4ea161c19360cf5d3a0e1ff020a42263830d405af02beb667150e3ef8339fa` |
| OnlyTestXLayer #4 | 0 in, 1 out, 2 state, 10 gates via 1 REF | 31 | `0xbf6062b32a57e0683ae506e44b41218ff126607f586adbe1003035eed0c0bec8` | 6 x 1 | 1 | `ab9639075d88d43c44d7f5449bf5057734ec0bc9a00b0d3ad9e5d6da9009d9c8` |

The two keccak values of the large circuits were also computed with `cast call ... | cast keccak` and agree. The layout hashes were the same in Node and in Chromium.

### 4.2 Simulator against the chain

- TAP-20 `vectors.json` (fixture `packages/tap20/test/fixtures/tap20-vectors.json`, SHA-256 `1a02f5cf...203b` as stated in TAP-20; repository commit `cca62773` of 2026-10-01): all 5 valid netlists (truth tables, beats, re-encoding), all 8 ill-formed ones rejected with the expected code, all 5 packing edge cases.
- Live, `Circuits.step` by `eth_call` against the local simulator, per large circuit: 6 random (state, inputs) pairs, a 5-beat run feeding each new state back, and 4 lenient-reading shapes (empty, short, over-long, padding bits set). All identical, new state and outputs.
- Live, small circuits on processor 0 (ids 1 to 4, one of them the REF circuit): every state and input, through `step` and through `eval` where there is no state. All identical.
- A REF pointing at an address that is not a registered processor is rejected (`ref-unresolved`).

### 4.3 Codec

- Every selector equals `keccak256(signature)[:4]` by viem and by our keccak; every builder's calldata equals viem's `encodeFunctionData` (random arguments, byte lengths 0 to 70 and the live shapes); every decoder agrees with viem's `encodeFunctionResult`; `aggregate3` calldata and return data for 0 to 40 random sub-calls; truncated return data throws instead of decoding.
- keccak256 equals viem for every length 0 to 600 and a 40 KB input; EIP-55 equals viem `getAddress`.

### 4.4 Site, in a real browser

Chromium driven through Playwright, production build served as static files by `python3 -m http.server`, also the dev server.

- Landing, processor (103 circuits, paging), circuit, judge, trust and not-found pages render. Console: no errors or warnings.
- Trivium #1 and LoteGate #3: Clock gives MATCH; chained beats MATCH. On Trivium, the same inputs from two states gave different outputs (`0x00` from the zero state, `0x01` from the state that beat produced), both confirmed by the chain. OnlyTestXLayer #1: all four input combinations MATCH through `eval` (outputs 0, 1, 1, 0). OnlyTestXLayer #4 (REF): five chained beats MATCH (outputs 1, 0, 0, 1, 0).
- The `cast call` line printed for a Trivium beat was pasted into a terminal and returned the same new state and outputs as the plate, on both endpoints.
- Frame pacing during `animate`, measured with `requestAnimationFrame` deltas on a 120 Hz display, canvas backing store 1916 px wide at device pixel ratio 2: Trivium (3,035 gates) and LoteGate (4,863 gates) both 324 frames in 2.7 s, mean 8.3 ms, p95 at most 9.2 ms, worst 9.4 ms, no frame above 20 ms.
- Hover text and click-to-flip on input pads work; the die re-themes when the colour scheme changes.
- At 360 px width no page scrolls sideways (`scrollWidth == clientWidth` on every route) and a beat still MATCHes.
- Network: the page requested its own three files and POSTs to `rpc.xlayer.tech`; nothing else.
- With `processor` set in `addresses.json` (tried with a stand-in address, then reverted) the landing page shows the processor and probe links and hides the examples.

### 4.5 Sizes

After kernel v2 support (2026-10-06, evening), `node scripts/check-budget.mjs`: **total 235,094 of 240,000 (98.0%)**,
**entry 84,330 of 96,000 (87.8%)**. Entry `index-*.js` 69,061 (`.site` no longer bundled: minus 2.7 KB; the shift
helpers, unit helpers and v2 config: plus 1.4 KB); `kernelPages` 49,845 (+12.9 KB: v2 on the vault, audit and hostile
pages); `guidePages` 26,565 (+6.8 KB: judge check 8, the Tether party); `kernel-*.js` 9,108 (+2.2 KB: v2 decoding and
detection); stylesheet 14,230 (+0.2 KB). Headroom left: 4,906 bytes in total, 11,670 in the entry.

The table below is the state before that work.

`web/dist` on 2026-10-06 (bytes on disk):

| File | Bytes | gzip |
|---|---|---|
| `assets/index-*.js` (entry) | 66,322 | 26,219 |
| `assets/style-*.css` (entry) | 14,027 | 4,005 |
| `index.html` (entry) | 1,039 | 590 |
| `assets/kernelPages-*.js` (vault, audit, hostile) | 36,883 | 11,879 |
| `assets/sim-*.js` (tap20 step + fg.hex + Gluttons) | 31,567 | 8,770 |
| `assets/guidePages-*.js` (judge, trust) | 19,798 | 7,608 |
| `assets/Circuit-*.js` | 14,776 | 5,543 |
| `assets/Die-*.js` (dieshot) | 13,568 | 6,213 |
| `assets/kernel-*.js` (data/kernel, code checks) | 6,957 | 3,138 |
| other two chunks | 5,317 | |
| **Total** | **210,254** of 240,000 (87.6%) | |
| **Entry** (html + stylesheet + index.js and every script it imports statically) | **81,388** of 96,000 (84.8%) | |

`packages/chain`, minified: client + codec 3,367 bytes, whole main entry 5,082 bytes (ceiling 5,120), keccak module 1,833 bytes. The `kernel` entry is separate and is not counted in that ceiling.

`check-budget.mjs` was run against tampered copies of the build and failed each one: an external script, an external font, a total above 240,000, an entry above 96,000, an analytics host in the code, a source map, an absolute path (2026-10-04). On 2026-10-06 it also rejected a build whose entry was within budget only because a static import had been split out (99,599 bytes once counted).

### 4.6 Kernel pages

- **Golden vectors**: `kernel/model.ts` passes every vector of `chips/golden/vectors.json` (format `covenant-golden/2`): 3,623 + 6 lg8, 1,024 exp8, 64 input and 60 output words, 400 routing, 67 boundary routing, 120 graduated routing, 3 fallback words, the graduated fallback, 6 state encodings (`test/model.test.ts`).
- **Chip files**: the bundled `fg.hex` has the keccak and size of `chips/out/fg.proofs.json`; this site's simulator reproduces `fg.witness.json` (both routes, both new states, both reach paths, and all 19 steps of the mode tour) and every 7th beat of `fg.vectors.json` (the model's vectors); the Glutton bytes have the keccaks of their README and clamp as it says (K2+K3, K2+K2C+K3 on 3 OKB, Glutton512 K1T+K3) (`test/chip.test.ts`).
- **Codec**: every new selector equals keccak256 by viem and by our keccak; calldata equals viem's `encodeFunctionData` and decoders equal viem's `encodeFunctionResult` for records, envelope, globals, replay, counterfactual, stateMatters, preflight, shadow pages of 0–6 steps, chipInfo, tokens, team entries, Safe owners (`packages/chain/test/kernel.test.ts`).
- **On the fork fixture** (fork of block 72,521,930, 12 records whose modes run CRUISE, BANK, DEFEND, REST; one record with DT = 2): every record MATCHes four ways and its amounts equal the TypeScript clip; no clamp fired on any record; the local Glutton shadow run equals `Lens.shadowChip` on every step (allowance 18.74% of the tax vs the real chip's 5.77%); the counterfactual chip column equals the sums of the records and paging does not change it (`test/fork.test.ts`, 4 tests). In Chromium against that fork: landing, vault, audit (#9, a DEFEND settle after a skipped epoch: MATCH, stateMatters yes), hostile (on-chain shadow MATCH), judge (7 of 7 passed), trust.
- **On X Layer mainnet**, after the flagship chip was taped out (chip #2, kernel 0xB722…d356, not yet bound): the landing page's two `Circuits.step` calls MATCH the browser (`0xa000…060b` and `0x0001…0e11`, routes differ in T_BUY, T_ALLOW, T_RES, REL); `node scripts/verify-kernel.ts` prints the same; the vault page shows the kernel as a clean clone of the factory's implementation, holding chip #2, pins holding (TapeOut evaluator), envelope as in `LaunchChip.referenceEnvelope`, no records; judge checks 1, 2, 3, 5, 7 pass, 4 and 6 say there is nothing to check yet (no settle, no token). `test/live.test.ts` gained a check of the deployment (processor, transistors, Fab, factory, Lens agree with each other).
- **Phone width**: at 360 px no route scrolls sideways (`scrollWidth == clientWidth`) on landing, vault, audit, hostile, judge, trust and the circuit page; tables scroll inside their own box. Console: no errors or warnings on the production build.
- Screenshots: `.playwright-mcp/shots/` (git-ignored): `landing-fork.png`, `landing-mainnet.png`, `landing-phone-dark-fork.png`, `vault-fork.png`, `vault-die-anim.png`, `audit-fork.png`, `hostile-fork.png`, `hostile-dark-fork.png`, `trust-dark-fork.png`, `vault-v2-codeshift-fork.png`.

### 4.7 Kernel v2 (USD₮0 quote)

All on 2026-10-06 (evening); X Layer only read (`eth_call`), everything else on a local anvil fork.

- **Vectors** (`test/model.test.ts`, offline): every vector of `chips/golden/vectors_v2.json` (format
  `covenant-golden-v2/1`): 1,950 `lg8s`, 3,072 `exp8s`, 3,000 routing with shifts 0 to 40 (755 graduated), 153 boundary
  routing; the reference points of `kernel_model_v2.py` (1 USD₮0 = 424, $0.50 = 416, 8,000 USD₮0 = 527; M1, CEIL0,
  M2, M3 in base units; 10^18 >> 33 = 116,415,321); and **all 8,808 settles of `vectors_v2_settles.jsonl`** (520
  sequences): every stored input word's TAX, TAXCUM, RES equal `lg8s` of the stored amounts (shift 0 after
  graduation), GRAD/REV/REVCUM/ESC/ZERO as required, the clip port gives the stored clamp bits, allowance and decided
  buy, every fallback record carries the fallback word. Three mutants of the port (no shift on K5, on the chip's CEIL,
  on ceilMax) each fail 3 of these tests.
- **Codec** (`packages/chain/test/kernel.test.ts`): `RecordV2`, `GlobalsV2`, `quote()`, `quoteShift()`, the
  KernelFactoryV2 pins, ERC-20 `allowance`, USD₮0 `isBlocked` against viem; every new selector against keccak256.
  USD₮0 `isBlocked(address)` (`0xfbac3951`), `owner()` (`0x4DFF…0bf8`), `decimals()` 6 and `symbol()` "USD₮0" were
  read on X Layer.
- **Fork fixture** (anvil fork of block 72,545,990; about 15 minutes): DeployCoreV2 accepted shift 33 from the live V3
  pool; LaunchChipV2 taped the Flow Governor out as chip 6 and created kernel v2 `0x90D0…2121` (KernelFactoryV2
  `0x3ebe…b049`, implementation 20,900 bytes); a Directed launch quoted in USD₮0 with that recipient went through the
  live IgnixManager with the keyless signer; 12 curve epochs (52.000069 USD₮0 of inflow including 12 USD₮0 of
  revenue payments (24 of 0.50); modes CRUISE, BANK, DEFEND, REST); the whale's buy graduated the token (7,678.94 USD₮0 at most);
  3 graduated epochs whose quote leg spent 103.0125, 96.340808 and 46.754183 USD₮0 on the pair (two of them with
  BUY_SHRUNK from the impact cap). No clamp on any of the 15 records; no USD₮0 allowance left.
- **Fork tests** (`COVENANT_FORK=… vitest run test/fork.test.ts`): 10 of 10 (kernel v1's 4, unchanged, and 6 for v2):
  v1/v2 told apart by factory and, without the v2 factory in the file, by shape; the v2 vault (bound, holds chip 6,
  clean clone of the recorded implementation, only `approve` among the forbidden selectors, no allowance, not
  blocked); every v2 record four ways (record = LensV2 on TapeOut = LensV2 on the SealedVM = this site's simulator),
  shifted codes and the clip as recorded, quote leg present after graduation; the Glutton shadow run with the shift
  equals `LensV2.shadowChip` on all 15 steps (allowance 9.750006 USD₮0, 18.75% of curve inflow, never above 3.932160
  USD₮0 per settle; the real chip 2.9365 USD₮0, 5.6%); LensV2's counterfactual adds up per regime and paging does not
  change it; the v1 Lens refuses the v2 kernel and LensV2 the v1 kernel.
- **In Chromium** (Playwright) against the fork (`dev:fork`): vault v2 (all facts ✓, code-shift panel, revenue section,
  15-row history with the quote-leg column, both counterfactual regimes), audit #6 (BANK, inflow 18.312729 USD₮0:
  MATCH four ways, codes shown as lg8 + 264) and #13 (graduated: MATCH, quote leg 103.0125 USD₮0, flag reading),
  hostile (the v2 switch; both shadow runs MATCH on chain), judge (8 of 8 passed), trust (USD₮0's owner read). At 360
  px no route scrolls sideways (landing, both vaults, three audits, hostile, judge, trust). Console: no errors or
  warnings. Found and fixed there: after graduation the vault's allowance tile and the audit's allowance-limit rows
  showed token totals as quote amounts (true for a graduated kernel v1 too; never seen before because the v1 fixture
  does not graduate).
- **Production build against X Layer** (no v2 keys): judge check 8 and the trust page say kernel v2 is not deployed;
  checks 3 passes and 4 and 6 have nothing to check yet, as before; the v1 vault shows no v2 section; the hostile v2
  switch uses the reference envelope and shift; `node scripts/verify-kernel.ts`: all MATCH. Console clean.

## 5. Open assumptions and things not verified

- Browsers: only Chromium was driven. Not tried in Safari or Firefox. The code needs `AbortSignal.timeout` (Chrome 103, Firefox 100, Safari 16).
- Smoothness was measured on one machine. On a slow phone the per-frame work is one image copy plus about 5,000 `rect` calls; not measured there.
- The TapeKit gateway (`*.tapekit.org`) was not tried. Per the design notes its CSP allows same-origin scripts and `connect-src https:`. The site uses a module script, one dynamically imported same-origin chunk and an inline `data:` icon; none was tested under that CSP.
- The `text/plain` request form works on both endpoints today. An endpoint that answers it with HTTP 200 and a request-level `-32600`/`-32700` is now asked again as JSON (3.5); any other in-band error form would not trigger the fallback.
- The kernel pages were exercised with real records only on the fork. On mainnet the kernel has no record yet: the history, audit, counterfactual and shadow sections were seen in their empty state only.
- The code scan proves absence of selectors and opcodes in the implementation's bytes; it does not prove the implementation equals `contracts/core/src/Kernel.sol` (source verification on OKLink was not run by this work).
- The TeamRegistry on mainnet lists one wallet (the deployer). `docs/WALLETS.md` also names the keeper; the judge check says it is not declared in the registry yet.
- Both endpoints are OKX's. The page has no second operator to compare against; the trust page says so.
- The rate limit header says 7 per second; a burst of 14 requests was not throttled. The real limit was not found.
- The block-map file format (`decodeBlockMap`: 7-byte runs of `firstRecord u24, count u24, blockId u8`) follows our design notes. `chips/INTERFACE.md` does not define it yet. No real block map exists, so the treemap path is covered by tests only and is not wired into a page.
- `nextId()` semantics were checked on three processors, not read from the X Layer contract source.
- The gas-per-gate figure comes from two circuits.
- Preact 11.0.0, Vite 8.3.2, vitest 5.0.3 and TypeScript 7.0.2 are the versions pnpm resolved today; nothing older was tried.

- Kernel v2 pages were exercised with records only on the fork. The deployment file's v2 key names (`coreV2`,
  `flagshipV2`) are the ones the brief gave; if the deploy step writes others, `config.ts` and the fixture follow.
- The fixture assumes a v2 kernel recorded in the deployment file is still unbound (as it does for kernel v1): once a
  real token is bound to it, its launch and bind steps would fail on the fork.
- Revenue on the fork is plain USD₮0 transfers to the kernel, not EIP-3009 settlements; the kernel only sees the
  balance, and `contracts/core-v2`'s fork tests run the EIP-3009 path.
- The site cannot tell revenue from tax in a record (neither can the kernel); it never shows a revenue figure.
- The Architect's PAY_TO shown on a v2 vault is the deployment file's record, not chain state.

## 6. Stubs and open items

- No builder page (compose a chip, tape it out): out of scope here.
- The die has no block map: `chips/out/fg.map.json` has `blocks: []` (records carry cones, not blocks), so the vault and audit dies are one block. The state is shown field by field next to the die instead.
- A REF is drawn as plain cells (one per signal it produces) with a link to the referenced circuit; there is no drill-down into the sub-circuit on the die.
- The landing demonstration uses the witness of `chips/out/fg.witness.json`. If the chip is rebuilt, regenerate the witness with it, or the page will show the local and on-chain answers disagreeing (by design it then says so).
- Graduated-regime display (token units, burn leg, native pot) for kernel v1 was not seen with data: its fixture token does not graduate. Kernel v2's was (records 13 to 15 of the v2 fixture), which also exercised the shared graduated paths.
- The root `README.md` still says "seven checks" for the judge guide (now eight); it was being edited by another track, so it was left alone.

## 7. Differences from the brief

1. `packages/chain` is 4,978 bytes minified as a whole, against a target of about 3 KB. The client and codec alone are 3,263; the rest is the typed call table for 20 functions, the Multicall3 reader and revert decoding. `pnpm --filter @covenant/chain size` fails above 5,120.
2. Two calls beyond the list were added: `factory.isCPU(address)` (the "registered" tag, and required to resolve a REF per TAP-20 section 3.6) and Multicall3 `getBlockNumber()` (the "read at block" line).
3. The site is several scripts, not one: the entry and four on-demand chunks (see 3.4, 3.5).
4. RPC requests are sent as `text/plain`: see 3.2.
5. The sweep is not linear in level number: see 3.3.
6. `addresses.json` and `deployments/xlayer.json` are imported with `with { type: 'json' }` so the same module loads in Node and in Vite.
8. `addresses.json` no longer has `processor` and `probeCircuitId`: both come from `deployments/xlayer.json` (3.5). `github.com` was added to the hosts the bundle may mention, for plain links to the source files (never fetched).
7. `nextId()` is treated as the circuit count: see 4.1.

## 8. Shared-repository incidents

- pnpm 11 refuses dependency install scripts by default. My `esbuild` devDependency (used only by `packages/chain/scripts/size.mjs`) made the first `pnpm install` print `ERR_PNPM_IGNORED_BUILDS` and append an `allowBuilds` placeholder to the root `pnpm-workspace.yaml`. I restored that file by hand once, which I should not have done to a file outside my directories; the next install appended the placeholder again. The file now reads `allowBuilds: esbuild: true`, set by someone else, and I have not touched it since.
- `pnpm exec` triggered a full workspace install once (see the note in section 2). After that I ran binaries directly or with `--config.verify-deps-before-run=false`.
- The browser tool wrote its page snapshots and console logs into the root `.playwright-mcp/` folder (already present and git-ignored).

## 9. Notes for whoever continues

- New read calls go into `packages/chain/src/kernel.ts` with a literal selector, an entry in `KERNEL_SIGNATURES`, and a viem check in `test/kernel.test.ts`.
- A page that needs the netlist simulator goes behind `import()`; `kernel/sim.ts` is the only module that bundles netlist bytes (`?raw` imports, so it cannot be loaded by plain Node; `scripts/verify-kernel.ts` reads the files with `fs` instead).
- After the reference token is bound and settles start, run `pnpm --filter web verify:kernel`: every record should print MATCH.
