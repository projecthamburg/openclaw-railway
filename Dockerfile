# ─── Stage 1: Build node-pty (requires native compilation) ─────────────────
FROM node:24-bookworm-slim AS builder

# node-pty needs python3, make, g++ to compile its native binding.
# git is needed because transitive deps reference GitHub SSH URLs.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    make \
    g++ \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./

# Force HTTPS for any GitHub git deps (no SSH keys in Docker)
RUN printf '[url "https://github.com/"]\n\tinsteadOf = ssh://git@github.com/\n\tinsteadOf = git@github.com:\n' > /root/.gitconfig

RUN npm install --omit=dev


# ─── Stage 2: Runtime ────────────────────────────────────────────────────────
FROM node:24-bookworm-slim

# OpenClaw version — set via Railway build args to pin a specific version.
# Default is 2026.6.6 (latest stable): the template's CLI flags, provider
# auth-choices, OAuth device-code flows, and the in-process device-bootstrap
# SDK are all verified against this release. Notable from earlier pins:
#   - 2026.3.12+ shipped two pairing bugs (issues #45504 + #51779) the wrapper
#     works around via the device-bootstrap SDK (callerScopes: operator.admin).
#   - 2026.6.x renamed the OpenAI OAuth choice openai-codex-device-code ->
#     openai-device-code, and bumped the Node engine floor to >=22.19.0
#     (satisfied by node:22-bookworm-slim below).
ARG OPENCLAW_VERSION=2026.6.6

# Runtime deps:
# - bash: required by node-pty for the shell
# - procps: for process management
# - curl: for healthchecks
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    procps \
    curl \
    git \
    ca-certificates \
    zip \
    && rm -rf /var/lib/apt/lists/*

# Install openclaw globally — needs git for transitive deps with GitHub URLs.
#
# Compatibility floor: MIN below is a HARD-CODED constant (deliberately NOT an
# ARG), so no Railway variable can lower or bypass it. If the deployer's
# OPENCLAW_VERSION is a concrete release older than MIN, we install MIN instead;
# tags ("latest") and pre-releases are installed verbatim. The decision is
# recorded in /app/openclaw-build-info.json so the setup/admin UI can explain
# an auto-bump. Keep MIN in sync with MIN_VERSION in src/utils/version.js
# (and the ARG OPENCLAW_VERSION default above).
RUN printf '[url "https://github.com/"]\n\tinsteadOf = ssh://git@github.com/\n\tinsteadOf = git@github.com:\n' > /root/.gitconfig \
    && MIN="2026.6.6" \
    && REQ="${OPENCLAW_VERSION:-$MIN}" && EFF="$REQ" && BUMPED=false \
    && if echo "$REQ" | grep -Eq '^[0-9]{4}\.[0-9]+\.[0-9]+$' && dpkg --compare-versions "$REQ" lt "$MIN"; then \
         echo "WARNING: OPENCLAW_VERSION=$REQ is below the compatibility floor $MIN — installing $MIN instead"; \
         EFF="$MIN"; BUMPED=true; \
       fi \
    && npm install -g openclaw@"$EFF" \
    && mkdir -p /app \
    && printf '{"requested":"%s","effective":"%s","min":"%s","bumped":%s}\n' "$REQ" "$EFF" "$MIN" "$BUMPED" > /app/openclaw-build-info.json \
    && echo "openclaw build-info: $(cat /app/openclaw-build-info.json)"

WORKDIR /app

# Copy compiled node_modules from builder stage
# (includes node-pty native .node binary built for this exact OS/arch)
COPY --from=builder /app/node_modules ./node_modules

# Copy application source
COPY src/ ./src/
COPY public/ ./public/
COPY package.json ./

# /data is the Railway volume mount path for all persistent state.
# Create it so the image works even without a volume attached (dev/test).
RUN mkdir -p /data/.openclaw/nodes /data/.openclaw/workspace

# ── Ensure node_modules/.bin is in PATH for other local binaries ─────────────
ENV PATH="/app/node_modules/.bin:${PATH}"

# Railway sets PORT automatically; default to 3000
ENV PORT=3000
ENV NODE_ENV=production
ENV OPENCLAW_DATA_DIR=/data

# Path to openclaw's entry.js — the wrapper invokes it directly via `node`
# (not the bin shim) and resolves the in-process device-bootstrap SDK
# relative to this path.
ENV OPENCLAW_ENTRY=/usr/local/lib/node_modules/openclaw/dist/entry.js
ENV OPENCLAW_NODE=node

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://localhost:${PORT}/api/status || exit 1

CMD ["node", "src/server.js"]