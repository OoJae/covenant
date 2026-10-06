# tools

Command-line tools for Covenant on X Layer (chain 196). Node 26 runs the `.ts` files directly; there are no npm
dependencies. Every tool only reads the chain (`eth_call`, `eth_getCode`, `eth_getBalance`, ...). None of them
holds a key, signs or sends a transaction to a real network.

| Tool | What it is for |
|---|---|
| [`launch-check/`](launch-check/NOTES.md) | The last check before a human signs the irreversible IGNIX token launch (`IgnixManager.createToken`) at ignix.bot. Two commands: `launch-check.ts` decodes the exact transaction the wallet shows and checks it against the rules and the chain; `simulate.ts` runs that exact transaction on a local fork, then binds the kernel, buys from an unrelated address, waits one epoch and settles. |
| [`audit-team/`](audit-team/NOTES.md) | Lists every transaction each declared team wallet has ever sent (a nonce walk on an archive RPC, no explorer) and flags any IGNIX trade, any call to the Uniswap V2 router or WOKB, any value sent into a kernel or its vault, any transistor transfer. The wallets are those of `docs/WALLETS.md`, the deployer, the keeper, the Architect's agent wallet, and every wallet the on-chain `TeamRegistry` lists. A wallet that is a known smart wallet (an OKX Agentic Wallet: EIP-7702 delegation to OKX's SmartWalletEntry) is not flagged for its code; its ERC-4337 user operations are found on the EntryPoints and audited like transactions. |
| [`deweb/`](deweb/NOTES.md) | Publishes the site (web/) into the DeWEB container of the probe circuit, so that https://1-2-283.tapekit.org/ serves it from the chain. `plan.ts` prints the transactions and their cost from the live chain; `verify.ts` reads the site back and compares it with the build, a second node operator and what the gateway serves; `deploy/publish-site.sh` builds, rehearses on a fork and sends (see "Publishing the site" below). |

Tests: `cd tools && node --test launch-check/test/*.test.ts audit-team/test/*.test.ts`
(kernel v2: `launch-check/test/usdt0.test.ts`, `audit-team/test/usdt0.test.ts`, offline)
(`OFFLINE=1` skips everything that needs the network; `REHEARSE=1` adds the full launch-day rehearsal against the
real contracts, see "Rehearsal" below).

## The deployment file

Both tools read the Covenant addresses from `--deployment deployments/xlayer.json`: the record the signing
sessions write, every address read back from the chain. Its sections are `deployer`, `keeper`, `issuance`
(Splitter, Circuits, Transistors, KeeperTank, TeamRegistry: signing session 1, live since 2026-10-06), `probe`, and,
once `deploy/launch-kernel.sh` (signing session 2) has run, `evaluator` (SealedVM, Fab), `core` (KernelFactory,
Kernel implementation, Lens) and `flagship` (chip id, kernel). The flat file `deploy/rehearse.sh` writes to
`deploy/rehearsal.json` is read the same way. Keys the tools do not use are ignored; a key they use with the wrong
type is refused.

Kernel v2 (USD₮0 quote, `contracts/core-v2`) is signing session 3, `deploy/launch-kernel-v2.sh`; it adds `coreV2`
(KernelFactoryV2, its KernelV2 implementation, LensV2, the quote USD₮0 and its 33-bit code shift) and `flagshipV2`
(the v2 chip and kernel). `deploy/rehearse-v2.sh` writes the same in the flat format (`kernelFactoryV2`, `lensV2`,
`kernelV2`, `chipIdV2`, `quoteV2`, `quoteShiftV2`). A launch quoted in USD₮0 is checked against that v2 kernel, and
only when the file names one (`launch-check/NOTES.md`, "Kernel v2"); `audit-team` treats v2 kernels as kernels and
flags USD₮0 sent to any kernel from a team wallet; `launch-check/payto-check.ts` checks an address proposed as the
Architect's x402 `PAY_TO` (only the deployment's bound v2 kernel passes).

