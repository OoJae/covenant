# Team wallets

Every wallet the team controls is listed here, and in the on-chain `TeamRegistry`. The deployer is entry 0 of the registry from the block that creates the processor; any other wallet is invited by a listed wallet and then declares itself. The keeper is invited and declares itself before its first settle. The Architect wallet acted once before it was in the registry (its OKX.AI registration, a user operation that `tools/audit-team` lists); it is invited and declares itself with the keeper.
None of them ever buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades transistors.

| Role | Address | Notes |
|---|---|---|
| Deployer, maintainer payee, token launcher | `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` | Deploys every contract, receives the 15% maintainer share, creates the reference token with first buy 0. Holds the two hostile demo chips (circuits 3 and 4), which are never bound to a kernel |
| Keeper | `0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff` | Only ever calls `KeeperTank.settleAndRefund` (or `settle` directly), after declaring itself in the registry. Funded with 0.031 OKB from the deployer. Invited into the registry by the deployer |
| Covenant Architect (OKX.AI agent wallet) | `0xbe5088307e15aaf8cf0c53bfcc4c612c9ead6da0` | Owns the OKX.AI listing of the paid compile endpoint and receives its x402 payments (USDT0). An OKX Agentic Wallet account created for Covenant only, with no history before it. An OKX Agentic Wallet can act through an EIP-7702 delegate in transactions other accounts send; the audit below sees only the transactions it signs itself, and says so |

`tools/audit-team/audit-team.ts` lists every transaction these wallets have sent and flags any call to IGNIX other than a token creation with first buy 0, any Uniswap V2 or WOKB call, any IGNIX token movement, any value sent into a kernel or its vault, and any transistor transfer. Expected: none. Its latest output is in `tools/audit-team/out/`.
