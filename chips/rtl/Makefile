# Flow Governor and Glutton: build, test, prove. Run from anywhere:  make -C chips/rtl <target>
#
#   make venv       create chips/.venv-fg (Python 3.12, yowasp-yosys, z3-solver)
#   make params     regenerate fg_params.vh from fg_params.json (checks the envelope against the factory limits
#                   and derives the token-regime thresholds from the reference curve)
#   make model      model self-check (200,000 random vectors)
#   make scenarios  every scenario under the revision-2 kernel model, the behaviour checks, the cadence test
#   make compare    every scenario under the idealised kernel and under revision 2, side by side
#   make synth      RTL -> NAND/LATCH TAP-20 bytes: chips/out/fg.tap, fg.hex, fg.manifest.json, fg.map.json
#   make pins       the pin manifest chips/out/fg.pins.json (its SHA-256 is the manifestHash for tape-out)
#   make test       RTL == model on the bytes (600,000 vectors + every scenario trace)
#   make prove      equivalence, P1..P7 (yosys SAT and z3), witness -> chips/out/fg.proofs.json
#   make modelproof model == bytes for every (state, input): z3 twin of the model -> chips/out/fg.model.json
#   make mutants    ten deliberately broken chips: each must fail its proof
#   make export     fg.fields.json, fg.vectors.json, fg.scenarios.json, per-epoch scenario tables
#   make glutton    the hostile demo chips and their clamp demo
#   make fork       local anvil fork: tape out, 10,000+ vector difftest, step gas -> chips/out/fg.fork.json
#   make all        everything except `mutants` and `fork`
#   make check      `all` without rebuilding the netlist: verifies the committed bytes
#
# Nothing here sends a mainnet transaction or reads a key. `make fork` starts a LOCAL anvil fork.

RTL     := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
CHIPS   := $(patsubst %/,%,$(dir $(RTL)))
PYTHON  ?= $(firstword $(wildcard $(HOME)/.local/bin/python3.12) python3.12)
VENV    ?= $(CHIPS)/.venv-fg
PY      := $(VENV)/bin/python
TAPC    := PYTHONPATH=$(CHIPS)/tools $(PY) -m tapc
OUT     := $(CHIPS)/out
RECIPE  ?= auto
FORK_BLOCK ?= 72373000
N       ?= 200000

.PHONY: venv params model scenarios compare synth pins test prove modelproof mutants export glutton fork all check clean

venv: $(VENV)/.installed
$(VENV)/.installed:
	test -x $(PY) || $(PYTHON) -m venv $(VENV)
	$(PY) -m pip install --disable-pip-version-check -r $(CHIPS)/tools/requirements.txt jsonschema==4.26.0
	touch $@

params: venv
	$(PY) $(RTL)/gen_params.py

model: venv
	$(PY) $(RTL)/gen_params.py --check
	$(PY) $(CHIPS)/model/flow_governor.py

scenarios: venv
	$(PY) $(CHIPS)/model/scenarios.py

compare: venv
	$(PY) $(CHIPS)/model/scenarios.py --compare

synth: venv
	$(PY) $(RTL)/gen_params.py --check
	$(TAPC) synth $(RTL)/fg_params.vh $(RTL)/fg_core.v --name fg --top fg_core --nin 96 --nout 112 \
		--pins $(CHIPS)/synth/fg.pins.json --out $(OUT) --build $(CHIPS)/synth/build/fg \
		--recipe $(RECIPE) --max-bytes 24000 --shape covenant-v1
	$(TAPC) info $(OUT)/fg.tap

pins: venv
	$(PY) $(CHIPS)/synth/gen_pins.py

test: venv
	$(PY) $(RTL)/test_fg.py --tap $(OUT)/fg.tap --n $(N)

prove: venv
	$(PY) $(CHIPS)/props/prove.py --tap $(OUT)/fg.tap

modelproof: venv
	$(PY) $(CHIPS)/props/model_equiv.py --tap $(OUT)/fg.tap --n $(N)

mutants: venv
	$(PY) $(CHIPS)/props/mutants.py

export: venv
	$(PY) $(CHIPS)/model/export.py
	$(TAPC) sim $(OUT)/fg.tap --check $(OUT)/fg.vectors.json

GL := $(CHIPS)/cells/glutton
GLPROPS := --props-v $(GL)/glutton_props.v --props-top glutton_props --tap-module glutton_tap \
	--signal p_demands_everything --signal p_heartbeat --signal p_ignores_inputs

glutton: venv
	$(TAPC) synth $(GL)/glutton_core.v --name glutton --top glutton_core --nin 96 --nout 112 \
		--pins $(GL)/glutton.pins.json --out $(GL) --build $(CHIPS)/synth/build/glutton --shape covenant-v1
	$(TAPC) synth $(GL)/glutton512_core.v --name glutton512 --top glutton512_core --nin 96 --nout 112 \
		--pins $(GL)/glutton.pins.json --out $(GL) --build $(CHIPS)/synth/build/glutton512 --shape covenant-v1
	$(TAPC) prove all --rtl $(GL)/glutton_core.v --top glutton_core --tap $(GL)/glutton.tap $(GLPROPS) \
		--signal p_group_256 --work $(CHIPS)/synth/build/glutton/prove --report $(GL)/glutton.proofs.json
	$(TAPC) prove all --rtl $(GL)/glutton512_core.v --top glutton512_core --tap $(GL)/glutton512.tap $(GLPROPS) \
		--signal p_group_512 --work $(CHIPS)/synth/build/glutton512/prove --report $(GL)/glutton512.proofs.json
	$(PY) $(GL)/demo.py

fork: venv
	$(PY) $(CHIPS)/synth/fork_test.py --block $(FORK_BLOCK) --n 10000

check: model scenarios test prove modelproof export
	$(PY) $(CHIPS)/synth/gen_pins.py --check
	$(PY) $(CHIPS)/cells/glutton/demo.py

all: params model scenarios synth pins test prove modelproof export glutton

clean:
	rm -rf $(CHIPS)/synth/build $(CHIPS)/props/build
	find $(RTL) $(CHIPS)/model $(CHIPS)/props $(CHIPS)/synth $(CHIPS)/cells -name __pycache__ -type d -prune -exec rm -rf {} +
