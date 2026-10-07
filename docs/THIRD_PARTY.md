# Third-party code and references

| Source | Licence | Where | Use |
|---|---|---|---|
| TapeOut verified contracts (`CircuitFactory`, `Circuits`, `Transistors`, `NetlistVM`, `SSTORE2`), from the OKLink verified-source API | MIT (SPDX headers) | `contracts/vendor/tapeout-xlayer/` | Reference for interfaces; test oracle; basis of the sealed evaluator port |
| IGNIX verified contracts (`IgnixManager` and libraries) | MIT (SPDX headers) | `contracts/vendor/ignix-xlayer/` | Reference for interfaces and curve math |
| TAP-20 standard, reference evaluator and vectors (TapeOutProtocol/TAPs) | CC0 (text), MIT (reference) | `chips/vendor/tap-20/`, `packages/tap20/test/fixtures/tap20-vectors.json` | Simulator conformance |
| OpenZeppelin Contracts v5 | MIT | `contracts/*/lib/` (not committed) | Clones, reentrancy guard, strings |
| Yosys / ABC via `yowasp-yosys` | ISC / BSD-style | Python venv (not committed) | Logic synthesis |
| Z3 | MIT | Python venv (not committed) | Proofs |
| OKX x402 seller SDK (`@okxweb3/x402-*`) | See package | `services/architect` | Paywall |
| Bodoni Moda (roman and italic, variable), © 2020 The Bodoni Moda Project Authors, from github.com/google/fonts `ofl/bodonimoda` | SIL OFL 1.1, no Reserved Font Name (`web/src/fonts/OFL-BodoniModa.txt`) | `web/src/fonts/bodoni-moda-*.woff2` (subset, instanced; `docs/brand/tools/build_fonts.py`); outlined in `docs/brand/wordmark-*.svg` and `lockup-*.svg` | Display type; the wordmark |
| Instrument Sans (variable), © 2022 The Instrument Sans Project Authors, from github.com/google/fonts `ofl/instrumentsans` | SIL OFL 1.1, no Reserved Font Name (`web/src/fonts/OFL-InstrumentSans.txt`) | `web/src/fonts/instrument-sans.woff2` (subset, instanced) | Body and UI type |
| Fragment Mono Regular, © 2022 The Fragment-Mono Project Authors, from github.com/google/fonts `ofl/fragmentmono` | SIL OFL 1.1, no Reserved Font Name (`web/src/fonts/OFL-FragmentMono.txt`) | `web/src/fonts/fragment-mono.woff2` (subset) | Data, labels, die markings |

No code from other hackathon entries is used. See `docs/PRIOR_ART.md`.
