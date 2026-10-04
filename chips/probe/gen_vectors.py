"""Generate probe.vectors.json from the behavioural model (model.py), not from the netlist.

    chips/.venv/bin/python chips/probe/gen_vectors.py            write the file
    chips/.venv/bin/python chips/probe/gen_vectors.py --check    fail if the file on disk differs

Two sections:
  beats       a walk from the all-zero state, in the TAP-20 vectors.json shape
              ({state, inputs, newState, outputs}, hex of the packed bytes without 0x);
  exhaustive  every one of the 512 states with every one of the 4 inputs (2,048 rows), as
              [state, inputs, newState, outputs] in the same hex packing.
The file is deterministic: no timestamps, no randomness.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import model as M  # noqa: E402

EN, CLR = 1, 2


def walk_inputs() -> list:
    seq = [0, 0, 0]                      # three idle beats: nothing moves
    seq += [EN] * 5                      # count to 5
    seq += [0, 0]                        # hold
    seq += [CLR]                         # clear
    seq += [EN | CLR]                    # clr wins over en
    seq += [EN] * 254                    # 254
    seq += [0]                           # hold just below saturation: flag still 0
    seq += [EN]                          # reaches 255: flag sets in this beat
    seq += [EN] * 3                      # saturated: stays 255, no wrap
    seq += [0]                           # hold at 255
    seq += [CLR]                         # count clears, flag stays
    seq += [EN] * 7                      # counts again with the flag still set
    seq += [EN | CLR, 0, EN, CLR, 0]
    return seq


def build() -> dict:
    beats = []
    st = 0
    for x in walk_inputs():
        ns, y = M.beat(st, x)
        beats.append({"state": M.pack(st, M.N_STATE), "inputs": M.pack(x, M.N_IN),
                      "newState": M.pack(ns, M.N_STATE), "outputs": M.pack(y, M.N_OUT)})
        st = ns
    exhaustive = []
    for s in range(1 << M.N_STATE):
        for x in range(1 << M.N_IN):
            ns, y = M.beat(s, x)
            exhaustive.append([M.pack(s, M.N_STATE), M.pack(x, M.N_IN), M.pack(ns, M.N_STATE), M.pack(y, M.N_OUT)])
    return {
        "format": "tapc-vectors/1",
        "name": "probe",
        "source": "chips/probe/model.py (behavioural model; independent of the RTL and of the netlist)",
        "packing": "bit i of a vector is bit (i mod 8) of byte floor(i / 8); LSB first; hex without 0x",
        "nIn": M.N_IN, "nOut": M.N_OUT, "nState": M.N_STATE,
        "fields": {"inputs": "en = bit 0, clr = bit 1",
                   "state": "count = bits 0..7, flag = bit 8",
                   "outputs": "count = bits 0..7, flag = bit 8, parity = bit 9"},
        "beats": beats,
        "exhaustiveColumns": ["state", "inputs", "newState", "outputs"],
        "exhaustive": exhaustive,
    }


def render(doc: dict) -> str:
    head = {k: v for k, v in doc.items() if k not in ("beats", "exhaustive")}
    text = json.dumps(head, indent=1)[:-2]                 # drop the closing "\n}"
    text += ',\n "beats": [\n' + ",\n".join("  " + json.dumps(b) for b in doc["beats"]) + "\n ]"
    text += ',\n "exhaustive": [\n' + ",\n".join("  " + json.dumps(r) for r in doc["exhaustive"]) + "\n ]\n}\n"
    return text


if __name__ == "__main__":
    out = HERE / "probe.vectors.json"
    text = render(build())
    assert json.loads(text) == build()
    if "--check" in sys.argv:
        if not out.exists() or out.read_text() != text:
            sys.exit("probe.vectors.json is stale: run gen_vectors.py")
        print("probe.vectors.json is up to date")
    else:
        out.write_text(text)
        d = json.loads(text)
        print(f"wrote {out.name}: {len(d['beats'])} beats, {len(d['exhaustive'])} exhaustive rows")
