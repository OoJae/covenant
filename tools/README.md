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
6. After the launch: bind the kernel (anyone may call `bind(token)` for a token its launcher created), and run
   step 1 again.

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
