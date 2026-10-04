# Covenant chips: toolchain (tapc) and the probe circuit.
#
#   make venv          create chips/.venv with the pinned packages (Python 3.12; never the system python3)
#   make test          run the whole test-suite, including the LIVE X Layer check (read-only eth_call)
#   make test-offline  the same without anything that needs the network
#   make probe         rebuild chips/probe from probe_core.v: synthesise, prove, regenerate and check vectors
#   make probe-check   verify that the committed probe artefacts are what a rebuild produces
#
# Nothing here sends a transaction or reads a key.

CHIPS   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
PYTHON  ?= $(firstword $(wildcard $(HOME)/.local/bin/python3.12) python3.12)
VENV    := $(CHIPS)/.venv
PY      := $(VENV)/bin/python
TAPC    := $(CHIPS)/tools/bin/tapc
PROBE   := $(CHIPS)/probe
export YOWASP_CACHE_DIR ?= $(VENV)/cache/yowasp

.PHONY: venv test test-offline probe probe-check clean

venv: $(VENV)/.installed

$(VENV)/.installed: $(CHIPS)/tools/requirements.txt
	test -x $(PY) || $(PYTHON) -m venv $(VENV)
	$(PY) -m pip install --disable-pip-version-check -r $(CHIPS)/tools/requirements.txt
	$(PY) -c "import yowasp_yosys, sys; sys.exit(yowasp_yosys.run_yosys(['-V']))"
	touch $@

test: venv
	cd $(CHIPS)/tools && $(PY) -m pytest

test-offline: venv
	cd $(CHIPS)/tools && $(PY) -m pytest -m "not live"

probe: venv
	$(TAPC) synth $(PROBE)/probe_core.v --name probe --pins $(PROBE)/probe.pins.json \
		--out $(PROBE) --build $(PROBE)/build --max-bytes 1050
	$(TAPC) prove all --rtl $(PROBE)/probe_core.v --top probe_core --tap $(PROBE)/probe.tap \
		--props-v $(PROBE)/probe_props.v --props-top probe_props --tap-module probe_tap \
		--props-py $(PROBE)/probe_props.py --work $(PROBE)/build/prove --report $(PROBE)/probe.proofs.json
	$(PY) $(PROBE)/gen_vectors.py
	$(TAPC) sim $(PROBE)/probe.tap --check $(PROBE)/probe.vectors.json
	$(TAPC) info $(PROBE)/probe.tap

probe-check: venv
	cd $(CHIPS)/tools && $(PY) -m pytest tests/test_probe.py

clean:
	rm -rf $(PROBE)/build $(CHIPS)/tools/.pytest_cache
	find $(CHIPS)/tools $(PROBE) -name __pycache__ -type d -prune -exec rm -rf {} +
