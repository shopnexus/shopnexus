# Deploy — GitOps on k3d

How ShopNexus is hosted. CI builds images in the submodule repos; CD (Argo CD)
here keeps the cluster in sync with `deploy/k8s`.

## Architecture

### Design principle

**An artifact lives next to whatever determines its content.**

- Content determined by **code** → the code's repo. A submodule ships its
  `Dockerfile`, its dev `docker-compose.yml`, its migrations, its generated
  OpenAPI spec, its Grafana dashboards, and a CI workflow that builds its image.
- Content determined by **environment or topology** → the umbrella. k8s manifests,
  sync ordering, ingress, GitOps wiring, domains, config values, secrets.

This keeps each component contributor-friendly (clone one repo, `docker compose
up`) and keeps environment specifics out of reusable components. It also decides
the cases the older "submodules own only build+run" rule got wrong: a Grafana
dashboard whose queries target the `observability` hypertable schema is *code*, so
it lives in `server`, and the umbrella reads it across the submodule boundary
rather than keeping a copy that would drift the moment the schema changed.

The root `docker-compose.yml` follows the same rule: it defines **no** services,
only `include:`s the submodule compose files, so infra versions have exactly one
source of truth.

### Repo topology

```
shopnexus (umbrella, PUBLIC)            ← this repo: orchestration + GitOps
├── docker-compose.yml                     dev: pure `include:` of the submodules
├── deploy/k8s/base/                       kustomize: the whole cluster topology
│   ├── postgres · redis · nats            wave 0  (stateful infra)
│   ├── migrate-job.yaml                    wave 1  (Argo Sync hook, 8 schemas)
│   ├── gateway · website · ingress        wave 2  (apps, via Traefik ingress)
│   ├── docs.yaml                            wave 2  (Mintlify static, docs.<domain> subdomain)
│   ├── config.env  → ConfigMap (generated) non-secret flat config (no APP_ prefix)
│   ├── secret.example.yaml                  template: keys + 8 per-module DSNs
│   └── kustomization.yaml                  images pinned here (Image Updater edits)
├── deploy/k8s/overlays/local/             run locally-built images on k3d
├── deploy/argocd/application.yaml          the Argo CD Application (+ Image Updater)
├── deploy/argocd/monitoring.yaml           2nd Argo App → deploy/monitoring
└── deploy/monitoring/                      loki + alloy + grafana (own kustomize + Argo App)

server  (submodule)   Go backend   — Dockerfile, docker-compose.yml, dev/{alloy,grafana}, .github/workflows/
website (submodule)   Next.js      — Dockerfile, docker-compose.yml, .github/workflows/build.yml
docs    (submodule)   Mintlify     — Dockerfile, docker-compose.yml (fetches the OpenAPI spec at build)
```

### Two planes: CI (build) vs CD (deploy)

They are decoupled and live in different repos — this is the core of the design.

```
 ── CI (in each submodule repo) ─────────────────────────────────────────────
  git push main ─► GitHub Actions (build.yml)
                     • docker buildx build
                     • push ghcr.io/shopnexus/<comp>:main  +  :sha-<commit>
                   (website bakes NEXT_PUBLIC_* at build time via --build-arg)

 ── CD (in the cluster, pull-based) ─────────────────────────────────────────
  Argo CD  ── watches ──► umbrella repo  deploy/k8s/base   (manifests)
  Image Updater ── watches ──► GHCR :main by DIGEST         (image versions)
        │
        │ new commit OR new image digest
        ▼
  Argo sync (wave-ordered) ─► k3d cluster `main`
```

