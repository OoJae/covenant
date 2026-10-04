"""Check every manifest in this directory against the JSON Schema and the reference validator.

Needs the `jsonschema` package (4.x) for the schema part:
    ~/.local/bin/python3.12 -m venv docs/taps/.venv && docs/taps/.venv/bin/pip install jsonschema
    docs/taps/.venv/bin/python docs/taps/assets/check_assets.py

What it checks:
  1. pin-manifest.schema.json is itself a valid draft 2020-12 schema;
  2. covenant-v1.pins.json and shift-toggle.pins.json pass the schema and pins_reference.validate();
  3. every manifest listed as valid in manifest-vectors.json passes both;
  4. every manifest listed as invalid is refused by pins_reference.validate(); the script reports how many
     of them the schema alone refuses (the rest break rules a schema cannot express, see its description).
Exit status 0 means all four hold.
"""
from __future__ import annotations

import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pins_reference as P         # noqa: E402

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit("jsonschema is not installed; see the first lines of this file")


def load(name):
    with open(os.path.join(HERE, name), "rb") as f:
        return f.read()


def main() -> int:
    schema = json.loads(load("pin-manifest.schema.json"))
    Draft202012Validator.check_schema(schema)
    v = Draft202012Validator(schema)
    failures = 0

    def expect(ok, what):
        nonlocal failures
        if not ok:
            failures += 1
            print("FAIL", what)

    for name in ("covenant-v1.pins.json", "shift-toggle.pins.json"):
        raw = load(name)
        doc = P.parse(raw)
        errs = [e.message for e in v.iter_errors(doc)]
        expect(not errs, f"{name}: schema: {errs[:2]}")
        expect(not P.validate(doc), f"{name}: reference validator: {P.validate(doc)[:2]}")
        print(f"ok   {name}: schema and reference validator ({len(raw)} bytes, sha256 {P.sha256(raw)})")

    vec = json.loads(load("manifest-vectors.json"))
    for f in vec["files"]:
        expect(P.sha256(load(f["file"])) == f["sha256"], f"{f['file']}: sha256 differs from manifest-vectors.json")
    for case in vec["validManifests"]:
        m = case["manifest"]
        expect(not list(v.iter_errors(m)) and not P.validate(m), f"valid case refused: {case['note']}")
    expect(not list(v.iter_errors(vec["conformance"]["profile"])), "the example profile fails the schema")
    by_schema = 0
    for case in vec["invalidManifests"]:
        m = case["manifest"]
        expect(bool(P.validate(m)), f"invalid case accepted by the reference validator: {case['note']}")
        by_schema += bool(list(v.iter_errors(m)))
    for case in vec["notManifestFiles"]:
        if "bytes" in case:
            try:
                P.parse(bytes.fromhex(case["bytes"][2:]))
                expect(False, f"file accepted: {case['note']}")
            except P.Invalid:
                pass
    print(f"ok   {len(vec['validManifests'])} valid manifests pass both; {len(vec['invalidManifests'])} invalid "
          f"manifests are refused by the reference validator, {by_schema} of them by the schema alone; "
          f"{len(vec['notManifestFiles'])} files are refused by the strict reader")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
