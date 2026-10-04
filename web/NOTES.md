# Web and packages: notes

Scope: `packages/tap20`, `packages/chain`, `packages/dieshot`, `web`. Written 2026-10-04.
Everything here reads X Layer mainnet (chain 196) with `eth_call` only. Nothing sends a transaction, holds a key or loads a wallet library.

## 1. What exists

| Path | What it is |
|---|---|
| `packages/tap20` | TAP-20 parser, well-formedness check (section 3), one-beat simulator, LSB-first bit packing, REF support (sync resolver, plus `load()` that fetches a REF closure asynchronously). No runtime dependencies. |
| `packages/chain` | JSON-RPC client over `fetch` (failover, batches of at most 10), hand-written ABI codec for the TapeOut read calls and Multicall3 `aggregate3`, typed call descriptors, `readAll` (many calls in one request). keccak256 and EIP-55 in a separate entry, `@covenant/chain/keccak`. No runtime dependencies. |
| `packages/dieshot` | Deterministic floorplan (`layout`, `layoutHash`), optional block map packed by a squarified treemap (`decodeBlockMap`), Canvas 2D renderer with `animate(previousSignals, signals, stateBefore, stateAfter)`. No runtime dependencies. |
| `web` | Vite + Preact + TypeScript site, hash routes: `#/`, `#/p/:processor`, `#/c/:processor/:id`, `#/judge`, `#/trust`. Only runtime dependency: `preact`. |

The three packages are consumed as TypeScript source (`exports` point at `src/index.ts`; relative imports carry the `.ts` extension). Vite, vitest and plain `node file.ts` (Node 26 strips types) all run them without a build step. The code uses erasable syntax only (no enums, no parameter properties), which `tsc` enforces.

Files worth knowing in `web/`:

- `src/addresses.json`: `{factory, processor, probeCircuitId, rpc}`. Exactly these four keys (a test checks it). Set `processor` and `probeCircuitId` when Covenant's processor exists: the landing page then shows it instead of the public examples, and the judge page uses the probe circuit as its sample.
- `src/config.ts`: reads that file; holds the example circuits and the explorer URL.
- `src/data/processor.ts`, `src/data/circuit.ts`: the data path, with no DOM. The pages, `scripts/verify-live.ts` and `test/live.test.ts` all call the same functions.
- `src/routes/Circuit.tsx`: the circuit bench. Loaded on demand (see 3.4).
- `src/routes/Judge.tsx`, `src/routes/Trust.tsx`: placeholders. The text lives in arrays at the top of each file.
- `scripts/check-budget.mjs`: fails the build if the output breaks the size budget or is not self-contained.
- `scripts/verify-live.ts`: the page's RPC calls and simulator from a terminal; prints MATCH or MISMATCH.

## 2. How to run

From the repository root, after `pnpm install` has been run once:

```
pnpm --filter web dev                  # http://localhost:5173
pnpm --filter web build                # typecheck, vite build, budget check; output in web/dist
pnpm --filter web test                 # 25 tests, 9 of them live against X Layer
pnpm --filter web test:offline         # SKIP_LIVE=1
pnpm --filter web verify:live          # node scripts/verify-live.ts; prints MATCH per beat
pnpm --filter web verify:live -- 0xProcessor 3     # one circuit of your choice

pnpm --filter @covenant/tap20 test     # 67 tests, 11 live
pnpm --filter @covenant/chain test     # 90 tests, 11 live
pnpm --filter @covenant/chain size     # minified sizes, fails above the ceiling
pnpm --filter @covenant/dieshot test   # 42 tests, none need the network
# all four at once, no network
pnpm --filter @covenant/tap20 --filter @covenant/chain --filter @covenant/dieshot --filter web test:offline
pnpm --filter @covenant/tap20 --filter @covenant/chain --filter @covenant/dieshot --filter web typecheck
```

(`--filter "@covenant/*"` also matches the services, which share the scope.)

To look at the production build: `python3 -m http.server 4173 --directory web/dist` (any static server works; all URLs are relative).

`SKIP_LIVE=1` skips every test that talks to the chain. Without it the live tests run and fail loudly if both RPC endpoints are unreachable.

Note on pnpm 11: `pnpm run` and `pnpm exec` first check that `node_modules` matches the manifests and run an install if it does not. To run a script without that, add `--config.verify-deps-before-run=false`, or call the binaries directly (`web/node_modules/.bin/vite`, `.../vitest`, `.../tsc`).

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
- The circuit bench (tap20 + dieshot + its page) is a second script fetched on demand, and prefetched 1.2 s after first paint. Without the split the entry was 78 KB of the 96 KB allowed, with the kernel pages still to come. `data/processor.ts` and `data/circuit.ts` are separate modules for the same reason.
- The die shows the last beat that was run. Toggling an input or a state bit updates its pad or strip cell at once; the logic is recomputed when Clock is pressed. That keeps the picture equal to the plate.
- After a beat the new state becomes the state for the next beat. Pressing Clock twice with the same inputs is the "same inputs, two states" demonstration. A row of the beats table can be loaded back into the editors.
- The plate shows MATCH only when both the outputs and the new state returned by the chain equal the local ones. If the chain cannot be asked the plate says NOT CHECKED, never MATCH.
- "Not found" (the chain answered that the circuit or processor does not exist) is shown differently from "could not read the chain".
- Colours: page follows `prefers-color-scheme`; the die has a dark and a light palette and switches live. `prefers-reduced-motion` skips the animation.
- All strings read from the chain (names, story) are rendered as text. Links are built only from addresses that passed a hex check.
- The icon is an inline `data:` SVG so no `/favicon.ico` request is made.

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

