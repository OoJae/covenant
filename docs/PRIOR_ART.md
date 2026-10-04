# Prior art and what is different here

We read the public repositories of other entries to this hackathon as landscape research. No code from any of them is used in this repository. Credit where it is due:

| Project | What it already does | Where Covenant differs |
|---|---|---|
| **Stego** | An ERC-4626 vault whose withdraw, drawdown and allocation rules are 112-246-gate circuits called on-chain; bonded policy authorship; a large test suite | Covenant routes an IGNIX token's own trading tax through the Directed vault, with a sequential chip whose latch state the kernel persists between epochs |
| **Nandout** | A rule DSL compiled to NAND/LATCH circuits that gate IGNIX launches, token locks and Uniswap v4 hook fees; an ownerless evaluator over frozen netlist snapshots | Same idea of a sealed evaluator (credit to Nandout for doing it first). Covenant's chip computes quantities (shares of money) from inputs the kernel assembles itself, rather than allow/deny on attested inputs |
| **TapeID** | One-click IGNIX coin per circuit; a Tax Distribution vault sends tax to the circuit's container. Its "21 NAND Driver" was distilled from a learned gate network | In Covenant the circuit's output decides the routing every epoch; in TapeID the split is fixed and the circuit is not evaluated |
| **Circuit Commons** | Circuit "Pods", a paid evaluation router with receipts, real paid calls | Covenant is a vault runtime, not a paid-call router |
| **ignix BURST** | A buyback-and-burn engine for IGNIX tokens that tapes out a fixed circuit per ignition | Covenant's buy-and-lock amount is decided by the chip from stored state |
| **Fabrica** | Verilog-to-NAND compilation with SAT equivalence, circuits optimised for gate count | Covenant uses the same standard tools (Yosys, ABC, SAT) for a different purpose |

What we believe is new in this field, stated narrowly: a taped-out chip with persisted multi-latch state that computes how an IGNIX Directed vault's tax is routed, behind a kernel with no admin, and a processor whose creator is a contract that enforces the split of mint proceeds.

Adoption today is zero. Flows on the reference token are small and are reported as they are.
