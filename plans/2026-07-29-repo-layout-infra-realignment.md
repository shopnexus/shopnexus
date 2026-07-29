# Repo Layout & Infra Realignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the umbrella repo back in line with the refactored backend and rewritten frontend, so `docker compose up` works locally and Argo CD can sync a deployable cluster.

**Architecture:** Each submodule becomes self-contained (its own `Dockerfile`, dev compose, CI); the umbrella keeps only orchestration (kustomize, Argo CD, ingress, environment values) and composes the submodule compose files via Compose `include:` instead of redefining infrastructure. See `specs/2026-07-29-repo-layout-design.md`.

**Tech Stack:** Docker Compose (spec `include:`), Kustomize, Argo CD, Traefik, Next.js 16 + pnpm, Go 1.26, TimescaleDB, NATS JetStream, Redis 7, Loki, Grafana Alloy, Grafana.

## Global Constraints

- **No unit tests exist for infrastructure.** Each task's test cycle is a
  validation command (`docker build`, `docker compose config`, `kustomize build`)
  run before committing. Never commit a manifest that has not been rendered.
- **All backend config is `required` with no defaults.** A missing variable is a
  startup crash, not a silent fallback. Every env var the gateway or migrate
  binary needs must be present in both compose and k8s.
- **Config variable names are exact, unprefixed, and case-sensitive:**
  `GATEWAY_ADDR`, `INSTANCE_ID`, `LOG_LEVEL`, `NATS_URL`, `REDIS_ADDR`,
  `REDIS_PASSWORD`, `JWT_SECRET`, `ID_CIPHER_KEY`, `ACCOUNT_DB_DSN`,
  `CATALOG_DB_DSN`, `ORDER_DB_DSN`, `CHAT_DB_DSN`, `COMMON_DB_DSN`,
  `TRUST_DB_DSN`, `FINANCE_DB_DSN`, `OBSERVABILITY_DB_DSN`. The `APP_` prefix is
  gone everywhere.
- **`JWT_SECRET` is min 32 bytes. `ID_CIPHER_KEY` is exactly 16, 24 or 32 bytes.**
- **Database image must be `timescale/timescaledb-ha:pg18`.** Migrations require
  `timescaledb`, `timescaledb_toolkit`, `vector`, `postgis`, `pg_trgm` and
  `unaccent`; only the `-ha` image bundles all six.
- **Postgres data path for that image is `/home/postgres/pgdata/data`**, not
  `/var/lib/postgresql/data`.
- **All `deploy/k8s/base` manifest edits land in ONE commit.** Argo CD syncs every
  commit on `main`; a split commit lets the cluster observe a half-updated
  topology (for example gateway on 8080 while the ingress still targets 5005).
- **Commits go directly to `main`** in every repo, per the approved delivery
  decision. Submodule work is committed and pushed in its own repo first, then the
  umbrella records the new pointer.
- **Never delete the `embedding/` working directory** — it holds uncommitted
  changes to `main.py`, `pyproject.toml` and `uv.lock`.
- **Language in the `docs` submodule.** `docs/CLAUDE.md` says content is written
  in Vietnamese — that applies to the **typst reports** (`manual/`, `typst/`),
  which this plan does not touch. The **Mintlify developer site** (`docs/docs/`)
  is written in English (verified: `introduction.mdx`, `operations/deployment.mdx`),
  so Tasks 3 and 3b write English. Do not translate existing pages.

---

## File Structure

### `website` submodule (new files)

| File | Responsibility |
|---|---|
| `Dockerfile` | Multi-stage pnpm build → Next standalone runtime image |
| `.dockerignore` | Keep `node_modules`/`.next` out of build context |
| `docker-compose.yml` | Dev service definition, so the umbrella can `include:` it |
| `.github/workflows/build.yml` | Build + push `ghcr.io/shopnexus/website` |
| `next.config.ts` | Add `output: "standalone"` (modify) |

### `server` submodule (moves only)

| Change | Reason |
|---|---|
| `deploy/` → `dev/` | Remove the name collision with the umbrella's production `deploy/` |
| `deploy/rybbit/README.md` → docs submodule | Prose belongs to docs, not a deployment directory |

### `docs` submodule

| File | Responsibility |
|---|---|
| `docs/operations/analytics-rybbit.mdx` | Rybbit runbook, relocated |
| `docs/docs.json` | Add the page to the Operations group (modify) |
| `.gitignore` | Untrack the vendored OpenAPI copy (modify) |
| `Dockerfile` | Fetch the OpenAPI spec at build time (modify) |
| `package.json` | `npm run spec` for local authoring |
| `README.md` | Explain that the spec is fetched, not committed (modify) |

### `umbrella` repo

| File | Responsibility |
|---|---|
| `docker-compose.yml` | Rewritten: `include:` only, no infra definitions |
| `deploy/k8s/base/config.env` | Non-secret config, new contract |
| `deploy/k8s/base/secret.env.example` | Secret template, new contract |
| `deploy/k8s/base/secret.example.yaml` | Secret manifest template, new contract |
| `deploy/k8s/base/postgres.yaml` | TimescaleDB image + data path |
| `deploy/k8s/base/nats.yaml` | **new** — JetStream StatefulSet |
| `deploy/k8s/base/restate.yaml` | **deleted** |
| `deploy/k8s/base/redis.yaml` | Image → `redis:7` |
| `deploy/k8s/base/gateway.yaml` | Replaces `server.yaml` |
| `deploy/k8s/base/migrate-job.yaml` | `/migrate` + full env |
| `deploy/k8s/base/ingress.yaml` | Backend → `gateway:8080` |
| `deploy/k8s/base/kustomization.yaml` | Resource list + ConfigMap generator |
| `deploy/k8s/overlays/local/kustomization.yaml` | Patch targets renamed |
| `deploy/monitoring/loki.yaml` | **new** |
| `deploy/monitoring/alloy.yaml` | **new** — DaemonSet + RBAC |
| `deploy/monitoring/alloy/config.alloy` | **new** — `discovery.kubernetes` |
| `deploy/monitoring/grafana.yaml` | TimescaleDB + Loki datasources |
| `deploy/monitoring/prometheus.yaml` | **deleted** |
| `deploy/monitoring/prometheus/` | **deleted** |
| `deploy/monitoring/grafana/provisioning/datasources/*.yml` | Rewritten |
| `deploy/monitoring/kustomization.yaml` | Resources + dashboard generator |
| `deploy/argocd/monitoring.yaml` | Add `--load-restrictor` build option |
| `.gitmodules` | Drop `embedding`; switch URLs to HTTPS |
| `README.md`, `deploy/README.md` | Reflect the new topology |

---

## Phase 1 — `website` becomes self-contained

Nothing in the umbrella can reference the website until its image exists in GHCR.
This phase is independently deliverable and must land first.

### Task 1: Website container image

**Files:**
- Modify: `website/next.config.ts`
- Create: `website/Dockerfile`
- Create: `website/.dockerignore`

**Interfaces:**
- Consumes: nothing.
- Produces: an image whose `CMD` is `node server.js`, listening on `$PORT`
  (default `3000`) at `$HOSTNAME` (default `0.0.0.0`). Task 2 and the umbrella's
  `website.yaml` depend on exactly those two variable names and that port.

- [ ] **Step 1: Add standalone output to the Next config**

`output: "standalone"` makes `next build` emit `.next/standalone/server.js` with
only the traced runtime dependencies. Without it there is no `server.js` and the
runtime stage below has nothing to run.

Also drop the stale ngrok host from `allowedDevOrigins` — it is one contributor's
dead tunnel URL and does not belong in a committed config.

```typescript
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Emit .next/standalone/server.js — a self-contained server with only the
  // traced dependencies, so the runtime image needs no node_modules install.
  output: "standalone",
  images: {
    remotePatterns: [
      {
        // Placeholder images: picsum.photos/seed/<id>/<w>/<h>
        protocol: "https",
        hostname: "picsum.photos",
      },
      {
        protocol: "https",
        hostname: "lh3.googleusercontent.com",
      },
    ],
  },
};

export default nextConfig;
```

- [ ] **Step 2: Write the `.dockerignore`**

Without this, the build context ships the host's `node_modules` (wrong
architecture) and `.next` (stale build), which is both slow and incorrect.

```
node_modules
.next
out
build
coverage
.git
.github
.antigravity
*.tsbuildinfo
next-env.d.ts
.env*
Dockerfile
.dockerignore
```

- [ ] **Step 3: Write the Dockerfile**

