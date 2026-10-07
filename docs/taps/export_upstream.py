"""Lay the two TAP drafts out the way the TAPs repository (TapeOutProtocol/TAPs) expects them, in a clone of it.

    python3 docs/taps/export_upstream.py <TAPs clone> [--draft stateful-consumers|circuit-pin-manifest|all]
        [--author-name NAME] [--discussions-to URL] [--python PYTHON] [--posting]

For each selected draft it writes (CONTRIBUTING section 2, TAP-01 section 6.2, editors' queue issue #31):

    TAPs/TAP-draft-<short-title>.md          the text, from docs/taps/tap-draft-<short-title>.md
    assets/tap-draft-<short-title>/          its asset files, from docs/taps/assets/

and then, inside the clone:

    1. runs each copied generator with TAP02_REFERENCE_DIR unset, so that it must find the TAPs repository's own
       assets/tap-02/reference.py through ../tap-02, and requires that it used that file;
    2. requires every file a generator writes to be byte-identical to the copy from this repository;
    3. runs check_assets.py (the pin-manifest draft; needs `jsonschema`, see --python);
    4. runs lint_tap.py on each exported text against the clone's TAP-template.md.

--author-name and --discussions-to fill the placeholders <NAME> and <ISSUE-URL> in the exported text only; the
texts in this repository keep them. --discussions-to needs a single --draft. With --posting, a placeholder that is
left is an error.

It writes only the files listed in EXPORTS, never deletes anything, and runs no git command and no network call.
Exit status 0 means every step passed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # docs/taps
ASSETS = os.path.join(HERE, "assets")
LINT = os.path.join(ASSETS, "lint_tap.py")

# short title -> (asset files, generators: script -> the files it writes, run check_assets.py)
EXPORTS = {
    "circuit-pin-manifest": (
        ["pin-manifest.schema.json", "pins_reference.py", "make_manifest_vectors.py", "check_assets.py",
         "shift-toggle.pins.json", "manifest-vectors.json", "covenant-v1.pins.json", "covenant-v1.vectors.json"],
        {"make_manifest_vectors.py": ["shift-toggle.pins.json", "manifest-vectors.json"]},
        True),
    "stateful-consumers": (
        ["replay_reference.py", "make_replay_vectors.py", "replay-vectors.json", "ReferenceConsumer.sol",
         "deployments-check.json"],
        {"make_replay_vectors.py": ["replay-vectors.json"]},
        False),
}


def sha256(path: str) -> str:
    with open(path, "rb") as f:
        return "0x" + hashlib.sha256(f.read()).hexdigest()


def default_python() -> str:
    venv = os.path.join(HERE, ".venv", "bin", "python")
    return venv if os.path.isfile(venv) else sys.executable


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Export the TAP drafts into a clone of TapeOutProtocol/TAPs.")
    ap.add_argument("target", help="a clone (or fork clone) of TapeOutProtocol/TAPs")
    ap.add_argument("--draft", choices=sorted(EXPORTS) + ["all"], default="all")
    ap.add_argument("--author-name", help="replaces <NAME> in the exported text")
    ap.add_argument("--discussions-to", help="replaces <ISSUE-URL> in the exported text (one draft only)")
    ap.add_argument("--python", default=default_python(), help="interpreter for the generators and checks")
    ap.add_argument("--posting", action="store_true", help="lint with placeholders as errors")
    args = ap.parse_args(argv)

    target = os.path.abspath(args.target)
    template = os.path.join(target, "TAP-template.md")
    upstream_ref = os.path.join(target, "assets", "tap-02", "reference.py")
    for need in (template, os.path.join(target, "TAPs"), upstream_ref):
        if not os.path.exists(need):
            print(f"{target} does not look like a clone of TapeOutProtocol/TAPs: {os.path.relpath(need, target)} is missing")
            return 2
    drafts = sorted(EXPORTS) if args.draft == "all" else [args.draft]
    if args.discussions_to and len(drafts) != 1:
        print("--discussions-to applies to one draft; pass --draft as well")
        return 2

    failures = 0
    print(f"TAP-02 reference in the clone: {upstream_ref} {sha256(upstream_ref)}")
    for short in drafts:
        files, generators, run_checks = EXPORTS[short]
        text_src = os.path.join(HERE, f"tap-draft-{short}.md")
        text_dst = os.path.join(target, "TAPs", f"TAP-draft-{short}.md")
        asset_dir = os.path.join(target, "assets", f"tap-draft-{short}")
        os.makedirs(asset_dir, exist_ok=True)

        text = open(text_src, encoding="utf-8").read()
        if args.author_name:
            text = text.replace("<NAME>", args.author_name)
        if args.discussions_to:
            text = text.replace("<ISSUE-URL>", args.discussions_to)
        with open(text_dst, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"\n== {short}\nwrote TAPs/TAP-draft-{short}.md {sha256(text_dst)}")
        for name in files:
            shutil.copyfile(os.path.join(ASSETS, name), os.path.join(asset_dir, name))
            print(f"wrote assets/tap-draft-{short}/{name} {sha256(os.path.join(asset_dir, name))}")

        env = {k: v for k, v in os.environ.items() if k != "TAP02_REFERENCE_DIR"}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        for script, outputs in generators.items():
            res = subprocess.run([args.python, "-B", os.path.join(asset_dir, script)], cwd=asset_dir, env=env,
                                 capture_output=True, text=True)
            used = [ln for ln in res.stdout.splitlines() if ln.startswith("TAP-02 reference:")]
            if res.returncode != 0:
                failures += 1
                print(f"FAIL {script} exited {res.returncode}\n{res.stdout}{res.stderr}")
                continue
            used_path = used[0].split("reference: ", 1)[1].rsplit(" sha256 ", 1)[0] if used else ""
            if os.path.realpath(used_path) != os.path.realpath(upstream_ref):
                failures += 1
                print(f"FAIL {script} did not use the clone's assets/tap-02/reference.py ({used_path or 'not reported'})")
            else:
                print(f"ok   {script} ran with the clone's assets/tap-02/reference.py")
            for out in outputs:
                mine, theirs = os.path.join(ASSETS, out), os.path.join(asset_dir, out)
                if open(mine, "rb").read() == open(theirs, "rb").read():
                    print(f"ok   {out} regenerated byte for byte ({sha256(theirs)})")
                else:
                    failures += 1
                    print(f"FAIL {out} regenerated in the clone differs from docs/taps/assets/{out}")
        if run_checks:
            res = subprocess.run([args.python, "-B", os.path.join(asset_dir, "check_assets.py")], cwd=asset_dir,
                                 env=env, capture_output=True, text=True)
            print(res.stdout.rstrip())
            if res.returncode != 0:
                failures += 1
                print(f"FAIL check_assets.py exited {res.returncode}\n{res.stderr}")
        lint = [args.python, "-B", LINT, "--template", template] + (["--posting"] if args.posting else []) + [text_dst]
        res = subprocess.run(lint, capture_output=True, text=True)
        print(res.stdout.rstrip())
        if res.returncode != 0:
            failures += 1
            print(f"FAIL lint_tap.py\n{res.stderr}")

    print(f"\n{'all steps passed' if not failures else f'{failures} step(s) failed'}; nothing was committed or pushed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
