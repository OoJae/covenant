"""Check the assets of the TAP draft "Circuit Pin Manifest": pinned digests, the JSON Schema and the reference
validator.

Needs the `jsonschema` package (4.x) for the schema part:
    python3 -m venv .venv && .venv/bin/pip install jsonschema
    .venv/bin/python check_assets.py

What it checks:
  0. covenant-v1.pins.json, shift-toggle.pins.json and pin-manifest.schema.json have exactly the SHA-256 digests
     below (this part needs nothing but the standard library and runs first);
  1. pin-manifest.schema.json is itself a valid draft 2020-12 schema;
  2. covenant-v1.pins.json and shift-toggle.pins.json pass the schema and pins_reference.validate();
  3. every manifest listed as valid in manifest-vectors.json passes both;
  4. every manifest listed as invalid is refused by pins_reference.validate(); the script reports how many
     of them the schema alone refuses (the rest break rules a schema cannot express, see its description).
Exit status 0 means all of them hold.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pins_reference as P         # noqa: E402

# Files whose bytes must never change.
#   covenant-v1.pins.json   A profile is identified by its digest (draft section 6.1), and this one is claimed by
#                           digest in circuit manifests whose own SHA-256 was recorded on chain when their chips
#                           were taped out. Changing one byte makes a different profile and breaks those claims.
#                           A new version of the profile is a new file.
#   shift-toggle.pins.json  Its digest is printed in the draft's Test Cases.
#   pin-manifest.schema.json  Pinned for this revision of the draft, so that a change to the schema is deliberate:
#                           when it is, change the digest here in the same commit.
PINNED = {
    "covenant-v1.pins.json": "0x77a721cda1c499ae4ffcad1a02a9bbb75bfce2a5773e587adbc77bd660756eb5",
    "shift-toggle.pins.json": "0x990990d0522a05d95881ae22eab2798d5dcb9f8e49236e97968bca6b26a0237a",
    "pin-manifest.schema.json": "0xeb5c7df2482277369b4c99f86385d57547b3c0adc001031ffe13fb2bb0442033",
}
COVENANT_PREFIX = "0x77a721cd"


def load(name):
    with open(os.path.join(HERE, name), "rb") as f:
        return f.read()


def check_pinned() -> int:
    failures = 0
    for name, want in PINNED.items():
        got = "0x" + hashlib.sha256(load(name)).hexdigest()
        if got != want:
            failures += 1
            print(f"FAIL {name}: sha256 {got}, expected {want}")
        else:
            print(f"ok   {name}: sha256 {got}")
    got = "0x" + hashlib.sha256(load("covenant-v1.pins.json")).hexdigest()
    if not got.startswith(COVENANT_PREFIX):
        failures += 1
        print(f"FAIL covenant-v1.pins.json: sha256 does not start with {COVENANT_PREFIX}")
    return failures


def main() -> int:
    failures = check_pinned()
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        print("jsonschema is not installed; see the first lines of this file")
        return 1

    schema = json.loads(load("pin-manifest.schema.json"))
    Draft202012Validator.check_schema(schema)
    v = Draft202012Validator(schema)

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
    if failures:
        print(f"{failures} check(s) failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