`pnpm-workspace.yaml` here only carries a build allowlist (`allowBuilds`), not a
`packages:` list, so this is a single-package build and needs no workspace
filtering. pnpm comes from `corepack`, which ships with Node.

```dockerfile
# Next.js standalone build. `output: "standalone"` (next.config.ts) traces the
# runtime deps into .next/standalone, so the final stage carries no package
# manager and no node_modules install.
FROM node:22-alpine AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN pnpm build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
RUN addgroup -g 1001 nodejs && adduser -u 1001 -G nodejs -S nextjs
COPY --from=build /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]
```

- [ ] **Step 4: Build the image and verify it fails or succeeds explicitly**

```bash
cd website && docker build -t shopnexus/website:local .
```

Expected: build succeeds. If `pnpm build` fails on a type or lint error, that is
a real defect in the rewritten codebase — fix it here rather than disabling the
check, and record what was fixed in the commit message.

- [ ] **Step 5: Run the image and verify it serves**

```bash
docker run --rm -d --name website-smoke -p 3000:3000 shopnexus/website:local
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:3000/
docker rm -f website-smoke
```

Expected: `200`.

- [ ] **Step 6: Commit**

```bash
cd website
git add next.config.ts Dockerfile .dockerignore
git commit -m "build: containerize with standalone output"
git push origin main
```

---

### Task 2: Website dev compose + CI

**Files:**
- Create: `website/docker-compose.yml`
- Create: `website/.github/workflows/build.yml`

**Interfaces:**
- Consumes: the `Dockerfile` from Task 1.
- Produces: a compose service named **`website`** on host port **5001**, and the
  image `ghcr.io/shopnexus/website:main`. The umbrella's `include:` (Task 5)
  depends on the service name; `deploy/k8s/base/website.yaml` depends on the
  image reference.

- [ ] **Step 1: Write the dev compose file**

Hot reload runs `next dev` against a bind mount, mirroring how the server repo's
compose treats the Go binary. `node_modules` gets its own volume so the host's
copy never shadows the container's.

```yaml
# Local DEV for the storefront. `docker compose up` → http://localhost:5001
# The image build is production-only (see Dockerfile); this runs `next dev` with
# hot reload against a bind mount.
name: shopnexus-website

services:
  website:
    image: node:22-alpine
    working_dir: /app
    command: sh -c "corepack enable && pnpm install --frozen-lockfile && pnpm dev --hostname 0.0.0.0 --port 3000"
    ports:
      - "5001:3000"
    environment:
      NEXT_TELEMETRY_DISABLED: "1"
      # Unread by the current codebase (no process.env references yet) but kept
      # as the documented contract — SEO/canonical work will need it.
      SITE_URL: ${SITE_URL:-http://localhost:5001}
    volumes:
      - .:/app
      - website-node-modules:/app/node_modules
      - website-next:/app/.next
    restart: unless-stopped

volumes:
  website-node-modules:
  website-next:
```

- [ ] **Step 2: Verify compose parses**

```bash
cd website && docker compose config >/dev/null && echo OK
```

Expected: `OK`.

- [ ] **Step 3: Write the CI workflow**

This mirrors `server/.github/workflows/build.yml` exactly, because the umbrella's
Argo CD Image Updater expects the same `:main` + `:sha-<commit>` tag pair tracked
by digest.

```yaml
name: Build & Push image

# CI only builds + pushes the image to GHCR. Deployment is handled by GitOps
# (Argo CD) in the umbrella repo, which rolls out new :main digests.
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

env:
  IMAGE: ghcr.io/${{ github.repository }} # ghcr.io/shopnexus/website

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build & push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.IMAGE }}:main
            ${{ env.IMAGE }}:sha-${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 4: Commit and push**

```bash
cd website
git add docker-compose.yml .github/workflows/build.yml
git commit -m "ci: build and push image to GHCR; add dev compose"
git push origin main
```

- [ ] **Step 5: Verify the workflow published the image**

Check the artifact, not just the workflow's exit status — a green run that pushed
to the wrong tag still leaves the deployment broken. GHCR packages for these repos
are public, so this needs no credentials:

```bash
docker manifest inspect ghcr.io/shopnexus/website:main >/dev/null \
  && echo "IMAGE-PUBLISHED" || echo "NOT-YET — wait for CI or check the run"
```

Expected: `IMAGE-PUBLISHED`. Do not proceed to Phase 3 until it appears — the
umbrella's `website.yaml` will otherwise reference a tag that does not exist and
the pod will sit in `ImagePullBackOff`.

`gh` is not authenticated in this environment, so `gh run list` will fail. If you
need the run log, authenticate first by typing `! gh auth login` in the session,
or read it in the browser.

---

## Phase 2 — `server` and `docs` hygiene

### Task 3: Rename `server/deploy/` → `server/dev/` and relocate the Rybbit runbook

**Files:**
- Move: `server/deploy/alloy/` → `server/dev/alloy/`
- Move: `server/deploy/grafana/` → `server/dev/grafana/`
- Delete: `server/deploy/rybbit/README.md`
- Modify: `server/docker-compose.yml`
- Create: `docs/docs/operations/analytics-rybbit.mdx`
- Modify: `docs/docs/docs.json`

**Interfaces:**
- Consumes: nothing.
- Produces: the path `server/dev/grafana/dashboards/observability.json`, which the
  umbrella's monitoring ConfigMap generator (Task 8) reads.

- [ ] **Step 1: Move the directories with git**

```bash
cd server
mkdir -p dev
git mv deploy/alloy dev/alloy
git mv deploy/grafana dev/grafana
```

- [ ] **Step 2: Repoint the compose bind mounts**

Three `./deploy/...` paths in `server/docker-compose.yml` become `./dev/...`:

```bash
cd server
sed -i 's#\./deploy/grafana/#./dev/grafana/#g; s#\./deploy/alloy/#./dev/alloy/#g' docker-compose.yml
grep -n 'dev/grafana\|dev/alloy\|deploy/' docker-compose.yml
```

Expected: three `./dev/...` lines, and no remaining `./deploy/` reference.

- [ ] **Step 3: Update the compose header comment**

The file's opening comment references `deploy/grafana`. Change that one mention
to `dev/grafana` so the comment does not contradict the volume paths.

- [ ] **Step 4: Verify compose still resolves**

```bash
cd server && docker compose config >/dev/null && echo OK
```

Expected: `OK`. A wrong bind-mount path is silently accepted by Compose (it
creates a directory), so also confirm the source files exist:

```bash
test -f server/dev/alloy/config.alloy && test -f server/dev/grafana/dashboards/observability.json && echo FILES-OK
```

Expected: `FILES-OK`.

- [ ] **Step 5: Move the Rybbit runbook into the docs site**

Create `docs/docs/operations/analytics-rybbit.mdx` with Mintlify front matter,
carrying over the content of `server/deploy/rybbit/README.md` verbatim below it:

```mdx
---
title: "Analytics (Rybbit)"
description: "Self-hosted product and web analytics for the storefront, and how it differs from backend telemetry."
---

Rybbit handles **product & web analytics** (traffic, funnels, retention, session
replay, Core Web Vitals) for the marketplace **frontend**. It is a **separate
self-hosted stack** — it runs its own ClickHouse, Postgres, backend, client, and
Caddy — and is deliberately **not** wired into the backend's `docker-compose.yml`.
The Go backend does not depend on it; instrumentation is client-side.

Split of responsibilities:

- **Rybbit** → frontend user behavior (anonymous/product analytics). ClickHouse.
- **`observability` module** (backend) → backend operational telemetry (HTTP RED,
  Go runtime, bus events) in TimescaleDB + Grafana.
- **Recommendation/personalization** (per-user, if/when built) → first-party
  interaction data server-side in TimescaleDB, joinable with catalog — not Rybbit.

## Deploy

Run on its own VPS (min 2 GB RAM), with a domain pointed at it (DNS A record).
The setup script generates env/secrets, builds the containers, and configures
Caddy for automatic TLS.

```bash
git clone https://github.com/rybbit-io/rybbit.git
cd rybbit
chmod +x *.sh
./setup.sh your.analytics.domain
```

