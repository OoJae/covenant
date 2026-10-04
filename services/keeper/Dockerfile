# syntax=docker/dockerfile:1
#
# Covenant keeper. Build from the REPOSITORY ROOT (the pnpm lockfile lives there):
#
#   docker build -f services/keeper/Dockerfile -t covenant-keeper .
#   docker run --rm --env-file services/keeper/.env covenant-keeper            # long-running
#   docker run --rm --env-file services/keeper/.env covenant-keeper node src/index.ts --once --dry-run
#
# The image runs the TypeScript sources directly: Node 24+ strips types natively, so there is no build step.

FROM node:26-bookworm-slim AS deps
ENV CI=1
WORKDIR /repo
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
# The pnpm version pinned by the root package.json ("packageManager": "pnpm@x.y.z").
RUN npm install -g "$(node -p "require('./package.json').packageManager.split('+')[0]")"
COPY services/keeper/package.json services/keeper/package.json
RUN pnpm install --frozen-lockfile --prod --filter @covenant/keeper

FROM node:26-bookworm-slim
ENV NODE_ENV=production
WORKDIR /repo/services/keeper
# pnpm links services/keeper/node_modules into the store at /repo/node_modules/.pnpm with relative
# symlinks, so both directories are copied at the same relative positions.
COPY --from=deps /repo/node_modules /repo/node_modules
COPY --from=deps /repo/services/keeper/node_modules ./node_modules
COPY services/keeper/package.json ./
COPY services/keeper/src ./src
USER node
# No port: this is a worker. Exit codes: 0 stopped, 1 runtime failure, 2 configuration error.
CMD ["node", "src/index.ts"]
