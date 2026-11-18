# ShopNexus

Umbrella repository for ShopNexus. Each component lives in its own git submodule.

## Components

| Path      | Repository              | Description                            |
| --------- | ----------------------- | -------------------------------------- |
| `agent`   | `shopnexus/agent`       | Console agent (NestJS)                 |
| `app`     | `shopnexus/app-android` | Android app (Kotlin)                   |
| `brand`   | `shopnexus/brand`       | Mascot art and icons for app and website |
| `console` | `shopnexus/console`     | Moderation console (React)             |
| `docs`    | `shopnexus/docs`        | Documentation                          |
| `server`  | `shopnexus/server`      | Backend (Go)                           |
| `website` | `shopnexus/website`     | Storefront (Astro)                     |

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

The root `docker-compose.yml` runs the whole system on one machine, in three
stacks. Each profile is a stack of its own, with its own network, Postgres,
Restate, RustFS and volumes, so the stacks share no data and run at the same
time. They need Docker and nothing else on the machine.

```bash
cp -n server/.env.example server/.env   # then fill in its three LLM_ lines
make dev                                 # everything, live reload
make prod                                # the images the cluster runs
make test                                # the server's Go tests
make down                                # stop every stack; data stays
```

Each target is one `docker compose` command, in the root `Makefile`, for
machines without `make`.

`dev` and `prod` each sit behind one Caddy that routes by host, as the
cluster's ingress does, on the domain `shopnexus.localhost`. Every host shares
that site, as the cluster's hosts share theirs, so the console's `SameSite`
cookie reaches the API:

| App | dev | prod |
|---|---|---|
| website | http://shopnexus.localhost:56481 | http://shopnexus.localhost:56480 |
| api | http://api.shopnexus.localhost:56481 | http://api.shopnexus.localhost:56480 |
| media | http://media.shopnexus.localhost:56481 | http://media.shopnexus.localhost:56480 |
| docs | http://docs.shopnexus.localhost:56481 | http://docs.shopnexus.localhost:56480 |
| console | http://console.shopnexus.localhost:56481 | http://console.shopnexus.localhost:56480 |
| Grafana | http://grafana.shopnexus.localhost:56481 | http://grafana.shopnexus.localhost:56480 |
| Restate UI | http://restate.shopnexus.localhost:56481 | http://restate.shopnexus.localhost:56480 |
| RustFS console | http://s3.shopnexus.localhost:56481 | http://s3.shopnexus.localhost:56480 |

Grafana gets the server's traces, metrics and logs. Locally the three
dashboards need no sign-in, and the RustFS console signs in with the stack's
object store keys, `shopnexus` and `shopnexus-secret`.

`dev` runs the server with `go run` and the web apps' dev servers. With
`--watch`, a saved file is copied into its container: the web apps reload the
page, and the server's container restarts on the new code in a few seconds. A
change to `go.mod`, `package.json` or a lock file rebuilds the image, and a
change under `server/migrations` runs the migrations again. Docs show the
internal pages; `DOCS_INTERNAL=false` before the command hides them. Search
is empty in dev, because only `bun run build` makes the Pagefind index.

`prod` builds every component from its Dockerfile. Its server runs with
`APP_ENV=dev`, so PNV's test numbers sign in.

`test` runs `go test -race ./...` for the server against Postgres, Restate
and RustFS on tmpfs. `run` exits with the tests' status and leaves the three
running for the next run; `make down` empties them.

In `dev` and `prod` the server and the console agent call the remote models
through the stack's LiteLLM (`litellm`), as in the cluster, with the config
in `infra/stack/litellm/` and one key per purpose that the stack generates.
LiteLLM reads its two upstream keys from
`infra/stack/secrets/compose.env`, which you create:
`LLM_UPSTREAM_API_KEY` for the OpenAI-compatible API at
`LLM_UPSTREAM_BASE_URL` (`infra/stack/env/litellm.env`) and
`OPENROUTER_API_KEY` for `embed-text`. Speech, photo vectors and video
frames run in the server itself (module `ai`), with about 4.5 GB of model
files that `fetch-models-*` downloads into the stack's `models` volume on
the first start. The console agent has no host: only the server calls it,
and its database is `agent` in the stack's Postgres. The first start of a
stack writes the server's keys into its volume, and
`docker compose --profile <stack> down -v` deletes the stack's data and keys.

