# Repo layout & infra realignment — design

**Date:** 2026-07-29
**Status:** approved, not yet implemented

## Problem

The `server` submodule was refactored end-to-end (`23e13b31 refactor entire
structure`) and `website` was rewritten from scratch (`4672bed Initial commit for
new website codebase`). The umbrella repo still describes the pre-refactor world,
so two things are broken right now:

1. Root `docker-compose.yml` builds `server/Dockerfile.dev`, which no longer
   exists.
2. `deploy/k8s/base/config.env` publishes only `APP_*` variables. The new server
   reads flat, unprefixed env and validates every field as `required`, so the
   gateway pod crash-loops on `config.Load` the moment Argo CD syncs it.

Beyond the mechanical breakage, the refactor invalidated the ownership rule
`deploy/README.md` states — *"the umbrella owns orchestration; each submodule
owns only how to build and run itself."* The server now ships a full
infrastructure `docker-compose.yml` and its own `deploy/` directory
(Alloy, Grafana, Rybbit), which the old rule forbids.

### What changed in the backend

| Concern | Before | After |
|---|---|---|
| Database | `pgvector/pgvector:pg18-trixie` | `timescale/timescaledb-ha:pg18` |
| Durable execution | Restate + MinIO | removed |
| Domain event bus | — | Redis Streams (`eventbus.NewRedis`) |
| Telemetry buffer | — | NATS JetStream (`eventbus.DialNATS`) |
| Metrics store | Prometheus | TimescaleDB hypertables (`observability` schema) |
| Logs | — | Loki + Alloy |
| Config | `APP_*` via viper | flat env, all `required`, no defaults |
| Entrypoint | `cmd/server`, port 5005 | `cmd/gateway`, port 8080 |
| Migrations | per-module, embedded | unchanged (8 schemas, one DSN each) |
| Embedding | `APP_LLM_PYTHON_URL` → `embedding` submodule | `internal/provider/llm/litellm`, unwired |
| Hot reload | `Dockerfile.dev` + air | removed; run `go run ./cmd/gateway` on host |

`website` additionally moved bun → pnpm (Next 16.2.11, React 19, Tailwind 4) and
lost its `Dockerfile` and `.github/workflows`, so its CI and CD are also broken.

## Ownership rule

> **An artifact lives next to whatever determines its content.**
>
> - Content determined by **code** → the code's repo.
> - Content determined by **environment or topology** → the umbrella.

This resolves each open question consistently rather than case by case.

| Artifact | Owner | Reason |
|---|---|---|
| `Dockerfile` (stages `build`/`dev`/`runtime`), `docker-compose.yml`, `docker-compose.dev.yml`, `.air.toml` | server | the code decides which infra versions it needs |
| Embedded migrations | server | schema is code |
| `api/openapi.gen.yaml` + drift-check CI | server | generated from handlers |
| Grafana dashboards + datasource provisioning | server | queries target the `observability` schema; schema change and dashboard change belong in one commit |
| Alloy config, **dev** (`docker.sock`) | server | part of the dev stack |
| Alloy config, **k8s** (`discovery.kubernetes`) | umbrella | cluster topology; the dev config cannot run here |
| k8s manifests, kustomize, ingress, Argo CD | umbrella | orchestration |
| `config.env` values, secrets, public domains | umbrella | environment-specific |
| Rybbit runbook | docs | prose, not deployment |

**Rename `server/deploy/` → `server/dev/`.** Two directories named `deploy` in
two repos currently mean opposite things — dev-stack assets in one, production
orchestration in the other. That ambiguity is exactly what makes an OSS
contributor put a file in the wrong place.

## Config contract

Every field is `required` with no default, so a missing variable fails fast at
startup instead of silently running wrong.

**Non-secret → generated `ConfigMap` (`config.env`):**

```
GATEWAY_ADDR=0.0.0.0:8080
LOG_LEVEL=info
NATS_URL=nats://nats:4222
REDIS_ADDR=redis:6379
```

**Secret → `Secret`:**

- `JWT_SECRET` — min 32 bytes.
- `ID_CIPHER_KEY` — 16, 24 or 32 bytes. **Permanent:** rotating it invalidates
  every opaque id ever handed out. Back it up like a database credential.
- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`.
- Eight DSNs, one per module — they embed the password, so they are secrets, not
  ConfigMap entries: `ACCOUNT_DB_DSN`, `CATALOG_DB_DSN`, `ORDER_DB_DSN`,
  `CHAT_DB_DSN`, `COMMON_DB_DSN`, `TRUST_DB_DSN`, `FINANCE_DB_DSN`,
  `OBSERVABILITY_DB_DSN`.

**`INSTANCE_ID` comes from the downward API (`metadata.name`)**, not a literal.
`config.go` is explicit that defaulting it to the hostname is worse than failing,
because several replicas would otherwise collapse into one meaningless telemetry
series.

**Removed from the umbrella:** `APP_ENV`, `APP_PUBLIC_SITEURL`,
`APP_LLM_PYTHON_URL`, `APP_RESTATE_*`, `APP_EXCHANGE_APIKEY`, `APP_VNPAY_*`.

`SITE_URL` and `DOCS_URL` stay, but the server no longer reads any public URL.

One correction found while planning: the rewritten `website` contains no
`process.env` reference at all, so it does not consume `SITE_URL` either — the
codebase has not reached SEO/canonical work yet. The variable stays in the
ConfigMap and stays wired into the website Deployment, because that is the
documented contract and the rewrite will need it, but it is currently unread.
Nothing in the system reads `DOCS_URL` either; it is documentation of the Caddy
edge, not an application input.

## Dev stack

### One Dockerfile, named stages

Dev tooling lives in the **same** Dockerfile as production, as a `dev` stage, not in
a separate `Dockerfile.dev`. Two files describing one toolchain is the drift pattern
this whole design exists to remove — and it is the pattern that produced every real
bug found while implementing it.

- `build` — deps + static binaries.
- `dev` — Go toolchain + `air`. Deliberately not derived from `build`: source
  arrives as a bind mount, so a `COPY` would be shadowed.
- `runtime` — distroless, last stage.

**CI builds `runtime` explicitly.** Relying on "the last stage is the default" means
a stage appended later silently ships the Go toolchain in the production image.
Measured: `runtime` 39 MB with no shell, `dev` 388 MB.

Three dev modes, chosen by task rather than by preference. `--profile dev` and
`--profile app` both publish host port 5000, so they are alternatives:

| Mode | Use when | Cost |
|---|---|---|
| infra only + `go run ./cmd/gateway` on the host | normal Go iteration | fastest — native build cache; logs go to the terminal, not Loki |
| `--profile dev` (air in the `dev` stage) | logs must reach Loki, or observability is under test | ~4s rebuild on save, measured |
| `--profile app` | final check before pushing | builds the real `runtime` image; no hot reload |

Dev deliberately stays **outside** the k3d cluster — no Skaffold or Tilt. Compose
already covers iteration; k3d's job is to verify the deploy. Iterating inside the
cluster invites editing manifests for dev convenience, which is where dev and prod
start to diverge.

### The root compose file

The root compose file stops redefining infrastructure and composes the submodule
files instead, so infra versions have exactly one source of truth:

```yaml
name: shopnexus
include:
  - server/docker-compose.yml
  - website/docker-compose.yml
  - docs/docker-compose.yml
