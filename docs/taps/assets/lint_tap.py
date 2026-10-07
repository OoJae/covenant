"""Check a TAP draft against the format of the TAPs repository (TAP-01 section 7, TAP-template.md, CONTRIBUTING
section 4).

What it checks, in this order:
  front matter   the keys of TAP-01 section 7.1, in the template's order, each once; the required ones present;
                 `tap` is TBD or a number; `description` is one sentence; `author` is `Name (@handle)`, comma
                 separated; `discussions-to` is a URL; `status`, `type`, `created`, `requires` and `license` are
                 well formed
  heading        exactly one level-1 heading, `# TAP-TBD: <title>` (or `# TAP-<nn>: <title>`)
  sections       the level-2 headings are the template's sections, in the template's order, each at most once,
                 and the required ones are present (TAP-01 section 7.2)
  Summary        one paragraph of one sentence, without key words
  key words      the RFC 2119 key words in capitals appear only in the Specification, which carries the
                 template's sentence about them; inline code and fenced code are not searched
  requires       every TAP that the Specification cites is listed in `requires`
  names          TAP names have at least two digits; a renumbered name appears only in its historical note
  leftovers      no template comment (`<!--`) and no Copyright line other than the template's

Placeholders such as <NAME> or <ISSUE-URL> are warnings; with --posting they are errors, because nothing may be
posted with one.

Run:   python3 docs/taps/assets/lint_tap.py docs/taps/tap-draft-*.md
       python3 docs/taps/assets/lint_tap.py --template <TAPs clone>/TAP-template.md --posting <file>
With --template the keys and sections are read from that file instead of the copy below (TAP-template.md of
TapeOutProtocol/TAPs at commit 075dd834a72c4c5b251d97f183cac9d42d8ccd66). Exit status 0 means no errors.
Python 3.9 or later, no dependencies.
"""
from __future__ import annotations

import argparse
import datetime
import re
import sys

sys.dont_write_bytecode = True

# TAP-template.md at 075dd834: front matter keys and level-2 sections, in order. TAP-01 section 7.1 adds the
# optional keys `updated`, `version`, `supersedes` and `superseded-by`; they are placed where TAP-01 lists them.
TEMPLATE_KEYS = ["tap", "title", "description", "author", "discussions-to", "status", "type", "created",
                 "requires", "license"]
OPTIONAL_KEYS = {"updated": "created", "version": "updated", "supersedes": "requires",
                 "superseded-by": "supersedes"}          # key -> the key it follows
REQUIRED_KEYS = ["tap", "title", "description", "author", "discussions-to", "status", "type", "created", "license"]
TEMPLATE_SECTIONS = ["Summary", "Abstract", "Motivation", "Specification", "Rationale", "Backwards Compatibility",
                     "Test Cases", "Reference Implementation", "Deployments", "Security Considerations", "Copyright"]
STATUSES = ["Idea", "Draft", "Review", "Candidate", "Final", "Living", "Stagnant", "Withdrawn"]
TYPES = ["Standards", "Application", "Information", "Process"]
KEYWORD_SENTENCE = ('The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", '
                    '"RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted '
                    'as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.')
COPYRIGHT = "Copyright and related rights waived via [CC0](../LICENSE)."
KEYWORD_RE = re.compile(r"\b(MUST NOT|MUST|REQUIRED|SHALL NOT|SHALL|SHOULD NOT|SHOULD|NOT RECOMMENDED|RECOMMENDED|"
                        r"MAY|OPTIONAL)\b")
PLACEHOLDER_RE = re.compile(r"<[A-Z][A-Z0-9_-]*>")
TAP_NAME_RE = re.compile(r"\bTAP-(\d+)\b")
# A renumbered TAP: its old name may appear only on a line that carries the historical note.
RENUMBERED = {"TAP-20": ("TAP-02", "until PR #45")}
ABBREVIATIONS = ("e.g.", "i.e.", "etc.", "vs.", "cf.", "No.")


