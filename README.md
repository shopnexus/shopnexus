# ShopNexus

Umbrella repository for ShopNexus. Each component lives in its own git submodule.

## Components

| Path      | Repository              | Description            |
| --------- | ----------------------- | ---------------------- |
| `app`     | `shopnexus/app-android` | Android app (Kotlin)   |
| `docs`    | `shopnexus/docs`        | Documentation          |
| `server`  | `shopnexus/server`      | Backend (Go)           |
| `website` | `shopnexus/website`     | Web frontend (Next.js) |

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

## Deployment

Each component repo builds its own image in GitHub Actions and pushes it to
GHCR: `:main` on every push to `main`, `X.Y.Z` on every `vX.Y.Z` tag. `infra/`
holds the cluster that runs them: one k3d cluster with a server node and
three agents, and two stacks of ShopNexus in it.

| Stack | Domain | Namespace | Follows |
|---|---|---|---|
| dev | `dev.shopnexus.id.vn` | `shopnexus-dev` | `:main`, by digest |
| prod | `shopnexus.id.vn` | `shopnexus-prod` | the newest `X.Y.Z` tag |

Each stack serves the website on its domain and `api.`, `media.`, `docs.`
and `ops.` below it. Argo CD syncs the Helm chart in `infra/stack` once per
stack, and Argo CD Image Updater moves the image tags. Postgres runs on
CloudNativePG, Restate on restate-operator; prod runs two Postgres instances
and three Restate nodes.

To run your own copy:

1. Fork this repo. Set `repoURL` in `infra/argocd/root.yaml` and
   `infra/argocd/stacks.yaml`, and `domain` in
   `infra/stack/values-dev.yaml` and `infra/stack/values-prod.yaml`.
2. Point DNS at the machine: `<domain>`, `*.<domain>` and `*.dev.<domain>`.
3. Run `infra/cluster/up.sh direct` with `ACME_EMAIL` set when Traefik may
   take ports 80 and 443, or `infra/cluster/up.sh behind-proxy` when another
   proxy on the machine holds them and forwards to `127.0.0.1:18080`.
4. Run `infra/cluster/seal.sh dev` and `infra/cluster/seal.sh prod`, fill in
   the two values each `.env` asks for, run them again, then commit and push
   `infra/stack/secrets/`.
5. Argo CD brings up both stacks. `infra/smoke.sh <domain>` checks one.

`seal.sh` keeps the generated keys in the git-ignored
`infra/stack/secrets/<stack>.env`. Back those files up, and the controller's
key with them: `kubectl -n kube-system get secret -l
sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`. Without the key, the
committed SealedSecrets cannot be opened on a new cluster.

`infra/check.sh` renders the chart for both stacks and checks it; CI runs it
on every change under `infra/`. The design is in
`docs/superpowers/specs/2026-11-04-infra-k3d-stacks-design.md`.
