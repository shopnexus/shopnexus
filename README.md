# ShopNexus

Umbrella repository for ShopNexus. Each component lives in its own git submodule.

## Components

| Path      | Repository              | Description            |
| --------- | ----------------------- | ---------------------- |
| `app`     | `shopnexus/app-android` | Android app (Kotlin)   |
| `console` | `shopnexus/console`     | Staff console (React)  |
| `docs`    | `shopnexus/docs`        | Documentation          |
| `server`  | `shopnexus/server`      | Backend (Go)           |
| `website` | `shopnexus/website`     | Storefront (Astro)     |

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

The root `docker-compose.yml` runs the system on one machine, in two profiles:

```bash
docker compose --profile dev up --build --watch   # live reload
docker compose --profile prod up -d --build       # built images
```

The `dev` profile runs the dev servers of the three web apps. Each image
holds the app's dependencies. `--watch` copies a saved file into its
container, where the dev server reloads the page in about two seconds, and
rebuilds the image when `package.json` or `bun.lock` changes. The command
stays in the foreground and prints the logs. `docker compose --profile dev
down` stops the apps.

| App | URL |
|---|---|
| docs | http://localhost:56421 |
| website | http://localhost:4321 |
| console | http://localhost:5173 |

The server is not in `dev`. Run it with `cd server && make run`, which starts
Postgres, Restate and RustFS in Docker and the server on the host. The console
calls it from the browser at `localhost:8080`. The website renders pages in its
container, which shares the host's network to call `localhost:8080`; Docker
Desktop needs host networking turned on in its settings for that.
Docs show the internal pages; `DOCS_INTERNAL=false` before the command hides
them. Search is empty in dev, because only `bun run build` makes the Pagefind
index.

The `prod` profile builds every component from its Dockerfile and runs it with
its own Postgres, Restate and RustFS, which the cluster runs too. A Caddy on
port 56480 routes by host, as the cluster's ingress does:

| App | URL |
|---|---|
| website | http://localhost:56480 |
| api | http://api.localhost:56480 |
| media | http://media.localhost:56480 |
| docs | http://docs.localhost:56480 |
| console | http://console.localhost:56480 |

Before the first start, copy `.env.example` to `.env` and set `LLM_API_KEY`.
The first start writes the server's keys into a volume, and `docker compose
--profile prod down -v` deletes them with the data. The server runs with
`APP_ENV=dev`, so PNV's test numbers sign in. `dev`, `prod` and `make run` use
different ports and can run at the same time.

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
`docs.` and `console.` (the staff console) below it. Argo CD syncs the Helm chart in `infra/stack` once per
stack, and Argo CD Image Updater moves the image tags. Postgres runs on
CloudNativePG, Restate on restate-operator; prod runs two Postgres instances
and three Restate nodes.

To run your own copy:

1. Fork this repo. Set `repoURL` in `infra/argocd/root.yaml` and
   `infra/argocd/stacks.yaml`. In `infra/stack/values-dev.yaml` and
   `infra/stack/values-prod.yaml`, set `domain`. Each stack's LiteLLM sends
   search to `litellm.model` at `litellm.apiBase` (in `values.yaml`), with a
   daily token budget per stack.
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