CI never touches the cluster (GitHub can't reach a home k3d). CD is **pull-based**:
Argo + Image Updater run *inside* the cluster and pull from GitHub/GHCR, so no
inbound access to the machine is needed.

### End-to-end flow (code change → live)

```
 dev ──git push──► server/website repo
                        │ Actions build.yml
                        ▼
               ghcr.io/shopnexus/<comp>:main  (new digest)   ◄── PUBLIC packages
                        │
        Argo CD Image Updater (polls every ~2m, digest strategy)
        writes the new @sha256 into the Application's kustomize images
                        │
                 Argo CD detects drift → sync
                        ▼
     ┌──────────────── k3d cluster `main` (namespace: shopnexus) ───────────────┐
     │  wave 0:  postgres     redis     nats         (become Healthy first)      │
     │  wave 1:  db-migrate Job  → go:embed migrations, per-module, idempotent   │
     │  wave 2:  gateway (8080)  website (3000)      (rolling update)            │
     │                        │                                                  │
     │            Traefik Ingress  (host-agnostic app + docs.internal alias)     │
     │              /api → gateway:8080   / → website:3000                       │
     │              host docs.internal   → docs:80                               │
     └───────────────────────────────┬──────────────────────────────────────────┘
                                      │ k3d loadbalancer  -p 8080:80
                                      ▼
                     Caddy (host, TLS/:443)  reverse_proxy localhost:8080
                                      ▼
              https://shop.toanehihi.io.vn · https://docs.toanehihi.io.vn ─► user
```

**Edge:** Caddy is the public TLS terminator (auto-HTTPS) and forwards to the
cluster's Traefik on `localhost:8080`. **The public domains live only in Caddy.**
The app ingress is **host-agnostic** — Caddy passes the real storefront Host
through and Traefik just splits `/api` vs `/`. Docs needs a host of its own (its
assets are root-absolute), so Caddy rewrites the docs Host to a **stable internal
alias** `docs.internal` that the docs ingress matches — the public docs domain
never appears in a manifest. No cert-manager needed.

```caddyfile
shop.toanehihi.io.vn {
  reverse_proxy localhost:8080                          # Host preserved → app
}
docs.toanehihi.io.vn {
  reverse_proxy localhost:8080 {
    header_up Host docs.internal                        # → docs ingress
  }
}
```

**Force-push safe:** images use the mutable tag `:main`, tracked **by digest** —
a rebuilt `:main` (new digest) rolls out even though the tag string is unchanged.

### Config & secrets model

The contract is **flat, unprefixed environment variables** — the `APP_*` + viper
layer is gone, along with the YAML config file it overrode. Every field is
`required` **with no default**, so a missing variable is a startup crash rather
than a plausible-looking wrong value (`server/internal/config/config.go`).

- **Non-secret** config → `deploy/k8s/base/config.env` → generated `ConfigMap`
  (kustomize `configMapGenerator`; hash suffix ⇒ a config change auto-rolls pods).
  `GATEWAY_ADDR`, `LOG_LEVEL`, `NATS_URL`, `REDIS_ADDR`, plus the public URLs.
- **Secret** config → `shopnexus-secret` `Secret`, created out-of-band, never in
  git (`secret.example.yaml` is the template). `POSTGRES_PASSWORD`,
  `REDIS_PASSWORD`, `JWT_SECRET`, `ID_CIPHER_KEY`, and the **eight per-module
  DSNs** — those are secrets, not ConfigMap entries, because they embed the
  password.
- Service DNS names in compose and k8s are identical (`postgres`, `redis`, `nats`),
  so the same values work in both environments.

**Eight DSNs, one database.** `ACCOUNT_DB_DSN` … `OBSERVABILITY_DB_DSN` all point
at the same Postgres today; each module isolates its tables in a Postgres schema
named after it (`search_path` set per pool), so any one module can be moved to its
own server later by changing only its DSN.

**One value, one place (no derived duplicates):**

- **`INSTANCE_ID` comes from the downward API** (`metadata.name`), not a literal.
  It tags every telemetry row with the pod that produced it; a shared value would
  collapse replicas into one meaningless series, which is why the app requires it
  instead of defaulting to the hostname.
- **`ID_CIPHER_KEY` is permanent.** It keys the Feistel permutation behind every
  opaque id on the wire. Rotating it invalidates every id ever handed out — back it
  up like a database credential.
- **Public domain → `SITE_URL` only.** The gateway no longer reads any public URL.
  Only the website Deployment consumes it (and the current storefront rewrite does
  not read it yet — it is the documented contract for SEO/canonical work). Browser
  API calls are **same-origin `/api/v1`**, so they need no URL config at all.
  `DOCS_URL` documents the Caddy edge; no workload reads it.
- **Passwords → one key each.** `POSTGRES_PASSWORD` / `REDIS_PASSWORD` are the
  single source; the postgres/redis containers read those same keys as their image
  env names, so there is no duplicate password value to keep matched.

### Sync-wave ordering (why it matters)

Argo applies resources in wave order, waiting for each wave to be Healthy:
`0` infra (postgres/redis/nats) → `1` `db-migrate` (a Sync hook, so it can
re-run each sync and can't run before the DB exists) → `2` gateway/website. This
guarantees migrations run against a live DB, and apps start against a migrated DB.

The migration Job takes the **full** `envFrom` pair, not just the database
connection: `cmd/migrate` calls the same `config.Load` as the gateway, so it
validates every field. Handing it only the DSNs fails validation on
`GATEWAY_ADDR`, `JWT_SECRET`, `ID_CIPHER_KEY` and the rest.

## What runs (`deploy/k8s/base`)

| Component | Image | Ports |
|-----------|-------|-------|
| gateway   | ghcr.io/shopnexus/server  | 8080 http |
| website   | ghcr.io/shopnexus/website | 3000 |
| docs      | ghcr.io/shopnexus/docs    | 80 (ingress host `docs.<domain>`) |
| postgres  | timescale/timescaledb-ha:pg18 | 5432 |
| redis     | redis:7                   | 6379 |
| nats      | nats:2.10-alpine          | 4222 client · 8222 monitoring |

The **database image is not interchangeable.** The migrations require
`timescaledb`, `timescaledb_toolkit`, `vector` (pgvector), `postgis`, `pg_trgm`
and `unaccent`. `pgvector/pgvector` has no TimescaleDB; the plain `timescaledb`
image has neither PostGIS nor pgvector. Only the `-ha` image bundles all six. It
also stores data at `/home/postgres/pgdata`, not `/var/lib/postgresql/data`.

**NATS is a StatefulSet, not a Deployment,** because JetStream holds durable state:
it buffers observability telemetry between the Sink and the batching writer, so a
slow database never blocks a request and queued samples survive a restart. Domain
events do not go through NATS — those are Redis Streams.

Restate and MinIO are gone. The backend no longer uses durable execution, and no
S3 client is wired (the `common` module records a storage `provider` string but
nothing reads it yet).

`docs` is the Mintlify site built to a static bundle (`mint export`) served by
nginx. Its export uses root-absolute paths (`/_next`, `/api`, …) that would
collide with the app under one host, so it gets its **own subdomain**
(`docs.<domain>`) via the docs Ingress — a normal ClusterIP service behind the
same Caddy→Traefik edge. Set the host in `ingress.yaml` (and `DOCS_URL` in
`config.env`) and add a Caddy block for the subdomain.

Gateway config: flat env only — there is no YAML config in the image any more.
Non-secret keys in `config.env` → ConfigMap; keys and the eight per-module DSNs in
the `shopnexus-secret` Secret, created out-of-band. See "Config & secrets model".

**Monitoring** (`deploy/monitoring`) runs **Loki + Alloy + Grafana** as a *separate*
Argo CD Application (`deploy/argocd/monitoring.yaml`) in the same namespace, so
it's optional and never gates the app rollout. There is **no Prometheus**: metrics
are written directly into TimescaleDB hypertables by the backend's `observability`
module, and the gateway exposes no `/metrics` endpoint. Grafana reads those tables
over a Postgres datasource, and container logs over Loki (shipped by Alloy).
Details: `deploy/monitoring/README.md`.

Out of scope for now: object storage (the `common` module records a storage
`provider` string, but no S3 client is wired), and LiteLLM (the provider exists at
`server/internal/provider/llm/litellm` but no config field points at it — which is
why the `embedding` submodule was dropped from this repo).

### Known gaps

Two deliberate compromises, recorded so they are not mistaken for oversights:

- **No health endpoint.** `server/internal/gateway/router.go` exposes
  `/openapi.yaml` and `/docs` and nothing else, so the gateway's probes are
  `tcpSocket` — they prove the port is open, not that the app is serving. Switch
  both probes to `httpGet /healthz` once the backend adds one.
- **Swagger UI needs outbound internet.** `/docs` loads swagger-ui from the unpkg
  CDN, so the page is blank in an air-gapped cluster. Vendor the assets into the
  server image to fix it there.

## Bootstrap (one-time)

This is the verified, working sequence (the commented gotchas are real — each
cost a debugging cycle the first time).

```bash
# kube context for the k3d cluster
k3d kubeconfig merge main --kubeconfig-switch-context

# 1. Install Argo CD — MUST be --server-side (the applicationsets CRD exceeds
#    the client-side apply annotation size limit).
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 1b. Submodules must be ENABLED (Argo's default). deploy/monitoring generates the
#     Grafana dashboard ConfigMap from server/dev/grafana, so the repo-server has
#     to check the submodule out. This works only because .gitmodules uses HTTPS
#     URLs — with the old SSH URLs Argo could not authenticate and the checkout
#     failed, which is why an earlier version of this runbook disabled it.
kubectl -n argocd set env deploy/argocd-repo-server ARGOCD_GIT_MODULES_ENABLED=true

# 1b-ii. Same reason: the dashboard lives outside deploy/monitoring, and kustomize
#     refuses to read outside its root. This is a GLOBAL argocd-cm setting — it is
#     NOT a field on Application.spec.source.kustomize (that field does not exist).
#     Note it relaxes the restriction for every Application on the cluster.
kubectl -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--load-restrictor LoadRestrictionsNone"}}'
kubectl -n argocd rollout restart deploy/argocd-repo-server

# 1c. Image Updater — use a versioned tag ('stable' 404s).
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v0.16.0/manifests/install.yaml

# 2. App secrets (NEVER commit these — see secret.example.yaml). Every config
#    field is required with no default, so a missing key is a crash-loop.
kubectl create namespace shopnexus
PG='<pg>'
DSN="postgres://shopnexus:$PG@postgres:5432/shopnexus?sslmode=disable"
kubectl -n shopnexus create secret generic shopnexus-secret \
  --from-literal=POSTGRES_PASSWORD="$PG" \
  --from-literal=REDIS_PASSWORD='<redis>' \
  --from-literal=JWT_SECRET='<>=32-byte-jwt-signing-secret>' \
  --from-literal=ID_CIPHER_KEY='<16-24-or-32-byte-key>' \
  --from-literal=ACCOUNT_DB_DSN="$DSN" \
  --from-literal=CATALOG_DB_DSN="$DSN" \
  --from-literal=ORDER_DB_DSN="$DSN" \
  --from-literal=CHAT_DB_DSN="$DSN" \
  --from-literal=COMMON_DB_DSN="$DSN" \
  --from-literal=TRUST_DB_DSN="$DSN" \
  --from-literal=FINANCE_DB_DSN="$DSN" \
  --from-literal=OBSERVABILITY_DB_DSN="$DSN"
#    postgres/redis read POSTGRES_PASSWORD / REDIS_PASSWORD directly (same keys as
#    the app) — no duplicate values to keep matched.
#    ID_CIPHER_KEY is PERMANENT: rotating it invalidates every opaque id ever
#    handed out. Back it up like a database credential.
# Non-secret required config lives in config.env (GATEWAY_ADDR, LOG_LEVEL,
# NATS_URL, REDIS_ADDR, SITE_URL, DOCS_URL).
# Crash-loop on "validate config ... required" -> add that key here (if it is a
# credential or a DSN) or in config.env (if it is not).

# 3. GHCR pull. For PUBLIC packages, no PAT: an empty docker-config secret makes
#    kubelet pull anonymously (satisfies the deployments' imagePullSecrets: ghcr).
kubectl -n shopnexus create secret generic ghcr \
  --type=kubernetes.io/dockerconfigjson --from-literal=.dockerconfigjson='{"auths":{}}'
#    For PRIVATE packages instead: a real docker-registry secret in BOTH
#    shopnexus (pods) and argocd (Image Updater), + re-add the
#    `argocd-image-updater.argoproj.io/pull-secret: pullsecret:argocd/ghcr`
#    annotation to application.yaml.

# 4. Repo access: the umbrella repo is PUBLIC, so Argo needs no repo creds.
#    (If you make it private: create an argocd repository secret with a token.)

# 5. Register the app — Argo takes over (wave 0 infra -> wave 1 db-migrate hook
#    -> wave 2 gateway/website/docs; Image Updater then tracks :main by digest).
kubectl apply -f deploy/argocd/application.yaml

# 6. Docs on its own subdomain (Mintlify static, via the docs Ingress). It rides
#    the same :8080 edge as the app. In Caddy, route the public docs domain to
#    :8080 and rewrite Host to the internal alias the docs ingress matches (the
#    public domain stays only in Caddy):
#      docs.toanehihi.io.vn { reverse_proxy localhost:8080 { header_up Host docs.internal } }
# → docs at https://docs.<domain>

# 7. Monitoring (optional) — Loki + Alloy + Grafana as a separate Argo App.
#    Requires steps 1b and 1b-ii above (submodules + load-restrictor), because the
#    dashboard ConfigMap is generated from server/dev/grafana.
#    No secret needed to start (Grafana defaults to admin/admin); see
#    deploy/monitoring/README.md to set GRAFANA_ADMIN_PASSWORD.
kubectl apply -f deploy/argocd/monitoring.yaml
```

## Day-to-day

- **Deploy code:** just push to `server` / `website` / `docs` main. CI builds
  `:main`, Image Updater rolls it out. Nothing to do here.
- **Change topology/config:** edit `deploy/k8s/base/*`, push to this repo. Argo
  syncs automatically.
- **Check status:** `kubectl -n shopnexus get pods` · Argo UI:
  `kubectl -n argocd port-forward svc/argocd-server 8081:443` then
  https://localhost:8081 (admin password: `kubectl -n argocd get secret
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
- **Rollback:** in the Argo UI, or pin a digest in `deploy/k8s/base/kustomization.yaml`.
- **Metrics/dashboards/logs:** Grafana is on `grafana.<domain>` via the ingress, or
  `kubectl -n shopnexus port-forward svc/grafana 3000:3000` (admin/admin by
  default). Metrics are SQL against the `observability` schema; logs are LogQL over
  Loki, e.g. `{service="gateway"} | json`.

## Prerequisite: the k3d cluster itself

The cluster must be created with the DNS/firewall fixes from
`~/linux-server-setup/k3d`. Ingress needs host ports 80/443 open in the firewall
(`fw allow 80`, `fw allow 443`).
