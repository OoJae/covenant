# Vendored: TAP-20 reference implementation and vectors

These files are copied, unmodified, from the TapeOut protocol's standards repository.

| | |
|---|---|
| Source | https://github.com/TapeOutProtocol/TAPs |
| Paths | `TAPs/TAP-20.md` and `assets/tap-20/{reference.py, make_vectors.py, vectors.json, popcount8_3151.hex}`, plus the repository `LICENSE` |
| Commit | `27b7a5fb6ffb0d1360dc2083ff1a34bb57db1239` (2026-10-04T15:56:06Z) |
| Fetched | 2026-10-04 with `gh api repos/TapeOutProtocol/TAPs/contents/<path>?ref=<commit>` |
| TAP-20 status at that commit | Draft, `updated: 2026-09-30` |

## Licence

Quoting the upstream `LICENSE` (copied here in full as `LICENSE`):

- "The text of every TAP in this repository, including templates, test vectors and other supporting files, is
  dedicated to the public domain under CC0 1.0 Universal." This covers `TAP-20.md`, `vectors.json` and
  `popcount8_3151.hex`.
- "Code files under assets/ (example and reference code) are licensed under the MIT License", copyright (c) 2026
  TapeOutProtocol. This covers `reference.py` and `make_vectors.py`.

## Checksums (SHA-256)

```
0e8515948981361c7db57373e8986eab63056f1ce0fad5a3ec070c1887919fa9  reference.py
15a1152fd7773613fcf1e39fb7524ab42050d8b74f6d1cf1ca4a6be4e19e0035  make_vectors.py
1a02f5cf991c130a22dc6cc6ee93d0f8fe0720afed081665fa8b8018aefd203b  vectors.json
8dc032e6c505e869e8f36ac98c801618474893b171ddbc91f0bc3d3464bb5687  popcount8_3151.hex
0b018332d30f9e30c346716f98f5a92e24171f57fc6e39c341dfd21201ef8d65  TAP-20.md
d746b74525aa20086388a05cb50eae7bc48c4ed3b896a6aea824f5ff3f089ac2  LICENSE
```

The `vectors.json` hash is the one TAP-20 itself states in its Test Cases section. Running `make_vectors.py` here
regenerates `vectors.json` byte for byte (checked on 2026-10-04 with Python 3.12.13; `popcount8_3151.hex` is vendored
only because `make_vectors.py` reads it).

## How they are used

- `reference.py` is the oracle for `chips/tools/tests/test_reference_fuzz.py`: `tapc.sim` must agree with it on
  thousands of random well-formed netlists. It is imported from this directory and never edited.
- `vectors.json` drives `chips/tools/tests/test_tap20_vectors.py` (valid, ill-formed and packing edge cases).
- `tapc` itself does not import anything from this directory at run time.

## Scope note carried over from TAP-20

TAP-20 says its chain comparison covers BNB Smart Chain only and that the X Layer contracts "were not compared".
The X Layer comparison this project relies on is its own: `tapc difftest` and the live test in
`chips/tools/tests/test_live.py`, against the evaluator source vendored at
`contracts/vendor/tapeout-xlayer/src/lib/NetlistVM.sol`.
