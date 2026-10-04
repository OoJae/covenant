"""Reference implementation for the TAP drafts "Circuit Pin Manifest" and "Stateful Circuit Consumers".

MIT licence. Pure Python 3.11+, no dependencies.

What is here, by section of the pin-manifest draft:
  parse()          strict JSON reader for a manifest file                          (section 3.1)
  validate()       every rule a manifest must satisfy                              (sections 3 to 5)
  check_binding()  does a circuit manifest describe this netlist                   (section 4)
  conforms()       does a manifest implement a profile                             (section 6)
  check_shape()    does a netlist satisfy a profile's shape constraints            (section 6.2)
  decode_vector(), encode_vector(), log_code(), log_floor()   the field codec      (section 5)
and of the stateful-consumer draft:
  state_word(), state_string(), is_canonical()   the state string and its word form  (section 3)
  replay()                                       the reader's check of a consumer's records  (section 5.3)

keccak256() is Keccak-f[1600] with the original Keccak padding byte 0x01 (the hash Ethereum uses, not
NIST SHA3-256). It follows the structure of the Keccak team's public-domain CompactFIPS202.py.
"""
from __future__ import annotations

import hashlib
import json
import re

MAX_FILE_BYTES = 65_536
MAX_PINS = 1 << 16                # TAP-20 section 2: nIn and nOut are at most 65,536
MAX_STATE = 1 << 24               # TAP-20 section 3, condition 7
MAX_SAFE = (1 << 53) - 1
FORBIDDEN_NAMES = ("__proto__", "constructor", "prototype")
ENCODINGS = ("uint", "int", "bool", "enum", "flags", "log", "zero", "bits")

VERSION_RE = re.compile(r"^0\.[1-9][0-9]*$")
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
HASH_RE = re.compile(r"^0x[0-9a-f]{64}$")
DECIMAL_RE = re.compile(r"^(0|[1-9][0-9]*)$")

# Members a field may carry, by encoding. "name", "offset", "width", "encoding", "description" and
# "unit" are allowed for every encoding.
_COMMON = {"name", "offset", "width", "encoding", "description", "unit"}
_EXTRA = {
    "uint": {"min", "max", "scale", "values"},
    "int": {"min", "max", "scale"},
    "bool": set(),
    "enum": {"values"},
    "flags": {"bits"},
    "log": {"mantissaBits", "scale", "values"},
    "zero": set(),
    "bits": set(),
}
_ENCODING_MEMBERS = {"min", "max", "scale", "values", "bits", "mantissaBits"}


class Invalid(ValueError):
    """The bytes are not a manifest file at all (section 3.1)."""


# ------------------------------------------------------------------------------------------------ hashes

