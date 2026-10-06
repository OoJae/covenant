#!/usr/bin/env bash
# Covenant chip kit: design, build, prove, price, plan and rehearse your own vault chip. See docs/BUILD_YOUR_CHIP.md.
#
#   chips/kit/kit.sh new <name>
#   chips/kit/kit.sh build    <chip>
#   chips/kit/kit.sh quote    <chip>
#   chips/kit/kit.sh envelope <chip> --launcher <address>
#   chips/kit/kit.sh plan     <chip> --launcher <address>
#   chips/kit/kit.sh fork     <chip> [--launcher <address>]
#
# Needs the chip toolchain once (Python 3.12 with yowasp-yosys and z3): make -C chips/rtl venv
# `fork` and the plan script also need Foundry (anvil, cast) and jq.
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CHIPS=$(dirname "$KIT")
PY=${KIT_PYTHON:-$CHIPS/.venv-fg/bin/python}
if [ ! -x "$PY" ]; then
  echo "kit: no chip toolchain at $PY. Create it once with: make -C chips/rtl venv" >&2
  exit 2
fi
exec "$PY" "$KIT/kit.py" "$@"
