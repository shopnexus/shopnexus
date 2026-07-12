# Deploy — GitOps on k3d

How ShopNexus is hosted. **Root owns orchestration; each submodule only owns its
own `Dockerfile` + dev `docker-compose.yml`.** CI builds images in the submodule
repos; CD (Argo CD) here keeps the cluster in sync with `deploy/k8s`.

## Architecture

### Design principle

**The umbrella repo owns orchestration; each submodule owns only how to build and
run itself.** A submodule (`server`, `website`) ships a `Dockerfile` + a dev
`docker-compose.yml` and a CI workflow that builds its image — nothing about the
cluster, ingress, or secrets. The umbrella owns the whole-system view: k8s
manifests, sync ordering, GitOps, ingress. This keeps each component
contributor-friendly (clone, `docker compose up`) and keeps infra out of
reusable components.

### Repo topology

```
shopnexus (umbrella, PUBLIC)            ← this repo: orchestration + GitOps
├── deploy/k8s/base/                       kustomize: the whole cluster topology
│   ├── postgres · redis · restate         wave 0  (stateful infra)
│   ├── migrate-job.yaml                    wave 1  (Argo Sync hook)
│   ├── server · website · ingress         wave 2  (apps, via Traefik ingress)
│   ├── docs.yaml                            wave 2  (Mintlify static, docs.<domain> subdomain)
│   ├── config.env  → ConfigMap (generated) non-secret APP_* config
│   └── kustomization.yaml                  images pinned here (Image Updater edits)
├── deploy/k8s/overlays/local/             run locally-built images on k3d
├── deploy/argocd/application.yaml          the Argo CD Application (+ Image Updater)
├── deploy/argocd/monitoring.yaml           2nd Argo App → deploy/monitoring
└── deploy/monitoring/                      prometheus + grafana (own kustomize + Argo App)

server  (submodule)   Go backend   — Dockerfile, docker-compose.yml, .github/workflows/build.yml
website (submodule)   Next.js      — Dockerfile, docker-compose.yml, .github/workflows/build.yml
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
     │  wave 0:  postgres     redis     restate      (become Healthy first)      │
     │  wave 1:  db-migrate Job  → go:embed migrations, per-module, idempotent   │
     │  wave 2:  server (5005)   website (3000)      (rolling update)            │
     │                        │                                                  │
     │            Traefik Ingress  (host-agnostic app + docs.internal alias)     │
     │              /api → server:5005   / → website:3000                        │
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

The single contract is **`APP_*` environment variables** (server uses viper
`AutomaticEnv`, prefix `APP`), the same interface docker-compose and k8s both
speak. Any YAML config key is overridable, e.g. `postgres.host` ← `APP_POSTGRES_HOST`.

- **Non-secret** config → `deploy/k8s/base/config.env` → generated `ConfigMap`
  (kustomize `configMapGenerator`; hash suffix ⇒ a config change auto-rolls pods).
- **Secret** config → `shopnexus-secret` `Secret`, created out-of-band, never in
  git (`secret.example.yaml` is the template).
- Service DNS names in compose and k8s are identical (`postgres`, `redis`,
  `restate`), so `APP_*_HOST` values match across both environments.

**One value, one place (no derived duplicates):**

- **Public domain → `SITE_URL` only.** The server reads it as `APP_PUBLIC_SITEURL`
  (mapped from `SITE_URL` via `configMapKeyRef` in `server.yaml`) and **derives**
  the payment return URL (`…/payment/result`) and the SePay base *in code* — there
  is no `APP_ORDER_RETURNURL` / `publicBaseUrl` to keep in sync. The website reads
  `SITE_URL` for SEO; browser API calls are **same-origin `/api/v1`**, so they need
  no URL config at all. Change the domain in one line and re-sync.
- **Passwords → one key each.** `APP_POSTGRES_PASSWORD` / `APP_REDIS_PASSWORD` are
  the single source; the postgres/redis containers map their image env names
  (`POSTGRES_PASSWORD` / `REDIS_PASSWORD`) from those keys, so there is no duplicate
  password value to keep matched.

### Sync-wave ordering (why it matters)

Argo applies resources in wave order, waiting for each wave to be Healthy:
`0` infra (postgres/redis/restate) → `1` `db-migrate` (a Sync hook, so it can
re-run each sync and can't run before the DB exists) → `2` server/website. This
guarantees migrations run against a live DB, and apps start against a migrated DB.

## What runs (`deploy/k8s/base`)

| Component | Image | Ports |
|-----------|-------|-------|
| server    | ghcr.io/shopnexus/server  | 5005 http · 8082 restate-svc · 8083 best-effort |
| website   | ghcr.io/shopnexus/website | 3000 |
| docs      | ghcr.io/shopnexus/docs    | 80 (ingress host `docs.<domain>`) |
| postgres  | pgvector/pgvector:pg17    | 5432 |
| redis     | redis:8-alpine            | 6379 |
| restate   | restatedev/restate        | 8080 ingress · 9070 admin · 5122 node |

`docs` is the Mintlify site built to a static bundle (`mint export`) served by
nginx. Its export uses root-absolute paths (`/_next`, `/api`, …) that would
collide with the app under one host, so it gets its **own subdomain**
(`docs.<domain>`) via the docs Ingress — a normal ClusterIP service behind the
same Caddy→Traefik edge, no bespoke host port. Set the host in `ingress.yaml`
(and `DOCS_URL` in `config.env`) and add a Caddy block for the subdomain.

Server config: the Go app bakes YAML config into the image and lets `APP_*` env
vars override any key (non-secret in `config.env` → ConfigMap; passwords in the
`shopnexus-secret` Secret, created out-of-band). See "Config & secrets model".

**Monitoring** (`deploy/monitoring`) runs Prometheus + Grafana as a *separate*
Argo CD Application (`deploy/argocd/monitoring.yaml`) in the same namespace, so
it's optional and never gates the app rollout. Prometheus scrapes
`server:5005/metrics`; Grafana auto-provisions the Prometheus datasource. Reach
both by port-forward (see Day-to-day). Details: `deploy/monitoring/README.md`.

Out of scope for now: `embedding` (Python, needed for catalog search), and MinIO +
restate snapshots (only needed for a multi-node restate cluster).

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

# 1b. This umbrella repo has git submodules with SSH URLs. Argo would try to
#     `git submodule update --init` them over SSH and fail. deploy/ needs no
#     submodule, so disable submodule fetching on the repo-server.
kubectl -n argocd set env deploy/argocd-repo-server ARGOCD_GIT_MODULES_ENABLED=false

# 1c. Image Updater — use a versioned tag ('stable' 404s).
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v0.16.0/manifests/install.yaml

# 2. App secrets (NEVER commit these — see secret.example.yaml). Each APP_*
#    overrides a YAML key; the server refuses to start without the required ones.
kubectl create namespace shopnexus
kubectl -n shopnexus create secret generic shopnexus-secret \
  --from-literal=APP_POSTGRES_PASSWORD='<pg>' \
  --from-literal=APP_REDIS_PASSWORD='<redis>' \
  --from-literal=APP_JWT_SECRET='<jwt-signing-secret>' \
  --from-literal=APP_EXCHANGE_APIKEY='<exchange-rate-api-key>' \
  --from-literal=APP_VNPAY_TMNCODE='<vnpay-tmn-code>' \
  --from-literal=APP_VNPAY_HASHSECRET='<vnpay-hash-secret>'
#    postgres/redis read APP_POSTGRES_PASSWORD / APP_REDIS_PASSWORD directly
#    (their image env names are mapped from these) — no duplicate keys.
# Non-secret required config (e.g. SITE_URL) lives in config.env; the payment
# return URL is derived from SITE_URL in code (no separate key).
# Crash-loop on "validate ... Error ... required" -> add that APP_* key here
# (secret) or in config.env (non-secret).

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
#    -> wave 2 server/website/docs; Image Updater then tracks :main by digest).
kubectl apply -f deploy/argocd/application.yaml

# 6. Docs on its own subdomain (Mintlify static, via the docs Ingress). No k3d
#    port-add / firewall hole — it rides the same :8080 edge as the app. In Caddy,
#    route the public docs domain to :8080 and rewrite Host to the internal alias
#    the docs ingress matches (the public domain stays only in Caddy):
#      docs.toanehihi.io.vn { reverse_proxy localhost:8080 { header_up Host docs.internal } }
# → docs at https://docs.<domain>

# 7. Monitoring (optional) — Prometheus + Grafana as a separate Argo App.
#    No secret needed to start (Grafana defaults to admin/admin); see
#    deploy/monitoring/README.md to set GRAFANA_ADMIN_PASSWORD.
kubectl apply -f deploy/argocd/monitoring.yaml
```

## Day-to-day

- **Deploy code:** just push to `server` / `website` main. CI builds `:main`,
  Image Updater rolls it out. Nothing to do here.
- **Change topology/config:** edit `deploy/k8s/base/*`, push to this repo. Argo
  syncs automatically.
- **Check status:** `kubectl -n shopnexus get pods` · Argo UI:
  `kubectl -n argocd port-forward svc/argocd-server 8081:443` then
  https://localhost:8081 (admin password: `kubectl -n argocd get secret
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
- **Rollback:** in the Argo UI, or pin a digest in `deploy/k8s/base/kustomization.yaml`.
- **Metrics/dashboards:** `kubectl -n shopnexus port-forward svc/grafana 3000:3000`
  (→ http://localhost:3000, admin/admin by default) and `svc/prometheus 9090:9090`.

## Prerequisite: the k3d cluster itself

The cluster must be created with the DNS/firewall fixes from
`~/linux-server-setup/k3d`. Ingress needs host ports 80/443 open in the firewall
(`fw allow 80`, `fw allow 443`).