After the launches, `deploy/post-launch.sh` (signing session 4, "Launch day" step 6) adds `reference` and
`architectToken` (each bound token with its vault, kernel, chip, quote, creator and bind transaction, read back from
the chain), `splitterPulls` (each `Splitter.pull()`: transaction, wei to the KeeperTank and to the maintainer) and
`registryInvites` (each `TeamRegistry.invite` it sent). The tools do not read these keys yet.

Until session 2 is recorded, `launch-check` and `simulate` refuse with
`signing session 2 is not deployed yet: deployments/xlayer.json records no evaluator (...), core (...), flagship (...)`
(exit code 1): there is no kernel to launch against. `audit-team` runs without it.

## Launch day: the exact steps

Prerequisites: Node 26, Foundry (`forge`), and once:
`(cd tools/launch-check/sim && forge install foundry-rs/forge-std --no-git --root "$PWD")`.

1. **Before you open ignix.bot**, run the audit and keep its output:
   `node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json --quiet` (expected: `VERDICT: CLEAN`).
2. At ignix.bot/create, from the launcher wallet (the wallet the kernel was created for: its envelope's
   `launcher`, the deployer for the reference token), fill in the form: Directed vault, recipient = `flagship.kernel`
   of `deployments/xlayer.json`, quote OKB, buy tax 3 %, sell tax 3 %, first buy 0, anti-snipe off, no founder round.
3. Capture the transaction before the wallet is asked to sign it, in one of two ways:

   **a. From the page (preferred).** Before pressing the launch button, open the browser's developer tools on the
   ignix.bot tab (F12, Console) and paste a hook that records what the page asks the wallet to send:

   ```js
   (() => {
     const p = window.ethereum; // the provider the page uses (OKX Wallet also injects window.okxwallet)
     const request = p.request.bind(p);
     p.request = (args) => {
       if (args && args.method === 'eth_sendTransaction') {
         const tx = JSON.stringify(args.params[0]);
         console.log('eth_sendTransaction', tx);
         copy(tx); // a DevTools console helper: puts the JSON on the clipboard
       }
       return request(args);
     };
   })();
   ```

   Press the launch button; the wallet opens its confirmation popup. **Do not confirm yet.** Save the clipboard as
   `tx.json`. It holds `{"from","to","value","data", ...}` exactly as the page passed them to the wallet. (This hook
   was not tried in Edge by the author of these tools; if the page talks to the wallet another way, nothing is
   logged: use b.)

   **b. From the wallet popup.** Press the launch button. In the confirmation popup (**do not confirm yet**), note
   the address it interacts with (`to`; it must be `0x96B51c57e5346D0C0198899243cf851D1E23C309`) and the amount
   (`value`; normally `0`), open the transaction details and copy the raw hex data (the field may be called Data,
   Hex or Hex data; in MetaMask, Settings > Advanced > "Show hex data" must be on). It starts with `0xef44bdf2`.
   Save it as `calldata.txt` (line breaks from the copy do not matter). If the wallet does not let you copy it,
   reject the transaction.

4. In a terminal at the repository root:

   ```
   # a. with tx.json
   node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json --tx @tx.json
   node tools/launch-check/simulate.ts     --deployment deployments/xlayer.json --tx @tx.json

   # b. with what the popup shows (<launcher> is the wallet you are signing with)
   node tools/launch-check/launch-check.ts --deployment deployments/xlayer.json \
       --from <launcher> --to <to> --value <value> --data @calldata.txt
   node tools/launch-check/simulate.ts --deployment deployments/xlayer.json \
       --from <launcher> --to <to> --value <value> --data @calldata.txt
   ```

   `--tx` also accepts the params array or the whole `{"method":"eth_sendTransaction","params":[...]}` request;
   other keys (gas, fees) are ignored, a `chainId` other than 196 is refused, a missing `value` means 0. With b, the
   value is wei (`0`) or OKB with the unit (`0.01okb`). The first command takes a few seconds, the second about
   half a minute.
