# ShopNexus

Umbrella repository for ShopNexus. Each component lives in its own git submodule.

## Components

| Path      | Repository         | Description            |
| --------- | ------------------ | ---------------------- |
| `app`     | `shopnexus/app`     | Mobile app (Flutter)   |
| `docs`    | `shopnexus/docs`    | Documentation          |
| `server`  | `shopnexus/server`  | Backend (Go)           |
| `website` | `shopnexus/website` | Web frontend (Next.js) |

## Clone

Submodules use HTTPS URLs, so this needs no SSH key:

```bash
git clone --recurse-submodules https://github.com/shopnexus/shopnexus.git
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

## Update submodules to latest

```bash
git submodule update --remote --merge
```

## Development

The whole system, from here. The root `docker-compose.yml` defines no services of
its own — it `include:`s each submodule's compose file, so infra versions have one
source of truth:

```bash
docker compose --profile app up --build   # infra + gateway + storefront + docs
docker compose up -d                      # infra only (db, redis, nats, grafana, loki, alloy)
```

`--profile app` is required because the server's compose keeps `gateway` and
`migrate` behind that profile, and Compose does not let an including file clear an
inherited profile list.

A single component, from its own repo — this is how each submodule is meant to be
worked on, and needs nothing from the umbrella:

```bash
cd server  && docker compose up -d                          # infra only; run `go run ./cmd/gateway` on the host
cd server  && docker compose --profile app up -d --build    # infra + gateway + migrations
cd website && docker compose up                             # storefront, hot reload
cd docs    && docker compose up --build                     # docs site (nginx)
```

## Deployment (CI/CD)

Hosted on a k3d cluster via GitOps (Argo CD). CI builds each component's image
in its submodule repo; Argo CD in the cluster syncs `deploy/k8s`. Full
architecture, flow diagram, and bootstrap steps: **[`deploy/README.md`](deploy/README.md)**.

```
git push (server/website/docs) → GitHub Actions → GHCR :main
   → Argo CD Image Updater (digest) → Argo CD sync (wave-ordered)
   → k3d → Traefik ingress → Caddy (TLS) → shop.toanehihi.io.vn
```
