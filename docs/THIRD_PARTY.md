# Third-party code and references

| Source | Licence | Where | Use |
|---|---|---|---|
| TapeOut verified contracts (`CircuitFactory`, `Circuits`, `Transistors`, `NetlistVM`, `SSTORE2`), from the OKLink verified-source API | MIT (SPDX headers) | `contracts/vendor/tapeout-xlayer/` | Reference for interfaces; test oracle; basis of the sealed evaluator port |
| IGNIX verified contracts (`IgnixManager` and libraries) | MIT (SPDX headers) | `contracts/vendor/ignix-xlayer/` | Reference for interfaces and curve math |
| TAP-20 standard, reference evaluator and vectors (TapeOutProtocol/TAPs) | CC0 (text), MIT (reference) | `chips/vendor/tap-20/` | Simulator conformance |
| OpenZeppelin Contracts v5 | MIT | `contracts/*/lib/` (not committed) | Clones, reentrancy guard, strings |
| Yosys / ABC via `yowasp-yosys` | ISC / BSD-style | Python venv (not committed) | Logic synthesis |
| Z3 | MIT | Python venv (not committed) | Proofs |
| OKX x402 seller SDK (`@okxweb3/x402-*`) | See package | `services/architect` | Paywall |

No code from other hackathon entries is used. See `docs/PRIOR_ART.md`.