class Report:
    def __init__(self, path: str, posting: bool):
        self.path, self.posting, self.errors, self.warnings = path, posting, [], []

    def error(self, line: int, msg: str) -> None:
        self.errors.append((line, msg))

    def warn(self, line: int, msg: str) -> None:
        self.warnings.append((line, msg))

    def placeholder(self, line: int, msg: str) -> None:
        (self.error if self.posting else self.warn)(line, msg)

    def print(self) -> None:
        for line, msg in sorted(self.errors):
            print(f"{self.path}:{line}: error: {msg}")
        for line, msg in sorted(self.warnings):
            print(f"{self.path}:{line}: warning: {msg}")
        print(f"{self.path}: {len(self.errors)} error(s), {len(self.warnings)} warning(s)")


def read_template(path: str):
    """Front matter keys and level-2 sections of a TAP-template.md, in order."""
    text = open(path, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        sys.exit(f"{path}: no front matter")
    keys = [ln.split(":", 1)[0].strip() for ln in m.group(1).splitlines() if ":" in ln]
    sections = re.findall(r"^## (.+?)\s*$", text, re.M)
    return keys, sections


def strip_code(lines: list) -> list:
    """The lines with fenced code blocks blanked and inline code spans removed (line numbers are kept)."""
    out, fenced = [], False
    for ln in lines:
        if ln.lstrip().startswith("```"):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else re.sub(r"`[^`]*`", "", ln))
    return out


def sentence_breaks(text: str) -> list:
    """Positions where one sentence ends inside the text and another begins."""
    t = re.sub(r"`[^`]*`", "x", text)
    found = []
    for m in re.finditer(r"[.!?](?=\s+[A-Z(\"'])", t):
        before = t[:m.end()]
        if any(before.endswith(a) for a in ABBREVIATIONS):
            continue
        found.append(m.start())
    return found


def one_sentence(text: str) -> bool:
    text = text.strip()
    return bool(text) and text[-1] in ".!?" and not sentence_breaks(text)