5. Check that the popup shows the same `to`, `value` and sending wallet as the file you checked. Sign only if
   **both** commands end with `VERDICT: PASS` and exit code 0, and the name, ticker and metadata URI that
   `launch-check` prints are the ones you typed. The platform's signature in the data expires (the real OB launch
   was mined 1,795 s, about 30 minutes, before the deadline it was signed with); `launch-check` refuses when fewer
   than 3 minutes remain. If time runs short, reject, reload ignix.bot and start again at step 3.
6. After the launch (the reference token CVREF here; the Architect token is launched the same way, Directed, quote
   USD₮0, recipient = `flagshipV2.kernel`, see `launch-check/NOTES.md`, "Kernel v2"), the deployer's remaining
   transactions are one command, signing session 4:

   ```
   CVREF_TOKEN=<reference token> ARCH_TOKEN=<Architect token> deploy/post-launch.sh               # checks and rehearses; sends nothing
   CVREF_TOKEN=<reference token> ARCH_TOKEN=<Architect token> deploy/post-launch.sh --broadcast   # then sends
   ```

   It binds kernel v1 to CVREF and kernel v2 to the Architect token, calls `Splitter.pull()` (the processor's mint
   proceeds: 85% to the KeeperTank, which refunds the keeper's settle gas, 15% to the maintainer) and invites the
   Architect's agent wallet into the TeamRegistry: four transactions, one keystore password each. Each token is
   optional (a bind whose token is not given is skipped), and so is every step that is done already. Before
   sending, it checks bind's preconditions on chain for each token (IGNIX's vault for it pays the kernel, is for
   that token and is quoted in native OKB for kernel v1 or USD₮0 for kernel v2; the deployer, the kernel's
   envelope launcher, created it; the token is taxed; the kernel holds its chip and is not bound), runs every
   call as an `eth_call` from the deployer, and rehearses the four steps on a local fork, where the keeper and the
   agent wallet also declare themselves and the KeeperTank refunds one settle of each bound kernel. It records the
   result in `deployments/xlayer.json` (`reference`, `architectToken`, `splitterPulls`, `registryInvites`). If it
   stops, run it again: a step that reached the chain is recorded from the chain and never sent again. Then run
   step 1 again.