Each component also runs from its own repository, as its README says; the
server, for example, with `make run` and `make test`.

## Deployment

Each component repo builds its own image in GitHub Actions and pushes it to
GHCR: `:main` on every push to `main`, `X.Y.Z` on every `vX.Y.Z` tag. `infra/`
holds the cluster that runs them: one k3d cluster with a server node and
three agents, and two stacks of ShopNexus in it.

| Stack | Domain | Namespace | Follows |
|---|---|---|---|
| dev | `dev.shopnexus.id.vn` | `shopnexus-dev` | `:main`, by digest |
| prod | `shopnexus.id.vn` | `shopnexus-prod` | the newest `X.Y.Z` tag |

Each stack serves the website on its domain and `api.`, `media.`,
`docs.` and `console.` (the moderation console) below it. Argo CD syncs the Helm chart in `infra/stack` once per
stack, and Argo CD Image Updater moves the image tags. Postgres runs on
CloudNativePG, Restate on restate-operator; prod runs two Postgres instances
and three Restate nodes. The console agent runs in each stack with no host:
NetworkPolicies let only the server reach it and only the agent reach the
server's MCP port, 9090.

To run your own copy:

1. Fork this repo. Set `repoURL` in `infra/argocd/root.yaml` and
   `infra/argocd/stacks.yaml`. In `infra/stack/values-dev.yaml` and
   `infra/stack/values-prod.yaml`, set `domain`. Each stack's LiteLLM
   starts with the aliases in `infra/stack/litellm/models/` and keeps them
   in its database; each key has a daily budget in the stack's values
   file.
   If your images are not `ghcr.io/shopnexus/*`, change the names in
   `infra/stack/values.yaml` and `infra/argocd/stacks.yaml`. The cluster
   pulls them without credentials, so the GHCR packages must be public.
2. Point DNS at the machine: `<domain>`, `*.<domain>`, `*.dev.<domain>` and
   `dev.<domain>`. The last one is needed because a `*` record does not
   cover `dev` once `*.dev` exists.
3. Create the cluster. When Traefik may take ports 80 and 443:
   `ACME_EMAIL=<you> k3d cluster create --config infra/cluster/k3d-direct.yaml`.
   When another proxy on the machine holds them and forwards to
   `127.0.0.1:18080`:
   `k3d cluster create --config infra/cluster/k3d-behind-proxy.yaml`. k3s
   installs Traefik's settings, Argo CD and the root Application from the
   config's `files`.
4. Run `go -C infra run ./cmd/seal dev` and `go -C infra run ./cmd/seal prod`,
   fill in the two values each `.env` asks for (the upstream model API key,
   and Firebase's service account for prod), run them again, then commit and
   push `infra/stack/secrets/`.
5. Argo CD brings up both stacks.
   `hurl --test --variable domain=<domain> infra/smoke.hurl` checks one.

`seal` keeps the generated keys in the git-ignored
`infra/stack/secrets/<stack>.env` and `<stack>.restate.pem`. Back up all four
files, and the controller's key with them: `kubectl -n kube-system get secret -l
sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`. Without the key, the
committed SealedSecrets cannot be opened on a new cluster.

`infra/check.sh` lints the chart, runs its helm-unittest suites in
`infra/stack/tests`, and checks the Argo CD Applications and the Traefik edge;
CI runs it on every change under `infra/`. The design is in
`docs/superpowers/specs/2026-11-04-infra-k3d-stacks-design.md`.

## License

MIT, in `LICENSE` here and in each component's repository.
