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

Each component runs itself locally from its own repo:

```bash
cd server  && docker compose up   # backend + postgres + redis + restate + minio
cd website && docker compose up    # frontend (or `bun dev` for hot reload)
```

## Deployment (CI/CD)

Hosted on a k3d cluster via GitOps (Argo CD). CI builds each component's image
in its submodule repo; Argo CD in the cluster syncs `deploy/k8s`. Full
architecture, flow diagram, and bootstrap steps: **[`deploy/README.md`](deploy/README.md)**.

```
git push (server/website) → GitHub Actions → GHCR :main
   → Argo CD Image Updater (digest) → Argo CD sync (wave-ordered)
   → k3d → Traefik ingress → Caddy (TLS) → shopnexus.hopto.org
```