`web/dist` (bytes on disk):

| File | Bytes | gzip |
|---|---|---|
| `assets/index-*.js` (entry) | 41,306 | 16,114 |
| `assets/Circuit-*.js` (on demand) | 33,314 | 13,311 |
| `assets/style-*.css` (entry) | 5,969 | 2,126 |
| `index.html` (entry) | 1,039 | 590 |
| **Total** | **81,628** of 240,000 (34.0%) | |
| **Entry** (html + script + stylesheet) | **48,314** of 96,000 (50.3%) | |

`packages/chain`, minified: RPC client 1,648 bytes, ABI codec 1,615 bytes (3,263 together), whole main entry with the call table and Multicall3 reader 4,978 bytes (2,555 gzip), keccak module 1,833 bytes.

`check-budget.mjs` was run against tampered copies of the build and failed each one: an external script, an external font, a total above 240,000, an entry above 96,000, an analytics host in the code, a source map, an absolute path.

## 5. Open assumptions and things not verified

- Browsers: only Chromium was driven. Not tried in Safari or Firefox. The code needs `AbortSignal.timeout` (Chrome 103, Firefox 100, Safari 16).
- Smoothness was measured on one machine. On a slow phone the per-frame work is one image copy plus about 5,000 `rect` calls; not measured there.
- The TapeKit gateway (`*.tapekit.org`) was not tried. Per the design notes its CSP allows same-origin scripts and `connect-src https:`. The site uses a module script, one dynamically imported same-origin chunk and an inline `data:` icon; none was tested under that CSP.
- The `text/plain` request form works on both endpoints today. If an endpoint starts answering it with an error inside a 200 response rather than a non-2xx status, the fallback will not trigger for it.
- Both endpoints are OKX's. The page has no second operator to compare against; the trust page says so.
- The rate limit header says 7 per second; a burst of 14 requests was not throttled. The real limit was not found.
- The block-map file format (`decodeBlockMap`: 7-byte runs of `firstRecord u24, count u24, blockId u8`) follows our design notes. `chips/INTERFACE.md` does not define it yet. No real block map exists, so the treemap path is covered by tests only and is not wired into a page.
- `nextId()` semantics were checked on three processors, not read from the X Layer contract source.
- The gas-per-gate figure comes from two circuits.
- Preact 11.0.0, Vite 8.3.2, vitest 5.0.3 and TypeScript 7.0.2 are the versions pnpm resolved today; nothing older was tried.

## 6. Stubs

- `#/judge` and `#/trust` are placeholders with the section titles from the design document. The three "fixed statements" on the trust page are copied from `chips/INTERFACE.md` section 13.
- No kernel pages: no vault page, settle history, audit-this-epoch, hostile chip, builder. They wait for the kernel ABI.
- Input and output bits are not named. When the pin manifest exists, the bit editor can group bits into the interface's fields.
- A REF is drawn as plain cells (one per signal it produces) with a link to the referenced circuit; there is no drill-down into the sub-circuit on the die.

## 7. Differences from the brief

1. `packages/chain` is 4,978 bytes minified as a whole, against a target of about 3 KB. The client and codec alone are 3,263; the rest is the typed call table for 20 functions, the Multicall3 reader and revert decoding. `pnpm --filter @covenant/chain size` fails above 5,120.
2. Two calls beyond the list were added: `factory.isCPU(address)` (the "registered" tag, and required to resolve a REF per TAP-20 section 3.6) and Multicall3 `getBlockNumber()` (the "read at block" line).
3. The site is two scripts, not one: see 3.4.
4. RPC requests are sent as `text/plain`: see 3.2.
5. The sweep is not linear in level number: see 3.3.
6. `addresses.json` is imported with `with { type: 'json' }` so the same module loads in Node and in Vite.
7. `nextId()` is treated as the circuit count: see 4.1.

## 8. Shared-repository incidents

- pnpm 11 refuses dependency install scripts by default. My `esbuild` devDependency (used only by `packages/chain/scripts/size.mjs`) made the first `pnpm install` print `ERR_PNPM_IGNORED_BUILDS` and append an `allowBuilds` placeholder to the root `pnpm-workspace.yaml`. I restored that file by hand once, which I should not have done to a file outside my directories; the next install appended the placeholder again. The file now reads `allowBuilds: esbuild: true`, set by someone else, and I have not touched it since.
- `pnpm exec` triggered a full workspace install once (see the note in section 2). After that I ran binaries directly or with `--config.verify-deps-before-run=false`.
- The browser tool wrote its page snapshots and console logs into the root `.playwright-mcp/` folder (already present and git-ignored).

## 9. For the next task (kernel pages)

- New read calls: build descriptors with the exported helpers in `@covenant/chain` (`word`, `addressWord`, `bytesTail`, `decUint`, ...) and read them with `readAll`. Keep one direct `read` for anything a judge should be able to reproduce with `cast`.
- Put each new heavy page behind `import()` like the circuit bench; the entry has 47 KB of room.
- The die shot for a vault is `createDieShot(canvas, netlist, { blocks })` and, per settle, `animate(previousSignals, signals, stateBefore, stateAfter)` with `signals` from `step(netlist, stateBefore, inputs).signals`.
- `chainBeat` and `sameBeat` in `src/data/circuit.ts` are the two legs of the three-way match; the third leg is the kernel record.