```

`cd server && docker compose up` keeps working standalone — that is the OSS
story. `docker compose up` at the root brings up the whole system.

Two interactions to handle rather than assume:

- **`profiles`.** The server's `gateway` and `migrate` services sit behind
  `profiles: ["app"]`, so a plain `include` starts only the infrastructure. The
  root file overrides both with `profiles: []` so that `docker compose up` at the
  root runs the whole system, which is the entire reason the root file exists.
- **`name`.** `docs/docker-compose.yml` declares `name: docs`. The including
  file's project name is expected to win, but this must be verified during
  implementation — if an included `name` leaks through, the docs service lands in
  the wrong compose project.

## Kubernetes changes

| Manifest | Change |
|---|---|
| `postgres.yaml` | image → `timescale/timescaledb-ha:pg18`; data path → `/home/postgres/pgdata/data` |
| `nats.yaml` | **new** — StatefulSet + PVC, `-js -sd /data -m 8222` |
| `restate.yaml` | **delete** |
| `redis.yaml` | image → `redis:7`, keep `requirepass` |
| `server.yaml` → `gateway.yaml` | command `/gateway`, port 5005 → 8080, new env contract, `INSTANCE_ID` via downward API |
| `migrate-job.yaml` | command → `/migrate` (the image builds both binaries; `ENTRYPOINT` is the gateway) |
| `ingress.yaml` | backend port → 8080 |
| `deploy/monitoring/` | replace Prometheus with Loki + Alloy + Grafana |

The database image is a hard constraint, not a preference. Migrations require
`timescaledb`, `timescaledb_toolkit`, `vector`, `postgis`, `pg_trgm` and
`unaccent`. `pgvector/pgvector` has no TimescaleDB; the plain `timescaledb` image
has neither PostGIS nor pgvector. Only the `-ha` image bundles all six.

### Known gap: no health endpoint

`internal/gateway/router.go` registers `/openapi.yaml` and `/docs` and nothing
else — there is no `/health` or `/healthz`, so an HTTP probe has nothing to hit.

This design uses a `tcpSocket` probe so the umbrella is deployable today, and
records the endpoint as **backend follow-up work**. A health endpoint is
code-owned; the umbrella should not work around its absence permanently. Switch
to `httpGet /healthz` once the backend provides it.

## Observability

Alloy's dev config discovers containers over `/var/run/docker.sock`. In
Kubernetes that mechanism does not exist — it needs `discovery.kubernetes` plus
`loki.source.kubernetes`. These are two genuinely different files, not one shared
file:

- `server/dev/alloy/config.alloy` — docker.sock (server-owned)
- `deploy/monitoring/alloy-config.yaml` — kubernetes_sd (umbrella-owned)

Grafana dashboards and datasources *are* shared, because they query the
`observability` schema. The server owns them; the umbrella mounts them into a
ConfigMap generated from the submodule path (`server/dev/grafana/…`) rather than
keeping a copy.

That cross-repo reference needs one accommodation: kustomize refuses to read files
outside its kustomization root by default, so the relaxed load restrictor must be
enabled.

**Correction found during implementation:** this is not a per-Application field.
`buildOptions` does not exist on `Application.spec.source.kustomize` (verified
against the CRD on the cluster). It is a **global** setting in the `argocd-cm`
ConfigMap, applied out-of-band:

```bash
kubectl -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--load-restrictor LoadRestrictionsNone"}}'
kubectl -n argocd rollout restart deploy/argocd-repo-server
```

That relaxes the restriction for every Application on the cluster — a real widening
of a safety boundary, acceptable here only because the cluster is single-tenant.
The alternative, copying the dashboard into the umbrella, reintroduces exactly the
drift this design exists to remove.

Prometheus is removed. Metrics now live in TimescaleDB hypertables written by the
`observability` module, so there is no `/metrics` endpoint left to scrape.

## Publishing the API spec

The server already commits `api/openapi.gen.yaml`, serves it at `/openapi.yaml`,
and guards it with a drift-check workflow. `docs` **fetches it at build time**
rather than keeping a copy:

```
docs build → fetch raw.githubusercontent.com/shopnexus/server/main/api/openapi.gen.yaml → render
```

No cross-repo token, and drift is structurally impossible. A copy in `docs` would
go stale the first time anyone edited a handler.

This is not hypothetical: `docs/docs/api/openapi.yaml` is **already a committed
copy**, wired into `docs.json` as the "HTTP Gateway" group. It happens to be
byte-identical to the server's generated file today, which means someone copied it
by hand recently — the mechanism is manual, so drift is a matter of time. The file
becomes a build artifact, fetched by the docs Dockerfile and git-ignored.

Note: the Swagger UI page in `api/api.go` loads its JS and CSS from the unpkg
CDN, so `/docs` breaks in an environment without outbound internet access.

### Correction: fetch in CI, not in a `RUN` layer

The first implementation put `curl` in a Dockerfile `RUN`. That is wrong and was
caught in production: Docker caches a `RUN` by its **instruction text**, so with
`cache-from: type=gha` the layer is reused forever and the spec freezes at whatever
the first build fetched. The docs site kept serving `baseUrlOptions: ["/"]` through
a successful rebuild, which looks identical to a working build.

The spec is now fetched by a **CI step** and arrives through the existing
`COPY docs/`. A COPY layer is content-addressed, so it invalidates exactly when the
spec changes — no cache-busting argument needed. The Dockerfile keeps a guard that
fails loudly if the file is absent, since it is git-ignored and a missing spec would
otherwise render an API reference with no operations.

### Two API doc surfaces, split by purpose

The gateway serves its own Swagger UI at `/api/v1/docs`, embedded from the same
spec the router serves. The Mintlify site renders that spec too. Rather than pick
one, they split by what each is good at:

- **Gateway `/api/v1/docs` — trying.** Same-origin with the API, so live requests
  need no CORS, no proxy and no absolute URL in the spec. Embedded in the binary,
  so it cannot drift from the routes.
- **Mintlify `api-reference/*` — reading.** Indexed, browsable without a running
  backend, sits next to the architecture prose. `api.playground.display: "simple"`
  turns off the Send button.

That last setting is not cosmetic. Mintlify's playground proxies requests through
`/_mintlify/api/request`, which exists only on their hosted platform — a static
`mint export` behind nginx 404s on it. Turning the proxy off instead would need
three further changes: an absolute server URL in the spec (putting the public
domain into a document the design keeps domain-free), CORS on the gateway (which
has none today), and accepting `Authorization` cross-origin. Not worth it while
most handlers still answer 501.

### Gap in this design: nothing rebuilds docs when the spec changes

Fetching at build time removes drift *within* a build but introduces staleness
*between* builds: the docs image only picks up a new spec when something pushes to
the docs repo. A server-side spec change leaves the published API reference stale
indefinitely, and it looks correct — which is worse than an obviously broken page.

Observed on 2026-07-29: the `/api/v1` change landed on `server` at ~03:56 while the
last docs build was 03:12, so the published reference kept advertising
`servers: url: /`.

Two ways to close it:

- **`repository_dispatch` from server CI** → docs rebuild on every spec change.
  Accurate, but cross-repo dispatch cannot use `GITHUB_TOKEN`; it needs a PAT
  stored as a secret in the server repo.
- **Scheduled rebuild** in the docs workflow (for example daily `cron`). No secret
  and no coupling, but the reference can lag by the schedule interval.

**Resolved: dispatch.** The server's `build.yml` gained a `notify-docs` job that
POSTs `spec-updated` to `shopnexus/docs`, which already listened for it. The
scheduled option was not taken — a cron rebuild trades a correct trigger for a
lag window, and the lag is the thing being fixed.

The job degrades rather than fails when `DOCS_DISPATCH_TOKEN` is unset: it warns and
exits 0, so a missing secret cannot block shipping the server. That is the right
default here but it is worth naming, because the failure mode it leaves is silent
staleness — the same one this section is about — and the only signal is a warning
annotation on a green run.

### Correction: the dispatch had to carry a sha

The first version dispatched a bare event and let docs fetch `main`. That reproduced
the staleness it was meant to fix, inside a five-minute window:
`raw.githubusercontent` serves a branch ref with `cache-control: max-age=300`
(verified: `curl -sI` on the `main` URL returns exactly that), while the dispatch
arrives seconds after the push. The docs build could therefore fetch the *previous*
spec, publish it, and never be triggered again — indistinguishable from success.

The event now carries `client_payload.sha` and the docs build fetches that exact
commit, falling back to `main` only for a build `docs` started itself. A sha URL is
immutable content, so the CDN caching it is correct instead of a hazard.

Not added, deliberately: gating `notify-docs` on the spec drift-check workflow. If
someone pushes a fragment edit without running `go generate`, the committed spec is
stale — but that is also the spec the *server* embeds and serves, so docs and server
stay consistent with each other, and `openapi.yml` is already red. A guard would buy
no additional guarantee.

## Decisions

- **`embedding` is removed from the umbrella.** The server reaches LLMs through
  `internal/provider/llm/litellm` and no config field points at the service. The
  GitHub repo stays; it is simply no longer a component of the system.
  The working tree has uncommitted changes to `main.py`, `pyproject.toml` and
  `uv.lock`, so deregistration must not delete the directory.
- **`website` gets a `Dockerfile`, a `docker-compose.yml` and `build.yml`** in
  its own repo, so `include:` works and its CD is restored.
- **The full observability stack is ported to Kubernetes** — Loki, Alloy with
  `kubernetes_sd`, and Grafana with a TimescaleDB datasource.
- **Changes land directly on `main`.** Argo CD syncs every commit, so all
  manifest edits go in as one atomic commit; the cluster must never observe a
  half-updated topology.

## Out of scope

- Adding `/healthz` to the backend (recorded above as follow-up).
- Wiring LiteLLM into the config and the deployment.
- Object storage. The `common` module records a `provider` field (`s3`, `minio`,
  `local`) but no S3 client is wired, so no storage infra is needed yet.
- The `app` (Flutter) submodule, which is not deployed.
- Removing the now-unused `restatedev/sdk-go` dependency and the stale Restate
  mention in `internal/shared/errx/errx.go` — both are backend cleanups.
