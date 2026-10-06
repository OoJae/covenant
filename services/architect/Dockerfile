# syntax=docker/dockerfile:1
#
# Covenant Architect: Node 26 for the HTTP service, Python 3.12 for the chip toolchain it shells out to.
# Build from the REPOSITORY ROOT (the pnpm lockfile and chips/ live there):
#
#   docker build -f services/architect/Dockerfile -t covenant-architect .
#   docker run --rm -p 8080:8080 -e X402_MODE=mock covenant-architect
#   node services/architect/scripts/selfcheck.ts http://localhost:8080 --run --mock-pay
#
# The service runs its TypeScript sources directly (Node strips the types); there is no build step.

# Debian 13 (trixie) on purpose: the pinned z3-solver publishes its arm64 wheel for glibc 2.38 or newer, and
# Debian 12 has 2.36 (pip would then try to build z3 from source and fail). x86-64 works on either.
FROM node:26-trixie-slim AS node

# --- production node_modules -----------------------------------------------------------------------
FROM node AS deps
ENV CI=1
WORKDIR /repo
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
# The pnpm version pinned by the root package.json ("packageManager": "pnpm@x.y.z").
RUN npm install -g "$(node -p "require('./package.json').packageManager.split('+')[0]")"
COPY services/architect/package.json services/architect/package.json
RUN pnpm install --frozen-lockfile --prod --filter @covenant/architect

# --- runtime ------------------------------------------------------------------------------------------
# Python's official image, with the Node binary copied in from Node's official image of the same Debian
# release. Only the binary is needed: nothing is installed or built with npm at run time.
FROM python:3.12-slim-trixie
COPY --from=node /usr/local/bin/node /usr/local/bin/node
# Node links against libatomic on arm64, and Python's slim image does not ship it. The last command makes
# the build fail here, rather than the container at start, if the copied binary cannot run.
# tini is PID 1: it forwards SIGTERM to the service and reaps every process the toolchain leaves behind.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libatomic1 tini \
 && rm -rf /var/lib/apt/lists/* \
 && node --version

ENV NODE_ENV=production \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    # The yowasp-yosys and z3 wheels are large; a slow link must not fail the build.
    PIP_DEFAULT_TIMEOUT=120 \
    PIP_RETRIES=10 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    # tapc is run as `python -m tapc ...` from chips/tools.
    PYTHONPATH=/app/chips/tools \
    # yowasp-yosys compiles its 60 MB WebAssembly module to native code on first use and caches the
    # result here. Without a persistent, pre-filled cache the first compile after every deploy would
    # pay for that (about a minute). The cache is filled below, at build time.
    YOWASP_CACHE_DIR=/var/cache/yowasp

# The toolchain's Python dependencies, pinned by the chips team (yowasp-yosys, z3-solver, ...).
COPY chips/tools/requirements.txt /tmp/requirements.txt
RUN python -m venv "$VIRTUAL_ENV" \
 && pip install -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# Fill the yowasp cache now, then hand it to the unprivileged user: if the machine that runs the image
# cannot load code compiled on the build machine, yowasp recompiles and rewrites the cache at run time.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin app \
 && mkdir -p "$YOWASP_CACHE_DIR" \
 && yowasp-yosys -V \
 && chown -R app:app "$YOWASP_CACHE_DIR"

# The chip sources and the toolchain (tapc, cells, RTL, properties, model, golden model). See
# Dockerfile.dockerignore. docs/taps/assets holds the reference implementation of the pin-manifest draft and
# the covenant-v1 profile, which chips/synth/gen_pins.py needs to write and check a chip's pin manifest.
COPY chips /app/chips
COPY docs/taps/assets /app/docs/taps/assets

# The service.
COPY --from=deps /repo/node_modules /app/node_modules
COPY --from=deps /repo/services/architect/node_modules /app/services/architect/node_modules
COPY services/architect/package.json /app/services/architect/package.json
COPY services/architect/src /app/services/architect/src
COPY services/architect/scripts /app/services/architect/scripts

WORKDIR /app/services/architect
USER app

# Railway injects PORT; this is the default for a plain `docker run`.
ENV PORT=8080
EXPOSE 8080

# The real toolchain (chips/tools/tapc/architect.py, contract in src/toolchain.ts). One request runs one
# synthesis and up to TAPC_ARCHITECT_JOBS proof workers (default 4) inside a budget of TAPC_ARCHITECT_BUDGET
# seconds (default 100; proofs still running then are reported as "timeout"). Both are passed through to the
# toolchain because their names start with TAPC_. Setting TAPC_CMD to an empty value falls back to the stub
# (the paid route then closes in live mode).
ENV TAPC_CMD="/opt/venv/bin/python -m tapc.architect"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "src/index.ts"]