def sha256(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def _rol(a: int, n: int) -> int:
    return ((a << n) | (a >> (64 - n))) & 0xFFFFFFFFFFFFFFFF if n else a


def _keccak_f(lanes: list) -> None:
    r = 1
    for _ in range(24):
        c = [lanes[x][0] ^ lanes[x][1] ^ lanes[x][2] ^ lanes[x][3] ^ lanes[x][4] for x in range(5)]
        d = [c[(x + 4) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                lanes[x][y] ^= d[x]
        x, y, cur = 1, 0, lanes[1][0]
        for t in range(24):
            x, y = y, (2 * x + 3 * y) % 5
            cur, lanes[x][y] = lanes[x][y], _rol(cur, ((t + 1) * (t + 2) // 2) % 64)
        for y in range(5):
            row = [lanes[x][y] for x in range(5)]
            for x in range(5):
                lanes[x][y] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5] & 0xFFFFFFFFFFFFFFFF)
        for j in range(7):
            r = ((r << 1) ^ ((r >> 7) * 0x71)) & 0xFF
            if r & 2:
                lanes[0][0] ^= 1 << ((1 << j) - 1)


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += bytes(-len(msg) % rate)
    msg[-1] |= 0x80
    lanes = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            lanes[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i:off + 8 * i + 8], "little")
        _keccak_f(lanes)
    return b"".join(lanes[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def netlist_hash(netlist: bytes) -> str:
    return "0x" + keccak256(netlist).hex()


# ------------------------------------------------------------------------------------------------ file (3.1)

def parse(data: bytes) -> dict:
    """Read a manifest file. Raises Invalid for anything section 3.1 rules out."""
    if len(data) > MAX_FILE_BYTES:
        raise Invalid("larger than 65,536 bytes")
    if data[:3] == b"\xef\xbb\xbf":
        raise Invalid("starts with a byte order mark")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Invalid("not valid UTF-8") from None

    def obj(pairs):
        out = {}
        for k, v in pairs:
            if k in out:
                raise Invalid(f"member name {k!r} is repeated")
            if k in FORBIDDEN_NAMES:
                raise Invalid(f"member name {k!r} is not allowed")
            out[k] = v
        return out

    def integer(s):
        if s == "-0":
            raise Invalid("negative zero")
        v = int(s)
        if abs(v) > MAX_SAFE:
            raise Invalid("integer beyond 2^53 - 1")
        return v

    def not_integer(s):
        raise Invalid(f"number {s} is written with a fraction or an exponent")

    try:
        value = json.loads(text, object_pairs_hook=obj, parse_int=integer, parse_float=not_integer,
                           parse_constant=not_integer)
    except Invalid:
        raise
    except (ValueError, RecursionError):
        raise Invalid("not JSON text") from None
    if not isinstance(value, dict):
        raise Invalid("the top-level value is not an object")

    def walk(v):
        if isinstance(v, str):
            if any(0xD800 <= ord(ch) <= 0xDFFF for ch in v):
                raise Invalid("a string has an unpaired surrogate")
        elif isinstance(v, list):
            for x in v:
                walk(x)
        elif isinstance(v, dict):
            for k, x in v.items():
                walk(k)
                walk(x)
    walk(value)
    return value


# ------------------------------------------------------------------------------------------------ rules (3-5)

def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _text(problems, where, v, limit, required=False):
    if v is None:
        if required:
            problems.append(f"{where}: missing")
        return
    if not isinstance(v, str):
        problems.append(f"{where}: not a string")
    elif len(v) > limit:
        problems.append(f"{where}: longer than {limit} code points")


def _fields(problems, what, arr, n):
    if not isinstance(arr, list):
        problems.append(f"{what}: not an array")
        return
    names, end = set(), 0
    for i, f in enumerate(arr):
        w = f"{what}[{i}]"
        if not isinstance(f, dict):
            problems.append(f"{w}: not an object")
            continue
        name, off, wid, enc = f.get("name"), f.get("offset"), f.get("width"), f.get("encoding")
        if not isinstance(name, str) or not NAME_RE.match(name) or name in FORBIDDEN_NAMES:
            problems.append(f"{w}: bad name")
        elif name in names:
            problems.append(f"{w}: name {name} is used twice")
        else:
            names.add(name)
        if not _is_int(off) or off < 0 or not _is_int(wid) or wid < 1:
            problems.append(f"{w}: offset must be >= 0 and width >= 1")
            continue
        if n is not None and off + wid > n:
            problems.append(f"{w}: bits {off}..{off + wid - 1} are outside a vector of {n} bits")
        if off < end:
            problems.append(f"{w}: overlaps the field before it, or the fields are not in offset order")
        end = max(end, off + wid)
        _text(problems, f"{w}.description", f.get("description"), 512)
        _text(problems, f"{w}.unit", f.get("unit"), 32)
        if not isinstance(enc, str):
            problems.append(f"{w}: encoding missing or not a string")
            continue
        if enc not in ENCODINGS:
            continue                                   # unknown encoding: read as "bits", nothing more to check
        for k in sorted(set(f) & _ENCODING_MEMBERS - _EXTRA[enc]):
            problems.append(f"{w}: member {k} does not belong to encoding {enc}")
        if enc == "bool" and wid != 1:
            problems.append(f"{w}: a bool field is 1 bit wide")
        lo, hi = (-(1 << (wid - 1)), (1 << (wid - 1)) - 1) if enc == "int" else (0, (1 << wid) - 1)
        for k in ("min", "max"):
            if k in f and k in _EXTRA[enc] and (not _is_int(f[k]) or not lo <= f[k] <= hi):
                problems.append(f"{w}: {k} is not an integer the field can hold")
        if _is_int(f.get("min")) and _is_int(f.get("max")) and f["min"] > f["max"]:
            problems.append(f"{w}: min is above max")
        if "scale" in f and "scale" in _EXTRA[enc]:
            s = f["scale"]
            if not (isinstance(s, list) and len(s) == 2 and all(_is_int(x) and x >= 1 for x in s)):
                problems.append(f"{w}: scale is not [numerator, denominator] with both at least 1")
        if "values" in f and "values" in _EXTRA[enc]:
            vals = f["values"]
            if not isinstance(vals, dict) or (enc == "enum" and not vals):
                problems.append(f"{w}: values is not an object, or is empty")
            else:
                for k, lab in vals.items():
                    if not DECIMAL_RE.match(k) or int(k) > hi:
                        problems.append(f"{w}: values key {k!r} is not a decimal value the field can hold")
                    if not isinstance(lab, str) or not 1 <= len(lab) <= 64:
                        problems.append(f"{w}: values label for {k!r} is not a string of 1 to 64 code points")
        elif enc == "enum":
            problems.append(f"{w}: an enum field needs values")
        if enc == "flags":
            b = f.get("bits")
            if not (isinstance(b, list) and len(b) == wid
                    and all(x is None or (isinstance(x, str) and 1 <= len(x) <= 64) for x in b)):
                problems.append(f"{w}: a flags field needs bits, one label or null per bit")
        if enc == "log":
            k = f.get("mantissaBits")
            if not _is_int(k) or not 0 <= k <= 16:
                problems.append(f"{w}: a log field needs mantissaBits from 0 to 16")


def validate(m: dict) -> list:
    """All problems found in a parsed manifest; an empty list means it is valid."""
    p: list = []
    if not isinstance(m.get("tapepins"), str) or not VERSION_RE.match(m["tapepins"]):
        p.append("tapepins: missing or not of the form 0.N")
    _text(p, "name", m.get("name"), 64)
    _text(p, "description", m.get("description"), 2048)
    n_in, n_out, n_state = m.get("nIn"), m.get("nOut"), m.get("nState")
    if not _is_int(n_in) or not 0 <= n_in <= MAX_PINS:
        p.append("nIn: not an integer from 0 to 65,536")
        n_in = None
    if not _is_int(n_out) or not 1 <= n_out <= MAX_PINS:
        p.append("nOut: not an integer from 1 to 65,536")
        n_out = None
    is_circuit = "circuit" in m
    if n_state is not None and (not _is_int(n_state) or not 0 <= n_state <= MAX_STATE):
        p.append("nState: not an integer from 0 to 16,777,216")
        n_state = None
    if is_circuit:
        c = m["circuit"]
        if not isinstance(c, dict) or not isinstance(c.get("netlistHash"), str) or not HASH_RE.match(c["netlistHash"]):
            p.append("circuit.netlistHash: missing or not 0x and 64 lowercase hex digits")
        elif "chainId" in c and (not _is_int(c["chainId"]) or c["chainId"] < 1):
            p.append("circuit.chainId: not a positive integer")
        if "nState" not in m:
            p.append("nState: required in a circuit manifest")
        if "state" not in m:
            p.append("state: required in a circuit manifest")
        if "shape" in m:
            p.append("shape: only a profile has a shape")
    else:
        if "state" in m and "nState" not in m:
            p.append("state: a profile that defines state fields must fix nState")
    if "profile" in m:
        pr = m["profile"]
        if not isinstance(pr, dict):
            p.append("profile: not an object")
        else:
            _text(p, "profile.name", pr.get("name"), 64, required=True)
            if not isinstance(pr.get("sha256"), str) or not HASH_RE.match(pr["sha256"]):
                p.append("profile.sha256: missing or not 0x and 64 lowercase hex digits")
    if "shape" in m and not is_circuit:
        s = m["shape"]
        if not isinstance(s, dict):
            p.append("shape: not an object")
        else:
            for k in ("nStateMin", "nStateMax"):
                if k in s and (not _is_int(s[k]) or not 0 <= s[k] <= MAX_STATE):
                    p.append(f"shape.{k}: not an integer from 0 to 16,777,216")
            if _is_int(s.get("nStateMin")) and _is_int(s.get("nStateMax")) and s["nStateMin"] > s["nStateMax"]:
                p.append("shape: nStateMin is above nStateMax")
            if "nState" in m and ("nStateMin" in s or "nStateMax" in s):
                p.append("shape: nStateMin and nStateMax are not used together with nState")
            for k in ("flat", "latchesFirst"):
                if k in s and not isinstance(s[k], bool):
                    p.append(f"shape.{k}: not a boolean")
            for k in ("maxGates", "maxNetlistBytes"):
                if k in s and (not _is_int(s[k]) or s[k] < 1):
                    p.append(f"shape.{k}: not a positive integer")
    for what, n, required in (("inputs", n_in, True), ("outputs", n_out, True), ("state", n_state, is_circuit)):
        if what in m:
            _fields(p, what, m[what], n)
        elif required:
            p.append(f"{what}: missing")
    return p


# ------------------------------------------------------------------------------------------------ netlists

def scan(netlist: bytes) -> dict:
    """Counts of a TAP-20 netlist from its bytes alone, and whether it is latches-first."""
    p, nand, latch, ref, seen_nand, latches_first = 0, 0, 0, 0, False, True
    while p < len(netlist):
        op = netlist[p]
        if op == 0x00:
            size, nand, seen_nand = 7, nand + 1, True
        elif op == 0x01:
            size, latch = 4, latch + 1
            latches_first = latches_first and not seen_nand
        elif op == 0x02:
            if p + 31 > len(netlist):
                raise Invalid("truncated record")
            size, ref, latches_first = 31 + 3 * netlist[p + 29], ref + 1, False
        else:
            raise Invalid(f"unknown opcode 0x{op:02x}")
        if p + size > len(netlist):
            raise Invalid("truncated record")
        p += size
    return {"nNand": nand, "nLatch": latch, "nRef": ref, "bytes": len(netlist), "latchesFirst": latches_first}


def check_binding(m: dict, netlist: bytes, n_in: int, n_out: int, n_state: int, chain_id=None) -> list:
    """Section 4: why a valid circuit manifest does not describe this circuit; empty when it does."""
    c, p = m["circuit"], []
    if netlist_hash(netlist) != c["netlistHash"]:
        p.append("netlistHash differs from keccak256 of the netlist")
    for k, v in (("nIn", n_in), ("nOut", n_out), ("nState", n_state)):
        if m[k] != v:
            p.append(f"{k} differs from the circuit's")
    if scan(netlist)["nRef"] and "chainId" not in c:
        p.append("the netlist has a REF record and the manifest names no chainId")
    if "chainId" in c and chain_id is not None and c["chainId"] != chain_id:
        p.append("chainId differs from the chain being read")
    return p


def check_shape(profile: dict, netlist: bytes) -> list:
    """Section 6.2: the shape constraints of a profile that only the netlist can answer."""
    s, info, p = profile.get("shape", {}), scan(netlist), []
    if s.get("flat") and info["nRef"]:
        p.append("shape.flat: the netlist has a REF record")
    if s.get("latchesFirst") and not info["latchesFirst"]:
        p.append("shape.latchesFirst: a LATCH follows a NAND, or the netlist has a REF record")
    if "maxGates" in s and not info["nRef"] and info["nNand"] + info["nLatch"] > s["maxGates"]:
        p.append("shape.maxGates: too many gates")
    if "maxNetlistBytes" in s and info["bytes"] > s["maxNetlistBytes"]:
        p.append("shape.maxNetlistBytes: the netlist is too long")
    return p


def conforms(m: dict, profile: dict, profile_bytes: bytes | None = None) -> list:
    """Section 6: why a valid manifest does not implement a valid profile; empty when it does."""
    p = []
    if "circuit" in profile:
        return ["the profile is a circuit manifest"]
    if profile_bytes is not None and m.get("profile", {}).get("sha256") != sha256(profile_bytes):
        p.append("profile.sha256 is not the SHA-256 of the profile file")
    for k in ("nIn", "nOut"):
        if m[k] != profile[k]:
            p.append(f"{k} differs from the profile's")
    s = profile.get("shape", {})
    if "nState" in m:
        if "nState" in profile and m["nState"] != profile["nState"]:
            p.append("nState differs from the profile's")
        if m["nState"] < s.get("nStateMin", 0) or m["nState"] > s.get("nStateMax", MAX_STATE):
            p.append("nState is outside the profile's range")
    for vec in ("inputs", "outputs", "state"):
        if vec not in profile:
            continue
        mine = {f["name"]: f for f in m.get(vec, [])}
        for pf in profile[vec]:
            f = mine.get(pf["name"])
            if f is None:
                p.append(f"{vec}: field {pf['name']} is missing")
            elif (f["offset"], f["width"]) != (pf["offset"], pf["width"]):
                p.append(f"{vec}: field {pf['name']} is at other bits")
            elif pf["encoding"] in ENCODINGS and pf["encoding"] != "bits" and any(
                    f.get(k) != pf.get(k) for k in ("encoding", *sorted(_ENCODING_MEMBERS))):
                p.append(f"{vec}: field {pf['name']} has another encoding")
    return p


# ------------------------------------------------------------------------------------------------ codec (5)

def get_bits(data: bytes, offset: int, width: int) -> int:
    """Raw value of a field. Bit i of a vector is bit i mod 8 of byte i // 8 (TAP-20 section 5); a bit
    whose byte is beyond the end of the string reads as 0."""
    v = 0
    for k in range(width):
        i = offset + k
        if (i >> 3) < len(data) and (data[i >> 3] >> (i & 7)) & 1:
            v |= 1 << k
    return v


def put_bits(buf: bytearray, offset: int, width: int, raw: int) -> None:
    if not 0 <= raw < (1 << width):
        raise ValueError(f"{raw} does not fit {width} bits")
    for k in range(width):
        i = offset + k
        if (raw >> k) & 1:
            buf[i >> 3] |= 1 << (i & 7)
        else:
            buf[i >> 3] &= ~(1 << (i & 7)) & 0xFF


def log_code(x: int, mantissa_bits: int, width: int) -> int:
    """The `log` encoding of an amount x >= 0."""
    if x < 0:
        raise ValueError("negative amount")
    if x == 0:
        return 0
    k, e = mantissa_bits, x.bit_length() - 1
    mant = (x >> (e - k) if e >= k else x << (k - e)) & ((1 << k) - 1)
    return min((1 << width) - 1, (e << k) + mant + 1)


def log_floor(code: int, mantissa_bits: int) -> int:
    """The floor amount of a `log` code: log_floor(log_code(x)) <= x for every x."""
    if code == 0:
        return 0
    k = mantissa_bits
    e, mant = (code - 1) >> k, (code - 1) & ((1 << k) - 1)
    return (((1 << k) + mant) << e) >> k


def decode_field(f: dict, raw: int) -> dict:
    """What a reader shows for a field. Integers are decimal strings, since they can exceed 2^53."""
    enc, out = f["encoding"], {"raw": str(raw)}
    if enc == "uint":
        out["value"] = str(raw)
    elif enc == "int":
        out["value"] = str(raw - (1 << f["width"]) if raw >> (f["width"] - 1) else raw)
    elif enc == "bool":
        out["value"] = bool(raw)
    elif enc == "flags":
        out["set"] = [b for k, b in enumerate(f["bits"]) if (raw >> k) & 1 and b is not None]
        out["unnamed"] = [k for k, b in enumerate(f["bits"]) if (raw >> k) & 1 and b is None]
    elif enc == "log":
        out["floor"] = str(log_floor(raw, f["mantissaBits"]))
    elif enc == "zero":
        out["ok"] = raw == 0
    if enc in ("uint", "int") and ("min" in f or "max" in f):
        v = int(out["value"])
        out["inRange"] = f.get("min", v) <= v <= f.get("max", v)
    if enc == "enum":
        out["label"] = f["values"].get(str(raw))          # None: the value is not defined
    elif enc in ("uint", "log") and str(raw) in f.get("values", {}):
        out["label"] = f["values"][str(raw)]
    return out


def decode_vector(fields: list, data: bytes) -> dict:
    return {f["name"]: decode_field(f, get_bits(data, f["offset"], f["width"])) for f in fields}


def encode_field(f: dict, value) -> int:
    """Raw value of a field from an application value. Raises ValueError for a value the field cannot hold."""
    enc, w = f["encoding"], f["width"]
    if enc == "zero":
        if value not in (0, None):
            raise ValueError(f"{f['name']} is always zero")
        return 0
    if enc == "bool":
        if not isinstance(value, bool):
            raise ValueError(f"{f['name']} takes true or false")
        return int(value)
    if enc == "enum":
        for k, lab in f["values"].items():
            if lab == value:
                return int(k)
        raise ValueError(f"{value!r} is not a value of {f['name']}")
    if enc == "flags":
        raw = 0
        for name in value:
            if name not in f["bits"] or name is None:
                raise ValueError(f"{name!r} is not a flag of {f['name']}")
            raw |= 1 << f["bits"].index(name)
        return raw
    if not _is_int(value):
        raise ValueError(f"{f['name']} takes an integer")
    if enc == "log":
        return log_code(value, f["mantissaBits"], w)
    if enc in ("uint", "int"):
        if not f.get("min", value) <= value <= f.get("max", value):
            raise ValueError(f"{value} is outside the range of {f['name']}")
    if enc == "int":
        if not -(1 << (w - 1)) <= value < (1 << (w - 1)):
            raise ValueError(f"{value} does not fit {w} bits")
        return value & ((1 << w) - 1)
    if not 0 <= value < (1 << w):
        raise ValueError(f"{value} does not fit {w} bits")
    return value


def encode_vector(fields: list, n: int, values: dict) -> bytes:
    """Packed vector of n bits. Fields that are not given, and bits no field covers, are 0."""
    unknown = set(values) - {f["name"] for f in fields}
    if unknown:
        raise ValueError(f"no such field: {sorted(unknown)}")
    buf = bytearray((n + 7) // 8)
    for f in fields:
        if f["name"] in values:
            put_bits(buf, f["offset"], f["width"], encode_field(f, values[f["name"]]))
    return bytes(buf)


# ------------------------------------------------------------------------------------------------ state

def is_canonical(data: bytes, n: int) -> bool:
    """True when data is exactly ceil(n / 8) bytes and its bits at positions n and above are 0."""
    return len(data) == (n + 7) // 8 and (n % 8 == 0 or data[-1] >> (n % 8) == 0)


def state_word(state: bytes) -> bytes:
    """Word form of a state string of at most 32 bytes: the string, then zero bytes up to 32."""
    if len(state) > 32:
        raise ValueError("a state string longer than 32 bytes has no word form")
    return state + bytes(32 - len(state))


def state_string(word: bytes, n_state: int) -> bytes:
    """The state string held by a word. Raises ValueError unless every bit at n_state and above is 0."""
    if len(word) != 32 or n_state > 256:
        raise ValueError("a word is 32 bytes and holds at most 256 state bits")
    s = word[:(n_state + 7) // 8]
    if any(word[len(s):]) or not is_canonical(s, n_state):
        raise ValueError("non-zero bits beyond nState")
    return s


def replay(beat, n_in: int, n_out: int, n_state: int, initial: bytes, records: list):
    """Check a consumer's records against the replay rule (stateful-consumer draft, section 5).

    beat(state_string, input_string) -> (new_state_string, output_string) is one TAP-20 beat of the bound
    circuit. Each record is (source, inputs, outputs, state_after), all byte strings; source 0 is a record
    without a beat. Returns None when every record holds, else (record number, reason). Record numbers start
    at 1.
    """
    if not is_canonical(initial, n_state):
        return 0, "the initial state is not a canonical state string"
    state = initial
    for n, (source, inputs, outputs, after) in enumerate(records, 1):
        if not is_canonical(after, n_state):
            return n, "stateAfter is not a canonical state string"
        if source == 0:
            if after != state:
                return n, "a record without a beat changed the state"
        else:
            if not is_canonical(inputs, n_in):
                return n, "inputs is not a canonical input string"
            new_state, out = beat(state, inputs)
            if new_state != after:
                return n, "stateAfter is not the new state of the beat"
            if out != outputs:
                return n, "outputs is not the output of the beat"
        state = after
    return None


# ------------------------------------------------------------------------------------------------ command line

if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        sys.exit("usage: pins_reference.py MANIFEST.json [PROFILE.json]")
    raw = open(sys.argv[1], "rb").read()
    doc = parse(raw)
    found = validate(doc)
    if not found and len(sys.argv) > 2:
        praw = open(sys.argv[2], "rb").read()
        prof = parse(praw)
        found = [f"profile: {x}" for x in validate(prof)] or conforms(doc, prof, praw if "profile" in doc else None)
    print("sha256", sha256(raw))
    print("kind  ", "circuit manifest" if "circuit" in doc else "profile")
    for line in found:
        print("problem:", line)
    sys.exit(1 if found else 0)
