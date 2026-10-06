# Team wallets

Every wallet the team controls is listed here and in the on-chain `TeamRegistry` before it acts. The deployer is entry 0 of the registry from the block that creates the processor; any other wallet is invited by a listed wallet and then declares itself.
None of them ever buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades transistors.

| Role | Address | Notes |
|---|---|---|
| Deployer, maintainer payee, token launcher | `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` | Deploys every contract, receives the 15% maintainer share, creates the reference token with first buy 0 |
| Keeper | `0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff` | Only ever calls `KeeperTank.settleAndRefund` (or `settle` directly). Funded with 0.031 OKB from the deployer |

`tools/audit_team.ts` lists every call these wallets have made to IGNIX and every transfer into a kernel. Expected: none.