def lint(path: str, template_keys: list, template_sections: list, posting: bool) -> Report:
    r = Report(path, posting)
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        r.error(1, "not valid UTF-8")
        return r
    if text.startswith("﻿"):
        r.error(1, "starts with a byte order mark")
    if "\r" in text:
        r.error(1, "has CR line endings")
    if not text.endswith("\n"):
        r.warn(text.count("\n") + 1, "no newline at the end of the file")
    lines = text.split("\n")

    # ------------------------------------------------------------------------------------------- front matter
    if not lines or lines[0] != "---":
        r.error(1, "the file does not start with front matter (`---`)")
        return r
    try:
        end = lines.index("---", 1)
    except ValueError:
        r.error(1, "the front matter is not closed with `---`")
        return r
    fm, order = {}, []
    for i in range(1, end):
        ln = lines[i]
        m = re.match(r"^([a-z][a-z-]*): (.*)$", ln)
        if not m:
            r.error(i + 1, f"front matter line is not `key: value`: {ln!r}")
            continue
        k, v = m.group(1), m.group(2).strip()
        if k in fm:
            r.error(i + 1, f"front matter key `{k}` is repeated")
            continue
        fm[k] = (v, i + 1)
        order.append(k)
    allowed = list(template_keys)
    for k, after in OPTIONAL_KEYS.items():
        if k not in allowed:
            pos = allowed.index(after) + 1 if after in allowed else len(allowed) - 1
            allowed.insert(pos, k)
    for k in order:
        if k not in allowed:
            r.error(fm[k][1], f"front matter key `{k}` is not one of TAP-01 section 7.1")
    known = [k for k in order if k in allowed]
    if known != sorted(known, key=allowed.index):
        r.error(2, "front matter keys are not in the template's order: " + ", ".join(known)
                + "; expected " + ", ".join(k for k in allowed if k in known))
    for k in REQUIRED_KEYS:
        if k not in fm:
            r.error(end + 1, f"front matter key `{k}` is missing")

    def val(k):
        return fm.get(k, ("", end + 1))

    v, ln = val("tap")
    if "tap" in fm and not (v == "TBD" or re.fullmatch(r"[1-9][0-9]*", v)):
        r.error(ln, "`tap` is neither TBD nor a plain number")
    title, ln = val("title")
    if "title" in fm:
        if TAP_NAME_RE.search(title) or re.search(r"\bTAP\b", title):
            r.error(ln, "`title` contains a TAP number")
        if len(title) > 60:
            r.warn(ln, f"`title` is {len(title)} characters; the template asks for a short title")
    v, ln = val("description")
    if "description" in fm and not one_sentence(v):
        r.error(ln, "`description` is not one sentence")
    if "description" in fm and KEYWORD_RE.search(v):
        r.error(ln, "`description` uses an RFC 2119 key word")
    v, ln = val("author")
    if "author" in fm:
        for a in [x.strip() for x in v.split(",")]:
            if not re.fullmatch(r"[^,()]+ \(@[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\)", a):
                r.error(ln, f"author entry is not `Name (@handle)`: {a!r}")
    v, ln = val("discussions-to")
    if "discussions-to" in fm and not PLACEHOLDER_RE.fullmatch(v) and not re.fullmatch(r"https://\S+", v):
        r.error(ln, "`discussions-to` is not a URL")
    v, ln = val("status")
    if "status" in fm and v not in STATUSES:
        r.error(ln, f"`status` is not one of {', '.join(STATUSES)}")
    if "status" in fm and val("tap")[0] == "TBD" and v != "Draft":
        r.error(ln, "a draft without a number has `status: Draft`")
    tap_type, ln = val("type")
    if "type" in fm and tap_type not in TYPES:
        r.error(ln, f"`type` is not one of {', '.join(TYPES)}")
    for k in ("created", "updated"):
        v, ln = val(k)
        if k in fm:
            try:
                datetime.date.fromisoformat(v)
            except ValueError:
                r.error(ln, f"`{k}` is not an ISO 8601 date")
    requires, ln = val("requires")
    required_taps = set()
    if "requires" in fm:
        for x in [x.strip() for x in requires.split(",")]:
            if re.fullmatch(r"TAP-\d{2,}", x):
                required_taps.add(x)
            elif re.fullmatch(r"TAP-\d", x):
                r.error(ln, f"`requires` names {x}; TAP names have at least two digits")
            elif not re.search(r"\d", x):
                r.warn(ln, f"`requires` entry {x!r} is neither a TAP nor a specification with a version")
    v, ln = val("license")
    if "license" in fm and v != "CC0-1.0":
        r.error(ln, "`license` is not CC0-1.0")
    for k in order:
        v, ln = fm[k]
        for p in PLACEHOLDER_RE.findall(v):
            r.placeholder(ln, f"`{k}` still holds the placeholder {p}")

    # ------------------------------------------------------------------------------------------- body
    body = lines[end + 1:]
    base = end + 2                                       # line number of body[0]
    plain = strip_code(body)
    h1 = [(i, ln) for i, ln in enumerate(plain) if ln.startswith("# ")]
    if len(h1) != 1:
        r.error(base, f"{len(h1)} level-1 headings; expected one")
    else:
        i, ln = h1[0]
        number = val("tap")[0]
        name = "TAP-TBD" if number in ("TBD", "") else f"TAP-{int(number):02d}"
        if ln != f"# {name}: {title}":
            r.error(base + i, f"the heading is not `# {name}: {title}`")

    sections = [(i, ln[3:].strip()) for i, ln in enumerate(plain) if ln.startswith("## ")]
    names = [s for _, s in sections]
    for i, s in sections:
        if s not in template_sections:
            r.error(base + i, f"section `{s}` is not a section of the template")
        elif names.count(s) > 1:
            r.error(base + i, f"section `{s}` appears more than once")
    known = [s for s in names if s in template_sections]
    if known != sorted(known, key=template_sections.index):
        r.error(base, "sections are not in the template's order: " + ", ".join(known))
    required = ["Summary", "Abstract", "Motivation", "Specification", "Rationale", "Copyright"]
    if tap_type != "Information":
        required.append("Security Considerations")
    if tap_type == "Standards":
        required.append("Test Cases")
    for s in required:
        if s not in names:
            r.error(base, f"required section `{s}` is missing")

    def span(name):
        """Body indices [start, stop) of a section's content, or None."""
        for k, (i, s) in enumerate(sections):
            if s == name:
                return i + 1, sections[k + 1][0] if k + 1 < len(sections) else len(body)
        return None

    sp = span("Summary")
    if sp:
        paras = [p.strip() for p in "\n".join(body[sp[0]:sp[1]]).split("\n\n") if p.strip()]
        if len(paras) != 1:
            r.error(base + sp[0], f"the Summary has {len(paras)} paragraphs; expected one sentence")
        elif not one_sentence(" ".join(paras[0].split())):
            r.error(base + sp[0], "the Summary is not one sentence")

    spec = span("Specification")
    in_spec = (lambda i: spec[0] <= i < spec[1]) if spec else (lambda i: False)
    for i, ln in enumerate(plain):
        if in_spec(i) or ln.startswith("#"):
            continue
        for m in KEYWORD_RE.finditer(ln):
            r.error(base + i, f"the key word {m.group(1)} is used outside the Specification")
    for i, ln in enumerate(plain):
        if ln.startswith("#"):
            for m in KEYWORD_RE.finditer(ln):
                r.error(base + i, f"the key word {m.group(1)} is used in a heading")
    if spec:
        spec_text = "\n".join(body[spec[0]:spec[1]])
        if KEYWORD_SENTENCE not in spec_text:
            r.error(base + spec[0], "the Specification does not carry the template's sentence on key words")
        cited = set()
        for i in range(*spec):
            for m in TAP_NAME_RE.finditer(plain[i]):
                cited.add(f"TAP-{int(m.group(1)):02d}")
        own = val("tap")[0]
        own = f"TAP-{int(own):02d}" if own.isdigit() else None
        missing = sorted(cited - required_taps - {own})
        if missing:
            r.error(base + spec[0], "the Specification cites " + ", ".join(missing) + ", which `requires` does not list")

    for i, ln in enumerate(lines):
        for m in TAP_NAME_RE.finditer(ln):
            if len(m.group(1)) < 2:
                r.error(i + 1, f"TAP-{m.group(1)}: TAP names have at least two digits")
        for old, (new, note) in RENUMBERED.items():
            if re.search(rf"\b{re.escape(old)}\b", ln) and note not in ln:
                r.error(i + 1, f"{old} is now {new}; the old name belongs only in the note \"{note}\"")
    notes = [i for i, ln in enumerate(lines) for old, (_, note) in RENUMBERED.items() if old in ln and note in ln]
    if len(notes) > 1:
        r.warn(notes[1] + 1, f"{len(notes)} historical notes on renumbering; one is enough")

    for i, ln in enumerate(lines):
        if "<!--" in ln:
            r.error(i + 1, "a template comment is left in the text")
    for i, ln in enumerate(strip_code(lines)):
        if i <= end:
            continue
        for p in PLACEHOLDER_RE.findall(ln):
            r.placeholder(i + 1, f"placeholder {p} in the text")
        if re.search(r"will be added before|<link", ln):
            r.placeholder(i + 1, "a link that is still to be added")
    cp = span("Copyright")
    if cp:
        content = [ln.strip() for ln in body[cp[0]:cp[1]] if ln.strip()]
        if content != [COPYRIGHT]:
            r.error(base + cp[0], f"the Copyright section is not exactly: {COPYRIGHT}")
    return r


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--template", help="a TAP-template.md to take the keys and sections from")
    ap.add_argument("--posting", action="store_true", help="treat placeholders as errors")
    args = ap.parse_args(argv)
    keys, sections = TEMPLATE_KEYS, TEMPLATE_SECTIONS
    if args.template:
        keys, sections = read_template(args.template)
        if (keys, sections) != (TEMPLATE_KEYS, TEMPLATE_SECTIONS):
            print(f"note: {args.template} differs from the copy in lint_tap.py; using {args.template}")
    failed = 0
    for path in args.files:
        rep = lint(path, keys, sections, args.posting)
        rep.print()
        failed += bool(rep.errors)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
