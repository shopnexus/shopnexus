# Deploy — GitOps on k3d

How ShopNexus is hosted. **Root owns orchestration; each submodule only owns its
own `Dockerfile` + dev `docker-compose.yml`.** CI builds images in the submodule
repos; CD (Argo CD) here keeps the cluster in sync with `deploy/k8s`.

## Architecture

```
push server repo ─► [server CI]  build ─► ghcr.io/shopnexus/server:main
push website repo ─► [website CI] build ─► ghcr.io/shopnexus/website:main
                                                   │
                              Argo CD Image Updater tracks :main by DIGEST
                                                   ▼
   deploy/k8s/base (this repo) ── Argo CD sync ──► k3d cluster `main`
                                                   ▼
                     Traefik ingress ─► shopnexus.hopto.org
```

Force-push safe: images use the mutable tag `:main` tracked **by digest**, so a
rebuilt `:main` (new digest) is rolled out even when the tag string is unchanged.

## What runs (`deploy/k8s/base`)

| Component | Image | Ports |
|-----------|-------|-------|
| server    | ghcr.io/shopnexus/server  | 5005 http · 8082 restate-svc · 8083 best-effort |
| website   | ghcr.io/shopnexus/website | 3000 |
| postgres  | pgvector/pgvector:pg17    | 5432 |
| redis     | redis:8-alpine            | 6379 |
| restate   | restatedev/restate        | 8080 ingress · 9070 admin · 5122 node |

Server config: the Go app bakes YAML config into the image and lets `APP_*` env
vars override any key (see `config.yaml`). Connection details are injected there;
passwords come from the `shopnexus-secret` Secret (created out-of-band).

Out of scope for now: `embedding` (Python, needed for catalog search), MinIO +
restate snapshots (only needed for a multi-node restate cluster), and
`deploy/monitoring` (Prometheus/Grafana config, not yet converted to k8s).

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
  --from-literal=POSTGRES_PASSWORD='<pg>' \
  --from-literal=REDIS_PASSWORD='<redis>' \
  --from-literal=APP_POSTGRES_PASSWORD='<pg>' \
  --from-literal=APP_REDIS_PASSWORD='<redis>' \
  --from-literal=APP_JWT_SECRET='<jwt-signing-secret>' \
  --from-literal=APP_EXCHANGE_APIKEY='<exchange-rate-api-key>' \
  --from-literal=APP_VNPAY_TMNCODE='<vnpay-tmn-code>' \
  --from-literal=APP_VNPAY_HASHSECRET='<vnpay-hash-secret>'
# Non-secret required config (e.g. APP_ORDER_RETURNURL) lives in config.env.
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
#    -> wave 2 server/website; Image Updater then tracks :main by digest).
kubectl apply -f deploy/argocd/application.yaml
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

## Prerequisite: the k3d cluster itself

The cluster must be created with the DNS/firewall fixes from
`~/linux-server-setup/k3d`. Ingress needs host ports 80/443 open in the firewall
(`fw allow 80`, `fw allow 443`).