For local runs or putting it behind an existing reverse proxy, follow Rybbit's
[self-hosting docs](https://rybbit.com/docs/self-hosting).

## Instrument the frontend

After setup, open the Rybbit dashboard, create a **Site**, and copy the tracking
snippet it shows into the storefront's `<head>`:

```html
<script defer src="https://your.analytics.domain/api/script.js" data-site-id="YOUR_SITE_ID"></script>
```

Use the exact `src` and `data-site-id` from the dashboard. The snippet lives in
the storefront app, not the backend.

## Optional: server-side events

For events the browser cannot see (for example `order.placed`), you can POST to
Rybbit's track API from the backend. Prefer keeping such domain signals
first-party in TimescaleDB if they feed recommendations; only forward to Rybbit
for product-analytics dashboards.

<Warning>
Do not vendor Rybbit's source into any ShopNexus repo — deploy it from its own
repository so it upgrades independently.
</Warning>
```

- [ ] **Step 6: Register the page in the docs navigation**

In `docs/docs/docs.json`, the Operations group currently reads:

```json
{
  "group": "Operations",
  "pages": [
    "operations/deployment"
  ]
}
```

Change it to:

```json
{
  "group": "Operations",
  "pages": [
    "operations/deployment",
    "operations/analytics-rybbit"
  ]
}
```

- [ ] **Step 7: Verify the docs JSON is still valid**

```bash
python3 -c "import json; json.load(open('docs/docs/docs.json')); print('JSON-OK')"
```

Expected: `JSON-OK`.

- [ ] **Step 8: Delete the old runbook and commit both repos**

```bash
cd server
git rm -r deploy/rybbit
git add -A dev docker-compose.yml
git commit -m "refactor: rename deploy/ to dev/; move rybbit runbook to docs"
git push origin main

cd ../docs
git add docs/operations/analytics-rybbit.mdx docs/docs.json
git commit -m "docs: add rybbit analytics runbook"
git push origin main
```

---

### Task 3b: Fetch the OpenAPI spec at docs build time instead of committing a copy

Numbered `3b` rather than renumbering the tasks after it — later tasks reference
each other by number.

**Files:**
- Modify: `docs/.gitignore`
- Delete from index (keep on disk): `docs/docs/api/openapi.yaml`
- Modify: `docs/Dockerfile`
- Modify: `docs/package.json` (create if absent)
- Modify: `docs/README.md`

**Interfaces:**
- Consumes: `server/api/openapi.gen.yaml`, published on the `main` branch of the
  server repo.
- Produces: `docs/docs/api/openapi.yaml` as a build artifact. `docs/docs/docs.json`
  already points the "HTTP Gateway" group at `api/openapi.yaml`, so that path must
  not change.

- [ ] **Step 1: Confirm the current copy is manual, not generated**

```bash
cd /home/beanbocchi/shopnexus
diff -q docs/docs/api/openapi.yaml server/api/openapi.gen.yaml \
  && echo "IDENTICAL (hand-copied, will drift)" || echo "ALREADY DRIFTED"
```

Expected: `IDENTICAL (hand-copied, will drift)`. Either result justifies the
change — the second one proves the drift already happened.

- [ ] **Step 2: Stop tracking the copy**

The file stays on disk so `mint dev` keeps working for whoever is mid-edit; only
the git tracking stops.

```bash
cd docs
git rm --cached docs/api/openapi.yaml
printf '\n# Fetched from the server repo at build time (see Dockerfile).\ndocs/api/openapi.yaml\n' >> .gitignore
```

- [ ] **Step 3: Add a fetch script for local authoring**

`mint dev` does not run the Dockerfile, so a contributor needs one command to
refresh the spec. Create `docs/package.json` if it does not exist, or add the
script to the existing one:

```json
{
  "name": "shopnexus-docs",
  "private": true,
  "scripts": {
    "spec": "curl -fsSL https://raw.githubusercontent.com/shopnexus/server/main/api/openapi.gen.yaml -o docs/api/openapi.yaml",
    "dev": "npm run spec && npx mint@latest dev"
  }
}
```

`curl -f` matters: without it a 404 writes an HTML error page into the spec file
and Mintlify renders a broken API tab instead of failing.

- [ ] **Step 4: Fetch the spec in the Docker build**

In `docs/Dockerfile`, add the fetch to the builder stage, after the `COPY docs/`
line and before the `mint export` line. `curl` is already being installed
alongside `unzip`, so extend that apt line rather than adding a second one.

Change:

```dockerfile
RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
```

to:

```dockerfile
RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
```

And insert, immediately after `WORKDIR /build/docs`:

```dockerfile
# The API reference is generated from the backend's handlers, so it is fetched
# rather than vendored — a committed copy goes stale the first time anyone edits
# a handler. docs.json points the "HTTP Gateway" group at api/openapi.yaml.
# -f so a 404 fails the build instead of writing an HTML error page into the spec.
ARG OPENAPI_URL=https://raw.githubusercontent.com/shopnexus/server/main/api/openapi.gen.yaml
RUN curl -fsSL "$OPENAPI_URL" -o api/openapi.yaml \
 && head -1 api/openapi.yaml | grep -q '^openapi:' \
 && echo "openapi spec fetched: $(wc -c < api/openapi.yaml) bytes"
```

The `head -1 | grep` guard catches a 200 response that is not actually a spec.

- [ ] **Step 5: Build the docs image and verify the spec was fetched**

```bash
cd /home/beanbocchi/shopnexus/docs
docker build -t shopnexus/docs:local . 2>&1 | grep -E 'openapi spec fetched|ERROR'
```

Expected: a line like `openapi spec fetched: 341649 bytes`. If the build fails at
the `curl` step, the server repo has not pushed `api/openapi.gen.yaml` to `main`
yet — check that before changing the URL.

- [ ] **Step 6: Verify the served page includes the API reference**

```bash
docker run --rm -d --name docs-smoke -p 5000:80 shopnexus/docs:local
sleep 3
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:5000/
docker rm -f docs-smoke
```

Expected: `200`.

- [ ] **Step 7: Note the mechanism in the docs README**

Add a short section so the next contributor does not re-commit the file:

```markdown
## API reference

`docs/api/openapi.yaml` is **not committed** — it is generated from the backend's
handlers (`server/api/openapi.gen.yaml`, guarded by a drift-check workflow in that
repo) and fetched at build time by the Dockerfile. Refresh it locally with:

```bash
npm run spec
```

Do not commit a copy: it goes stale the first time anyone edits a handler.
```

- [ ] **Step 8: Commit**

```bash
cd /home/beanbocchi/shopnexus/docs
git add .gitignore Dockerfile package.json README.md
git commit -m "docs: fetch openapi spec at build time instead of vendoring it"
git push origin main
```

---

## Phase 3 — umbrella realignment

### Task 4: Deregister the `embedding` submodule

**Files:**
- Modify: `.gitmodules`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a `.gitmodules` without `embedding`, and with HTTPS URLs that Task 8
  relies on for Argo CD submodule checkout.

- [ ] **Step 1: Confirm there is uncommitted work to protect**

```bash
cd embedding && git status --short
```

Expected: `M main.py`, `M pyproject.toml`, `M uv.lock`. **Stop and tell the user**
if this is non-empty and they have not yet pushed it — the next step removes the
git link, and the directory must survive with these changes intact.

- [ ] **Step 2: Deregister the submodule without deleting the directory**

`git rm --cached` drops the gitlink from the index but leaves the working tree
alone, unlike `git submodule deinit` + `git rm`, which would remove the files.

```bash
cd /home/beanbocchi/shopnexus
git rm --cached embedding
git config --file .gitmodules --remove-section submodule.embedding
```

- [ ] **Step 3: Switch the remaining submodule URLs to HTTPS**

These are public repos. HTTPS lets an OSS contributor `git clone --recurse-submodules`
without an SSH key, and lets Argo CD initialise submodules without credentials —
which Task 8 requires in order to read the Grafana dashboard from `server/dev/`.

`.gitmodules` becomes:

```ini
[submodule "app"]
	path = app
	url = https://github.com/shopnexus/app.git
[submodule "docs"]
	path = docs
	url = https://github.com/shopnexus/docs.git
[submodule "server"]
	path = server
	url = https://github.com/shopnexus/server.git
[submodule "website"]
	path = website
	url = https://github.com/shopnexus/website.git
```

- [ ] **Step 4: Sync the new URLs into `.git/config`**

```bash
git submodule sync --recursive
git config --get submodule.server.url
```

Expected: `https://github.com/shopnexus/server.git`.

- [ ] **Step 4b: Keep pushing over SSH**

`git submodule sync` just rewrote the local submodule remotes to HTTPS, which is
what Argo CD and fresh clones need — but HTTPS **pushes** require a token, and
this machine authenticates to GitHub with an SSH key
(`~/.ssh/id_ed25519`). Without this, the next `git push` from inside a submodule
prompts for a password and fails.

`pushInsteadOf` rewrites only the push URL, so fetches stay HTTPS:

```bash
git config --global url."git@github.com:".pushInsteadOf "https://github.com/"
```

Verify fetch and push resolve differently:

```bash
cd server && git remote -v
```

Expected: the `(fetch)` line shows `https://github.com/shopnexus/server.git` and
the `(push)` line shows `git@github.com:shopnexus/server.git`.

This is a global git setting, not a repo change — mention it in the commit message
body so the next person on a different machine knows they need it too.

- [ ] **Step 5: Verify the embedding directory and its changes survived**

```bash
test -f embedding/main.py && (cd embedding && git status --short) && echo SURVIVED
```

Expected: the three `M` lines, then `SURVIVED`.

- [ ] **Step 6: Drop `embedding` from the README component table**

Remove the `embedding` row. The remaining rows are `app`, `docs`, `server`,
`website`.

- [ ] **Step 7: Commit**

```bash
git add .gitmodules README.md
git commit -m "chore: drop embedding submodule; use https submodule urls"
```

---

### Task 5: Root compose composes submodules instead of redefining them

**Files:**
- Modify: `docker-compose.yml` (full rewrite)

**Interfaces:**
- Consumes: `server/docker-compose.yml` (services `db`, `redis`, `nats`,
  `grafana`, `loki`, `alloy`, `migrate`, `gateway`), `website/docker-compose.yml`
  (service `website`, from Task 2), `docs/docker-compose.yml` (service `docs`).
- Produces: a single `shopnexus` compose project covering the whole system.

- [ ] **Step 1: Replace the root compose file**

The old file redefined every piece of infrastructure and had already drifted from
the server repo — it still built the deleted `server/Dockerfile.dev`. The
replacement defines nothing; it composes.

The `profiles: []` overrides matter: `gateway` and `migrate` sit behind
`profiles: ["app"]` in the server's own compose so that a backend developer gets
infra-only by default. At the root, running the whole system *is* the point, so
both are pulled into the default profile.

```yaml
# Local DEV stack for the whole system.
#
#   docker compose up --build
#
# This file defines NO services of its own. Each submodule owns how it builds and
# runs itself, and this file composes those definitions — so infra versions have
# exactly one source of truth (the submodule that depends on them).
#
# Backend only:   cd server  && docker compose up
# Storefront only: cd website && docker compose up
#
# Production is Kubernetes — see ./deploy. This file is dev-only.
name: shopnexus

include:
  - server/docker-compose.yml
  - website/docker-compose.yml
  - docs/docker-compose.yml

services:
  # The server's compose keeps these behind `profiles: ["app"]` so a backend dev
  # gets infra-only by default. At the root, running the full system is the point.
  migrate:
    profiles: []
  gateway:
    profiles: []
```

- [ ] **Step 2: Verify the merged project renders**

```bash
cd /home/beanbocchi/shopnexus && docker compose config >/dev/null && echo OK
```

Expected: `OK`. If it fails on a duplicate service name, two submodules define
the same service and the collision must be resolved by renaming in the submodule,
not by dropping the `include`.

- [ ] **Step 3: Verify the project name and profile overrides took effect**

```bash
docker compose config --services | sort
docker compose config | grep -A2 '^name:'
```

Expected: the service list contains `alloy db docs gateway grafana loki migrate
nats redis website`. Expected: `name: shopnexus` — **verify this explicitly**,
because `docs/docker-compose.yml` declares `name: docs` and the including file's
project name must win. If `docs` wins instead, remove the `name:` key from the
docs submodule's compose file and re-verify.

- [ ] **Step 4: Verify gateway and migrate are in the default profile**

Compose's merge semantics for sequence fields are not uniform — an override list
sometimes replaces and sometimes appends — so whether `profiles: []` actually
clears the inherited `["app"]` must be measured, not assumed.

```bash
cd /home/beanbocchi/shopnexus
docker compose config | grep -n 'profiles' || echo "NO-PROFILES (override worked)"
docker compose config --services | grep -E '^(gateway|migrate)$'
```

Expected: `NO-PROFILES (override worked)`, and both `gateway` and `migrate` listed.

**If `profiles` survives in the rendered output**, the override did not clear it.
Do not fight it — remove the `services:` block from the root compose file
entirely, leaving a pure `include:`, and document the profile flag instead:

```bash
docker compose --profile app up --build
```

Then update the root compose header comment and the README command in Task 9,
Step 2 to use `--profile app`. Record which of the two outcomes occurred in the
commit message, so the next reader knows the flag is deliberate rather than
forgotten.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: root compose includes submodule compose files"
```

---

### Task 6: New config contract — ConfigMap and Secret templates

**Files:**
- Modify: `deploy/k8s/base/config.env` (full rewrite)
- Modify: `deploy/k8s/base/secret.env.example` (full rewrite)
- Modify: `deploy/k8s/base/secret.example.yaml` (full rewrite)

**Interfaces:**
- Consumes: nothing.
- Produces: ConfigMap `shopnexus-config` with keys `GATEWAY_ADDR`, `LOG_LEVEL`,
  `NATS_URL`, `REDIS_ADDR`, `SITE_URL`, `DOCS_URL`; and Secret `shopnexus-secret`
  with keys `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `JWT_SECRET`, `ID_CIPHER_KEY`,
  and the eight `*_DB_DSN` keys. Task 7 wires both into workloads by exactly
  these names.

- [ ] **Step 1: Rewrite `config.env`**

Every `APP_*` key is gone. The DSNs are absent here on purpose — they embed the
password, so they belong to the Secret.

```
# Non-secret runtime config for the gateway, as the flat env vars the Go app
# reads (internal/config/config.go). Same .env syntax docker-compose uses, so
# this file doubles as documentation of the interface. Consumed by the
# configMapGenerator in kustomization.yaml.
#
# Every field the app reads is `required` with no default — a missing key is a
# startup crash, not a fallback. The eight *_DB_DSN values live in the Secret
# because they embed the password.

GATEWAY_ADDR=0.0.0.0:8080
LOG_LEVEL=info

# In-cluster DNS; service names match the compose ones.
NATS_URL=nats://nats:4222
REDIS_ADDR=redis:6379

# ── Public URLs — single source of truth ────────────────────────────────────
# SITE_URL is the storefront origin. The gateway no longer reads any public URL
# (payment-return derivation moved out of config), so this is consumed only by
# the website Deployment. The current storefront rewrite does not read it yet,
# but it remains the documented contract.
SITE_URL=https://shop.toanehihi.io.vn

# Docs public origin. Documentation of the Caddy edge — no workload reads it.
# The docs Ingress matches the internal alias `docs.internal` instead, so the
# public domain can change without touching a manifest.
DOCS_URL=https://docs.toanehihi.io.vn
```

- [ ] **Step 2: Rewrite `secret.env.example`**

```
# TEMPLATE — copy to secret.env (git-ignored) if you enable the secretGenerator,
# or use the kubectl create secret command in README. Never commit real values.
#
# The postgres and redis containers read POSTGRES_PASSWORD / REDIS_PASSWORD
# directly — the same keys the app uses, so there is no duplicate copy.

POSTGRES_PASSWORD=CHANGE_ME
REDIS_PASSWORD=CHANGE_ME

# Min 32 bytes (validated at startup).
JWT_SECRET=CHANGE_ME_32_BYTES_MINIMUM_XXXXXX

# Exactly 16, 24 or 32 bytes. PERMANENT: rotating this invalidates every opaque
# id ever handed out. Back it up like a database credential.
ID_CIPHER_KEY=0123456789abcdef0123456789abcdef

# One DSN per module. They all point at the same database today and isolate
# their tables by Postgres schema (search_path is set per pool to the module
# name); each can be moved to its own server later without a code change.
ACCOUNT_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
CATALOG_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
ORDER_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
CHAT_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
COMMON_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
TRUST_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
FINANCE_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
OBSERVABILITY_DB_DSN=postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable

# Optional — Grafana admin password (monitoring). Absent ⇒ Grafana admin/admin.
# GRAFANA_ADMIN_PASSWORD=CHANGE_ME
```

- [ ] **Step 3: Rewrite `secret.example.yaml`**

```yaml
# TEMPLATE — never commit real values. Apply out-of-band:
#   kubectl -n shopnexus apply -f secret.yaml
# See deploy/README.md for the `kubectl create secret generic` one-liner.
apiVersion: v1
kind: Secret
metadata:
  name: shopnexus-secret
  namespace: shopnexus
type: Opaque
stringData:
  POSTGRES_PASSWORD: CHANGE_ME
  REDIS_PASSWORD: CHANGE_ME
  JWT_SECRET: CHANGE_ME_32_BYTES_MINIMUM_XXXXXX
  ID_CIPHER_KEY: 0123456789abcdef0123456789abcdef
  ACCOUNT_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  CATALOG_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  ORDER_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  CHAT_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  COMMON_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  TRUST_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  FINANCE_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
  OBSERVABILITY_DB_DSN: postgres://shopnexus:CHANGE_ME@postgres:5432/shopnexus?sslmode=disable
```

- [ ] **Step 4: Verify no `APP_` key survives in the base**

```bash
grep -rn 'APP_' deploy/k8s/base/ || echo CLEAN
```

Expected: `CLEAN`. (This will still report matches from `server.yaml` and
`migrate-job.yaml` until Task 7 rewrites them; if so, note it and re-run this
check at the end of Task 7.)

- [ ] **Step 5: Commit**

```bash
git add deploy/k8s/base/config.env deploy/k8s/base/secret.env.example deploy/k8s/base/secret.example.yaml
git commit -m "deploy: new flat config contract (drop APP_* prefix)"
```

---

### Task 7: Kubernetes topology — one atomic commit

Per the global constraints, every manifest change here lands in a single commit
so Argo CD never observes a half-updated topology.

**Files:**
- Modify: `deploy/k8s/base/postgres.yaml`
- Create: `deploy/k8s/base/nats.yaml`
- Delete: `deploy/k8s/base/restate.yaml`
- Modify: `deploy/k8s/base/redis.yaml`
- Create: `deploy/k8s/base/gateway.yaml`
- Delete: `deploy/k8s/base/server.yaml`
- Modify: `deploy/k8s/base/migrate-job.yaml`
- Modify: `deploy/k8s/base/ingress.yaml`
- Modify: `deploy/k8s/base/kustomization.yaml`
- Modify: `deploy/k8s/overlays/local/kustomization.yaml`
- Modify: `deploy/argocd/application.yaml`

**Interfaces:**
- Consumes: ConfigMap/Secret keys from Task 6; the image
  `ghcr.io/shopnexus/website:main` from Task 2.
- Produces: Service `gateway` on port `8080`, Service `nats` on `4222`, and the
  Deployment/Service name `gateway` that Task 8's ingress and the local overlay
  patch targets refer to.

- [ ] **Step 1: Point Postgres at the TimescaleDB HA image**

Three edits in `deploy/k8s/base/postgres.yaml`. The image change is mandatory
(see Global Constraints); the data path changes because this image runs Postgres
as the `postgres` user out of `/home/postgres/pgdata`.

Replace the container `image`:

```yaml
          image: timescale/timescaledb-ha:pg18
```

Replace the `PGDATA` env value and the volume mount path:

```yaml
            - name: PGDATA
              value: /home/postgres/pgdata/data
```

```yaml
          volumeMounts:
            - name: postgres-data
              mountPath: /home/postgres/pgdata
```

Add a comment above the image recording why it is not negotiable:

```yaml
          # timescaledb-ha, not plain postgres or pgvector: the migrations need
          # timescaledb, timescaledb_toolkit, vector, postgis, pg_trgm and
          # unaccent. Only the -ha image bundles all six.
```

- [ ] **Step 2: Bump the Postgres PVC**

TimescaleDB hypertables for HTTP request telemetry grow faster than the old
relational-only schema. Raise `storage` on the `postgres-data` PVC from `5Gi` to
`20Gi`.

Note: a PVC's `resources.requests.storage` is immutable for shrink and only
expandable if the StorageClass allows it. On k3d's `local-path` class, expansion
is not supported, so **this edit only affects a fresh cluster**. Record that in a
comment rather than pretending it resizes in place:

```yaml
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      # 20Gi: telemetry hypertables grow faster than the old schema. k3d's
      # local-path class cannot expand in place — this applies to a fresh volume.
      storage: 20Gi
```

- [ ] **Step 3: Bump Redis to 7**

In `deploy/k8s/base/redis.yaml`, change the image and repoint the secret key
(Task 6 renamed `APP_REDIS_PASSWORD` to `REDIS_PASSWORD`):

```yaml
          image: redis:7
```

```yaml
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: shopnexus-secret
                  key: REDIS_PASSWORD   # single source key (shared with the app)
```

- [ ] **Step 4: Repoint the Postgres secret key**

In `deploy/k8s/base/postgres.yaml`, the `POSTGRES_PASSWORD` env still reads
`key: APP_POSTGRES_PASSWORD`. Change it to `key: POSTGRES_PASSWORD`.

- [ ] **Step 5: Create the NATS JetStream StatefulSet**

A StatefulSet rather than a Deployment because JetStream holds state: queued
telemetry must survive a restart, which is the entire reason the bus sits between
the observability Sink and the database writer.

```yaml
# NATS with JetStream — buffers observability telemetry between the Sink
# (publisher) and the batching writer (consumer), so a slow or down database
# never blocks a request and queued samples survive a restart.
#
# StatefulSet, not Deployment: the JetStream store is durable state, and a stable
# volume identity matters. `-m 8222` serves the monitoring endpoint used by the
# readiness probe.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nats
  labels:
    app.kubernetes.io/name: nats
    app.kubernetes.io/part-of: shopnexus
spec:
  replicas: 1
  serviceName: nats
  selector:
    matchLabels:
      app.kubernetes.io/name: nats
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nats
        app.kubernetes.io/part-of: shopnexus
    spec:
      containers:
        - name: nats
          image: nats:2.10-alpine
          args: ["-js", "-sd", "/data", "-m", "8222"]
          ports:
            - name: client
              containerPort: 4222
            - name: monitor
              containerPort: 8222
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8222
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8222
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: nats-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: nats-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: nats
spec:
  selector:
    app.kubernetes.io/name: nats
  ports:
    - name: client
      port: 4222
      targetPort: 4222
    - name: monitor
      port: 8222
      targetPort: 8222
```

- [ ] **Step 6: Create `gateway.yaml` and delete `server.yaml`**

The workload is renamed to match the binary it runs. Ports 8082 and 8083 are
gone with Restate. `INSTANCE_ID` comes from the downward API because defaulting
it collapses replicas into one telemetry series.

The probe is `tcpSocket`, not `httpGet`: the router registers only
`/openapi.yaml` and `/docs`, so there is no health endpoint to hit. This is a
deliberate placeholder — see the plan's follow-up section.

```yaml
# Go backend gateway (cmd/gateway). Listens on 8080; the image's ENTRYPOINT is
# /gateway. Built and pushed to GHCR by the server repo's build workflow; the tag
# is managed by Argo CD Image Updater.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  annotations:
    argocd.argoproj.io/sync-wave: "2"   # after DB migration (wave 1)
  labels:
    app.kubernetes.io/name: gateway
    app.kubernetes.io/part-of: shopnexus
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app.kubernetes.io/name: gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: gateway
        app.kubernetes.io/part-of: shopnexus
    spec:
      imagePullSecrets:
        - name: ghcr
      containers:
        - name: gateway
          image: ghcr.io/shopnexus/server:main
          imagePullPolicy: Always
          # Non-secret config from the ConfigMap, DSNs and keys from the Secret.
          # Every field is `required` — a missing key crashes at startup.
          envFrom:
            - configMapRef:
                name: shopnexus-config
            - secretRef:
                name: shopnexus-secret
          env:
            # Tags every telemetry row with the pod that produced it. Without a
            # per-pod value, replicas collapse into one meaningless series, which
            # is why config.go makes this required rather than defaulting it.
            - name: INSTANCE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
          ports:
            - name: http
              containerPort: 8080
          # tcpSocket, not httpGet: the router exposes no /healthz yet. Switch to
          # httpGet once the backend adds one.
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 45
            periodSeconds: 30
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: gateway
spec:
  selector:
    app.kubernetes.io/name: gateway
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

```bash
git rm deploy/k8s/base/server.yaml deploy/k8s/base/restate.yaml
```

- [ ] **Step 7: Rewrite the migration Job**

Two corrections. The binary is at `/migrate`, not `/app/migrate` — the new
Dockerfile copies both binaries to the image root. And `cmd/migrate/main.go`
calls the same `config.Load` as the gateway, so it validates **every** field:
giving it only the database connection would fail validation on `GATEWAY_ADDR`,
`JWT_SECRET`, `ID_CIPHER_KEY`, `NATS_URL` and the rest. It therefore takes the
full `envFrom` pair.

Replace the container block's `command` and `env` with:

```yaml
        - name: migrate
          image: ghcr.io/shopnexus/server:main
          imagePullPolicy: Always
          command: ["/migrate"]
          # cmd/migrate calls the same config.Load as the gateway, which
          # validates every field — so it needs the full environment, not just
          # the DSNs. The hook runs at wave 1, after the generated ConfigMap
          # (wave 0) exists.
          envFrom:
            - configMapRef:
                name: shopnexus-config
            - secretRef:
                name: shopnexus-secret
          env:
            - name: INSTANCE_ID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Also update the file's header comment: it says `/app/migrate` and lists
`postgres/redis/restate` as wave-0 infra. Restate is gone; NATS replaces it.

- [ ] **Step 8: Repoint the ingress at the gateway**

In `deploy/k8s/base/ingress.yaml`, the `/api` path backend becomes:

```yaml
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: gateway
                port:
                  number: 8080
```

- [ ] **Step 9: Update the base kustomization**

Swap `restate.yaml` and `server.yaml` for `nats.yaml` and `gateway.yaml`:

```yaml
resources:
  - namespace.yaml
  - postgres.yaml
  - redis.yaml
  - nats.yaml
  - gateway.yaml
  - website.yaml
  - docs.yaml
  - ingress.yaml
  - migrate-job.yaml
```

- [ ] **Step 10: Update the local overlay patch targets**

In `deploy/k8s/overlays/local/kustomization.yaml`, the patch targeting
`Deployment/server` must become `Deployment/gateway`, or kustomize fails with
"no matches for target". The image mappings keep the `ghcr.io/shopnexus/server`
name, because the repo — and therefore the image — is still called `server`.

```yaml
  - target:
      kind: Deployment
      name: gateway
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: IfNotPresent
```

- [ ] **Step 11: Update the Argo CD Image Updater aliases**

In `deploy/argocd/application.yaml`, the alias `server` is only a label, but
leaving it while the workload is named `gateway` is misleading. Rename the alias
and its strategy key; the image reference itself is unchanged:

```yaml
    argocd-image-updater.argoproj.io/image-list: >-
      gateway=ghcr.io/shopnexus/server:main,
      website=ghcr.io/shopnexus/website:main,
      docs=ghcr.io/shopnexus/docs:main
    argocd-image-updater.argoproj.io/gateway.update-strategy: digest
    argocd-image-updater.argoproj.io/website.update-strategy: digest
    argocd-image-updater.argoproj.io/docs.update-strategy: digest
    argocd-image-updater.argoproj.io/write-back-method: argocd
```

- [ ] **Step 12: Render the base and confirm the new topology**

```bash
cd /home/beanbocchi/shopnexus
kubectl kustomize deploy/k8s/base > /tmp/base.yaml && echo BUILD-OK
grep -n 'restate\|APP_' /tmp/base.yaml || echo NO-STALE-REFS
grep -n 'image: timescale/timescaledb-ha:pg18' /tmp/base.yaml
```

Expected: `BUILD-OK`; `NO-STALE-REFS`; the TimescaleDB image on one line.

Then check the workload inventory by name rather than by count:

```bash
python3 - <<'EOF'
import subprocess, yaml
docs = [d for d in yaml.safe_load_all(open('/tmp/base.yaml')) if d]
for d in sorted(docs, key=lambda d: (d['kind'], d['metadata']['name'])):
    print(f"{d['kind']:<24} {d['metadata']['name']}")
EOF
```

Expected exactly these workloads: `Deployment` — `docs`, `gateway`, `postgres`,
`redis`, `website` (five); `StatefulSet` — `nats` (one); `Job` — `db-migrate`;
`Service` — `docs`, `gateway`, `nats`, `postgres`, `redis`, `website`; plus the
two `Ingress` objects, the `Namespace`, the generated `ConfigMap`, and the two
`PersistentVolumeClaim`s (`postgres-data`, `redis-data`). Nothing named `restate`
or `server`.

- [ ] **Step 13: Render the local overlay**

```bash
kubectl kustomize deploy/k8s/overlays/local >/dev/null && echo OVERLAY-OK
```

Expected: `OVERLAY-OK`. A "no matches for target" error means Step 10 was missed.

- [ ] **Step 14: Confirm every required config key is supplied**

The gateway crashes if any of the 16 required variables is missing. Check the
rendered ConfigMap plus the Secret template together:

```bash
for k in GATEWAY_ADDR INSTANCE_ID LOG_LEVEL NATS_URL REDIS_ADDR REDIS_PASSWORD \
         JWT_SECRET ID_CIPHER_KEY ACCOUNT_DB_DSN CATALOG_DB_DSN ORDER_DB_DSN \
         CHAT_DB_DSN COMMON_DB_DSN TRUST_DB_DSN FINANCE_DB_DSN OBSERVABILITY_DB_DSN; do
  if grep -q "$k" /tmp/base.yaml deploy/k8s/base/secret.example.yaml; then
    echo "ok   $k"
  else
    echo "MISS $k"
  fi
done
```

Expected: 16 `ok` lines, no `MISS`.

- [ ] **Step 15: Commit — one atomic commit**

```bash
git add -A deploy/k8s deploy/argocd/application.yaml
git commit -m "deploy: retarget k8s at new backend (timescale, nats, gateway:8080; drop restate)"
```

---

### Task 8: Observability — Loki + Alloy + Grafana replace Prometheus

**Files:**
- Delete: `deploy/monitoring/prometheus.yaml`
- Delete: `deploy/monitoring/prometheus/prometheus.yml`
- Delete: `deploy/monitoring/grafana/provisioning/datasources/prometheus.yml`
- Create: `deploy/monitoring/loki.yaml`
- Create: `deploy/monitoring/alloy.yaml`
- Create: `deploy/monitoring/alloy/config.alloy`
- Create: `deploy/monitoring/grafana/provisioning/datasources/timescaledb.yml`
- Create: `deploy/monitoring/grafana/provisioning/datasources/loki.yml`
- Create: `deploy/monitoring/grafana/provisioning/dashboards/dashboards.yml`
- Modify: `deploy/monitoring/grafana.yaml`
- Modify: `deploy/monitoring/kustomization.yaml`
- Modify: `deploy/argocd/monitoring.yaml`

**Interfaces:**
- Consumes: Service `postgres:5432` and Secret key `POSTGRES_PASSWORD` from
  Task 7/6; the dashboard file `server/dev/grafana/dashboards/observability.json`
  from Task 3.
- Produces: Service `loki:3100`; Grafana with datasources `TimescaleDB` (uid
  `timescaledb`) and `Loki` (uid `loki`). The dashboard JSON references these
  uids, so they must not be renamed.

- [ ] **Step 1: Delete the Prometheus stack**

Prometheus has nothing left to scrape: metrics are now written directly into
TimescaleDB hypertables by the `observability` module, and the gateway exposes no
`/metrics` endpoint.

```bash
cd /home/beanbocchi/shopnexus
git rm deploy/monitoring/prometheus.yaml \
       deploy/monitoring/prometheus/prometheus.yml \
       deploy/monitoring/grafana/provisioning/datasources/prometheus.yml
```

- [ ] **Step 2: Create Loki**

Single-binary Loki on the image's bundled config, with a PVC for its chunks.
`fsGroup: 10001` is the `loki` uid in the official image; without it the mounted
`local-path` volume is not writable and the pod crash-loops.

```yaml
# Single-binary Loki (filesystem storage) on the image's default config.
# Holds container logs shipped by Alloy. Single replica writing one PVC, so
# Recreate rather than RollingUpdate — two pods must never share the store.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: loki-data
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  labels:
    app.kubernetes.io/name: loki
    app.kubernetes.io/part-of: shopnexus
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: loki
  template:
    metadata:
      labels:
        app.kubernetes.io/name: loki
        app.kubernetes.io/part-of: shopnexus
    spec:
      securityContext:
        fsGroup: 10001   # loki user — owns the mounted PVC
      containers:
        - name: loki
          image: grafana/loki:3.3.0
          args: ["-config.file=/etc/loki/local-config.yaml"]
          ports:
            - name: http
              containerPort: 3100
          readinessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            - name: data
              mountPath: /loki
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: loki-data
---
apiVersion: v1
kind: Service
metadata:
  name: loki
spec:
  selector:
    app.kubernetes.io/name: loki
  ports:
    - name: http
      port: 3100
      targetPort: 3100
```

- [ ] **Step 3: Write the Kubernetes Alloy config**

This is a genuinely different file from the server repo's dev config, which
discovers containers over `/var/run/docker.sock` — a mechanism that does not
exist in Kubernetes. Here discovery goes through the API server and log reading
goes through the kubelet.

```river
// Discover pods in the shopnexus namespace via the Kubernetes API and ship their
// logs to Loki, labelled so Grafana can filter e.g. {service="gateway"}.
//
// This is the K8S config. The server repo has its own dev config that tails
// Docker containers over docker.sock — the two mechanisms are not interchangeable.
// App logs are JSON (slog); parse them at query time in Grafana with `| json`.

discovery.kubernetes "pods" {
	role = "pod"

	namespaces {
		names = ["shopnexus"]
	}
}

discovery.relabel "pods" {
	targets = discovery.kubernetes.pods.targets

	rule {
		source_labels = ["__meta_kubernetes_namespace"]
		target_label  = "namespace"
	}

	// app.kubernetes.io/name is set on every workload in deploy/k8s/base, so
	// this yields gateway / website / docs / postgres / redis / nats.
	rule {
		source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
		target_label  = "service"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_name"]
		target_label  = "pod"
	}

	rule {
		source_labels = ["__meta_kubernetes_pod_container_name"]
		target_label  = "container"
	}
}

loki.source.kubernetes "pods" {
	targets    = discovery.relabel.pods.output
	forward_to = [loki.write.default.receiver]
}

loki.write "default" {
	endpoint {
		url = "http://loki:3100/loki/api/v1/push"
	}
}
```

- [ ] **Step 4: Create the Alloy DaemonSet with RBAC**

Alloy needs a ServiceAccount with cluster-wide read on pods and pod logs;
`discovery.kubernetes` calls the API server and `loki.source.kubernetes` reads
`pods/log`. Without the ClusterRole the pod starts but silently ships nothing.

```yaml
# Grafana Alloy — discovers pods via the Kubernetes API and ships their logs to
# Loki. DaemonSet so each node's pods are collected locally.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alloy
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: shopnexus-alloy
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "namespaces", "pods", "pods/log", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: shopnexus-alloy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: shopnexus-alloy
subjects:
  - kind: ServiceAccount
    name: alloy
    namespace: shopnexus
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: alloy
  labels:
    app.kubernetes.io/name: alloy
    app.kubernetes.io/part-of: shopnexus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: alloy
  template:
    metadata:
      labels:
        app.kubernetes.io/name: alloy
        app.kubernetes.io/part-of: shopnexus
    spec:
      serviceAccountName: alloy
      containers:
        - name: alloy
          image: grafana/alloy:v1.5.1
          args:
            - "run"
            - "--server.http.listen-addr=0.0.0.0:12345"
            - "--storage.path=/var/lib/alloy/data"
            - "/etc/alloy/config.alloy"
          env:
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          ports:
            - name: http
              containerPort: 12345
          readinessProbe:
            httpGet:
              path: /-/ready
              port: 12345
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/alloy
            - name: data
              mountPath: /var/lib/alloy/data
      volumes:
        - name: config
          configMap:
            name: alloy-config   # kustomize rewrites to the hashed name
        - name: data
          emptyDir: {}
```

- [ ] **Step 5: Write the Grafana datasources**

The dashboard JSON from the server repo references datasources by **uid**, so
`timescaledb` and `loki` must match the dev provisioning exactly. The password
uses Grafana's `$VAR` expansion, fed from the Secret by the Deployment — so no
credential is committed.

`deploy/monitoring/grafana/provisioning/datasources/timescaledb.yml`:

```yaml
# Backend operational telemetry — HTTP RED, Go runtime and bus events, written as
# TimescaleDB hypertables by the observability module (schema: observability).
# The uid must stay `timescaledb`: the dashboard JSON references it by uid.
apiVersion: 1

datasources:
  - name: TimescaleDB
    uid: timescaledb
    type: postgres
    access: proxy
    url: postgres:5432
    user: shopnexus
    isDefault: true
    jsonData:
      database: shopnexus
      sslmode: disable
      postgresVersion: 1800
      timescaledb: true
    secureJsonData:
      # Expanded by Grafana from the container env (see grafana.yaml), which
      # reads it from shopnexus-secret. No credential is committed here.
      password: $POSTGRES_PASSWORD
```

`deploy/monitoring/grafana/provisioning/datasources/loki.yml`:

```yaml
# Container logs shipped by Alloy. uid must stay `loki` — dashboards reference it.
apiVersion: 1

datasources:
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      maxLines: 1000
```

- [ ] **Step 6: Write the dashboard provider**

`deploy/monitoring/grafana/provisioning/dashboards/dashboards.yml`:

```yaml
# Loads dashboards from /var/lib/grafana/dashboards, mounted from a ConfigMap
# generated out of the server submodule (see kustomization.yaml) so the dashboard
# and the schema it queries stay in one repo.
apiVersion: 1

providers:
  - name: observability
    orgId: 1
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

- [ ] **Step 7: Rewire the Grafana Deployment**

Three changes to `deploy/monitoring/grafana.yaml`: add the `POSTGRES_PASSWORD`
env the datasource expands, mount the dashboard provider and dashboard JSON, and
bump the image to match the dev stack.

Add to the container `env` list:

```yaml
            # Expanded into the TimescaleDB datasource's secureJsonData at
            # provisioning time (see grafana/provisioning/datasources).
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: shopnexus-secret
                  key: POSTGRES_PASSWORD
```

Replace the `volumeMounts` and `volumes` blocks:

```yaml
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: dashboard-provider
              mountPath: /etc/grafana/provisioning/dashboards
            - name: dashboards
              mountPath: /var/lib/grafana/dashboards
            - name: data
              mountPath: /var/lib/grafana
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources   # kustomize rewrites to the hashed name
        - name: dashboard-provider
          configMap:
            name: grafana-dashboard-provider
        - name: dashboards
          configMap:
            name: grafana-dashboards
        - name: data
          persistentVolumeClaim:
            claimName: grafana-data
```

Change the image to `grafana/grafana:11.3.0` so prod matches the dev stack's
pinned version rather than drifting a patch ahead.

Also update the file's header comment, which describes "dashboards over the
Prometheus datasource".

- [ ] **Step 8: Rewrite the monitoring kustomization**

The dashboard generator reads **across the submodule boundary** — that is the
point, so the dashboard lives with the schema it queries. Kustomize refuses paths
outside its root by default, which Step 10 handles at the Argo CD level.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Monitoring runs in the same namespace as the apps so Grafana can reach
# `postgres:5432` and `loki:3100` by short DNS name.
namespace: shopnexus

resources:
  - loki.yaml
  - alloy.yaml
  - grafana.yaml
  - ingress.yaml

# Configs kept in files (readable, reusable) and mounted as ConfigMaps. The hash
# suffix means editing a config auto-rolls the pod; kustomize rewrites the volume
# `configMap.name` references to the hashed names.
configMapGenerator:
  - name: grafana-datasources
    files:
      - timescaledb.yml=grafana/provisioning/datasources/timescaledb.yml
      - loki.yml=grafana/provisioning/datasources/loki.yml
  - name: grafana-dashboard-provider
    files:
      - dashboards.yml=grafana/provisioning/dashboards/dashboards.yml
  # Read from the server submodule on purpose: the dashboard queries the
  # observability schema, so the two must change in one commit. Requires
  # --load-restrictor LoadRestrictionsNone (set on the Argo CD Application).
  - name: grafana-dashboards
    files:
      - observability.json=../../server/dev/grafana/dashboards/observability.json
  - name: alloy-config
    files:
      - config.alloy=alloy/config.alloy
```

- [ ] **Step 9: Verify the monitoring build renders**

Kustomize needs the relaxed load restrictor for the cross-submodule file:

```bash
cd /home/beanbocchi/shopnexus
kubectl kustomize --load-restrictor LoadRestrictionsNone deploy/monitoring > /tmp/mon.yaml && echo BUILD-OK
grep -c 'kind: ConfigMap' /tmp/mon.yaml
grep -n 'prometheus' /tmp/mon.yaml || echo NO-PROMETHEUS
grep -n 'observability.json' /tmp/mon.yaml | head -1
```

Expected: `BUILD-OK`; 4 ConfigMaps; `NO-PROMETHEUS`; the dashboard key present.

Confirm the restriction is real (so Step 10 is justified, not cargo-culted):

```bash
kubectl kustomize deploy/monitoring >/dev/null 2>&1 && echo "UNRESTRICTED-OK" || echo "NEEDS-FLAG (expected)"
```

Expected: `NEEDS-FLAG (expected)`.

- [ ] **Step 10: Give the Argo CD Application the build option**

In `deploy/argocd/monitoring.yaml`, add the kustomize build option and update the
stale "Prometheus + Grafana" description:

```yaml
# Argo CD Application for the monitoring stack (Loki + Alloy + Grafana over
# TimescaleDB).
#
# Kept as a SEPARATE Application from the main `shopnexus` app so monitoring is
# optional and its health never gates the app rollout. No Image Updater: the
# images are pinned upstream tags, bumped by editing deploy/monitoring.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: shopnexus-monitoring
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/shopnexus/shopnexus.git
    targetRevision: main
    path: deploy/monitoring
    kustomize:
      # The Grafana dashboard ConfigMap is generated from the server submodule
      # (deploy/monitoring/kustomization.yaml), which kustomize treats as outside
      # its root. Argo initialises submodules on checkout, so the path resolves.
      buildOptions: --load-restrictor LoadRestrictionsNone
  destination:
    server: https://kubernetes.default.svc
    namespace: shopnexus
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ApplyOutOfSyncOnly=true
```

**Verify this assumption before trusting the sync:** Argo CD initialises git
submodules on checkout by default (disabled only when
`ARGOCD_GIT_MODULES_ENABLED=false`), and Task 4 switched the URLs to HTTPS so no
credentials are needed for these public repos. Confirm on the cluster:

```bash
kubectl -n argocd get deploy argocd-repo-server -o yaml | grep -A2 GIT_MODULES || echo "default (enabled)"
```

If submodules turn out to be disabled and cannot be enabled, fall back to
committing a copy of `observability.json` under `deploy/monitoring/dashboards/`
plus a CI check that diffs it against the server submodule — and say so, because
that reintroduces the drift this design set out to remove.

- [ ] **Step 11: Commit**

```bash
git add -A deploy/monitoring deploy/argocd/monitoring.yaml
git commit -m "deploy: replace prometheus with loki+alloy; grafana over timescaledb"
```

---

### Task 9: Documentation and submodule pointers

**Files:**
- Modify: `README.md`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing further depends on this.

- [ ] **Step 1: Record the new submodule pointers**

Phases 1 and 2 pushed commits in `server`, `website` and `docs`. The umbrella
still points at the old ones.

```bash
cd /home/beanbocchi/shopnexus
git submodule status
git add server website docs
git diff --cached --submodule=log
```

Expected: the diff shows the new commits from Tasks 1–3.

- [ ] **Step 2: Update the root README**

Three corrections:

- The component table drops `embedding` (done in Task 4) — confirm it is gone.
- The Development section is wrong: it tells the reader to run
  `cd server && docker compose up` for "backend + postgres + redis + restate +
  minio". Replace with the new per-component and whole-system commands.
- The deployment diagram mentions `shopnexus.hopto.org`, a dead domain.

```markdown
## Development

The whole system, from the umbrella (this composes each submodule's own compose
file — it defines no services itself):

```bash
docker compose up --build
```

A single component, from its own repo — this is how each submodule is meant to be
worked on, and needs nothing from the umbrella:

```bash
cd server  && docker compose up -d          # infra only; run `go run ./cmd/gateway` on the host
cd server  && docker compose --profile app up -d --build   # infra + gateway + migrations
cd website && docker compose up             # storefront with hot reload
cd docs    && docker compose up --build     # docs site (nginx)
```
```

- [ ] **Step 3: Update `deploy/README.md`**

This file is the architecture reference and is now wrong in several places. Make
these edits:

1. **Design principle** — it currently says a submodule ships "a `Dockerfile` + a
   dev `docker-compose.yml` ... nothing about the cluster, ingress, or secrets."
   Restate it as the rule from the spec: *an artifact lives next to whatever
   determines its content* — code-determined artifacts in the code's repo,
   environment- and topology-determined artifacts in the umbrella. Note the one
   deliberate crossing: the Grafana dashboard is server-owned and read across the
   submodule boundary, because it queries the `observability` schema.

2. **Repo topology block** — replace `postgres · redis · restate` with
   `postgres · redis · nats`; replace `server · website · ingress` with
   `gateway · website · ingress`; note that `config.env` holds flat (not `APP_*`)
   config; drop the `embedding` row; add `deploy/monitoring/` as Loki + Alloy +
   Grafana rather than Prometheus + Grafana.

3. **End-to-end flow diagram** — wave 0 becomes `postgres  redis  nats`; wave 2
   becomes `gateway (8080)  website (3000)`; the Traefik line becomes
   `/api → gateway:8080   / → website:3000`.

4. **Config & secrets model** — the contract is no longer `APP_*` + viper
   `AutomaticEnv`. Replace that section with the Task 6 contract: flat
   unprefixed env, every field required with no default, eight per-module DSNs in
   the Secret because they embed the password, and `INSTANCE_ID` from the downward
   API. Call out that `ID_CIPHER_KEY` is permanent and must be backed up.

5. **Add a "Known gaps" section** recording the two deliberate compromises:

```markdown
### Known gaps

- **No health endpoint.** `internal/gateway/router.go` exposes `/openapi.yaml`
  and `/docs` and nothing else, so the gateway's probes are `tcpSocket` — they
  prove the port is open, not that the app is serving. Switch both probes to
  `httpGet /healthz` once the backend adds one.
- **Swagger UI needs outbound internet.** `/docs` loads swagger-ui from the
  unpkg CDN, so the page is blank in an air-gapped cluster. Vendor the assets
  into the server image to fix it there.
```

- [ ] **Step 4: Verify no stale references survive**

```bash
cd /home/beanbocchi/shopnexus
grep -rn 'restate\|minio\|APP_\|prometheus\|Prometheus\|hopto.org\|Dockerfile.dev' \
  README.md deploy/ docker-compose.yml --exclude-dir=.git || echo CLEAN
```

Expected: `CLEAN`. Any hit is a doc or manifest still describing the old system.

- [ ] **Step 5: Verify both kustomize builds one final time**

```bash
kubectl kustomize deploy/k8s/base >/dev/null && echo BASE-OK
kubectl kustomize deploy/k8s/overlays/local >/dev/null && echo OVERLAY-OK
kubectl kustomize --load-restrictor LoadRestrictionsNone deploy/monitoring >/dev/null && echo MON-OK
docker compose config >/dev/null && echo COMPOSE-OK
```

Expected: all four OK lines.

- [ ] **Step 6: Commit and push**

```bash
git add README.md deploy/README.md server website docs
git commit -m "docs: describe new topology; bump submodule pointers"
git push origin main
```

- [ ] **Step 7: Watch the first Argo CD sync**

The commit above is what the cluster reacts to. Confirm it converges rather than
assuming it did:

```bash
kubectl -n argocd get app shopnexus shopnexus-monitoring
kubectl -n shopnexus get pods
kubectl -n shopnexus logs job/db-migrate --tail=30
```

Expected: both Applications `Synced`/`Healthy`; the `db-migrate` Job
`Completed` with eight `migrate <module>: ok` lines; `gateway`, `website`,
`docs`, `postgres`, `redis`, `nats` all `Running`.

If the gateway crash-loops, read the config error first — it names the missing
field:

```bash
kubectl -n shopnexus logs deploy/gateway --tail=20
```

---

## Follow-up work (out of scope, recorded)

These are real gaps this plan deliberately does not close. They belong to the
backend repo, not the umbrella.

1. **Add `GET /healthz` to `internal/gateway/router.go`**, then switch the
   gateway's `readinessProbe`/`livenessProbe` from `tcpSocket` to `httpGet`.
2. **Remove the unused `restatedev/sdk-go` dependency** from `server/go.mod` and
   the stale Restate reference in `internal/shared/errx/errx.go`.
3. **Vendor the swagger-ui assets** into the server image so `/docs` works
   without outbound internet.
4. **Wire LiteLLM** into `internal/config/config.go` and the deployment — the
   provider exists at `internal/provider/llm/litellm` but no config field points
   at it, which is why the `embedding` submodule was dropped.
5. **Decide the fate of the `embedding` repo** — it has uncommitted local changes
   and is no longer part of the system.