7. What only other wallets can do; `deploy/post-launch.sh` prints these commands with the live balances at its end.
   You type every password and key yourself.

   - **The keeper declares itself** (it was invited at prelaunch), before the keeper service sends its first settle:

     ```
     cast wallet import covenant-keeper --interactive     # once: paste the keeper's private key, choose a password
     cast wallet address --account covenant-keeper        # must print 0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff
     cast send 0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699 "declare(string)" keeper \
       --rpc-url https://rpc.xlayer.tech --account covenant-keeper
     ```

   - **The Architect's agent wallet declares itself** once step 6 has invited it. It is an OKX Agentic Wallet, so
     through onchainos, logged in to that wallet. The calldata is `TeamRegistry.declare("architect (OKX.AI agent
     14683)")`:

     ```
     onchainos wallet contract-call --chain 196 --from 0xbe5088307e15aaf8cf0c53bfcc4c612c9ead6da0 \
       --to 0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699 \
       --input-data 0xb7baf10a0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001e61726368697465637420284f4b582e4149206167656e74203134363833290000
     ```

     The wallet pays the gas in OKB and held none on 2026-10-06: send it about 0.0001 OKB first (the call is about
     100,000 gas, 0.000002 OKB at 0.02 gwei; more through the wallet's smart-account path). If onchainos asks for a
     confirmation, read it and add `--force` only if it describes this call.
   - **The keeper service** (`services/keeper/README.md`, section 3): `KERNELS=<flagship.kernel>,<flagshipV2.kernel>`
     (the bound ones), `TANK=0xb89BCe53822a99503A937C22974F1224D9Ab6352`,
     `KEEPER_ADDRESS=0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff`. You paste `KEEPER_PRIVATE_KEY` yourself
     (`railway variable set --service covenant-keeper --skip-deploys --stdin KEEPER_PRIVATE_KEY`) and seal it; run
     the dry run first.

   Check: `cast call 0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699 "isTeam(address)(bool)" <wallet> --rpc-url
   https://rpc.xlayer.tech` prints `true` for both wallets.

### What a refusal looks like

Every check is one line. A refusal has one or more `FAIL` lines, each with the decoded value and, after `<--`,
what was expected, then a verdict that says not to sign; the exit code is 1:

```
PASS  vault recipient is the kernel: 0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356
...
FAIL  firstBuy is 0 (no team buy): 0.4 OKB (400000000000000000 wei)  <-- a first buy is executed inside createToken with the launcher's own money: a team buy
FAIL  msg.value is the listing fee alone: value 0.4 OKB (400000000000000000 wei), listingFee 0 OKB (0 wei)  <-- the value must equal the listing fee; anything above it is spent on a first buy
...
VERDICT: FAIL. 2 of 34 checks failed or could not be performed. DO NOT SIGN this transaction.
```

(from the rehearsal; a pass ends with `VERDICT: PASS. All 34 checks passed.`)

A check that could not be performed (node unreachable, no deployment file, a kernel that does not answer) is a
`FAIL ... NOT CHECKED` line, never a pass. The simulation fails with the first thing that went wrong:

```
FAIL  sim: the vault RECIPIENT is not the kernel

VERDICT: FAIL. The simulated launch did not complete. DO NOT SIGN this transaction.
```

Exit codes, both commands: 0 pass, 1 refused or could not run, 2 called wrongly (nothing was checked; never a
pass). `launch-check --json` prints the same result for a program.

## Publishing the site (DeWEB)

```
deploy/publish-site.sh                 build the site of HEAD, plan, rehearse on a local fork, read back. Sends nothing
deploy/publish-site.sh --broadcast     the same, then send (keystore covenant-deployer, one password), record in
                                       deployments/xlayer.json under .site, and check the live gateway
MONTHS=3 deploy/publish-site.sh ...    months of name activation (default 1)
```

The site goes into circuit 1 of Covenant's processor (processor number 283): container
`0x911350102b2D81a1E8A816638D429a16b80B8Ee2`, name `1.2.283.tape`, served at **https://1-2-283.tapekit.org/**.
The first publication is 17 transactions: opening the container (0.08 OKB), the files (about 0.001 OKB of gas in all)
and one month of the name (0.026 OKB): **about 0.107 OKB**; each further month 0.026 OKB. A later run sends only what
changed. A run that stopped is recovered from the chain and nothing that reached it is sent again. Details, and what
was verified: `deweb/NOTES.md`. Check any time: `node tools/deweb/verify.ts --site 1-2-283`.

## Rehearsal

`REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts` (about 4 to 6 minutes) runs `deploy/rehearse.sh`,
which rehearses on a local anvil fork whatever `deployments/xlayer.json` does not yet record on chain (today:
SealedVM, Fab, KernelFactory, Lens, the flagship chip and its kernel), in its own scratch copy of the contracts. The
test keeps that fork running, replaces the IGNIX platform signer in the fork's storage by a test signer, builds the
createToken calldata for the rehearsal's kernel, runs both launch-day commands on it (they must pass, with the flat
rehearsal file and with `deployments/xlayer.json` completed by the rehearsed session 2, with `--tx` and with the
separate flags), corrupts each field one at a time (each must be refused), sends the transaction to the local fork,
binds, runs both commands again (refused: the kernel is bound) and runs `audit-team` against the fork. It restores
`deploy/rehearsal.json` and kills the node at the end, and writes a transcript of every command; see
`launch-check/NOTES.md`.

`REHEARSE=1 node --test tools/launch-check/test/rehearsal-v2.test.ts` does the same for kernel v2: `deploy/rehearse-v2.sh`
deploys KernelFactoryV2, LensV2 and the Flow Governor's v2 kernel (its plan goes to a scratch file), both commands must
pass on a USD₮0-quoted launch and refuse the refusal matrix of the new quote, the launch is sent to the fork and bound,
an unrelated buyer and an unrelated payer move USD₮0, the keeper (dry run) and the live KeeperTank settle the v2
kernel, and `audit-team` runs against the fork. It needs `services/keeper/node_modules` (`pnpm install`).
