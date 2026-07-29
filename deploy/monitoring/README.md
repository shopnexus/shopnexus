# Monitoring (Loki + Alloy + Grafana over TimescaleDB)

Wired into the cluster as a **separate Argo CD Application** (`deploy/argocd/
monitoring.yaml`) so it's optional and its health never gates the app rollout.
Runs in the `shopnexus` namespace alongside the apps, so datasources use short
DNS names.

**There is no Prometheus.** Metrics are not scraped — the backend's
`observability` module writes them straight into TimescaleDB hypertables on the
`observability` schema, and the gateway exposes no `/metrics` endpoint. Grafana
reads those tables over a Postgres datasource. Logs travel a separate path: the
app logs JSON to stdout, Alloy tails pods and ships to Loki, same Grafana.

## What's here

- `kustomization.yaml` — the stack; mounts the configs below as hashed ConfigMaps.
- `loki.yaml` — Deployment + Service (`loki:3100`) + 10Gi PVC. Single-binary Loki
  on the image's bundled config; `fsGroup: 10001` so the PVC is writable.
- `alloy.yaml` — DaemonSet + ServiceAccount + ClusterRole/Binding. The RBAC is
  required: `discovery.kubernetes` calls the API server and
  `loki.source.kubernetes` reads `pods/log`. Without it Alloy starts and silently
  ships nothing.
- `alloy/config.alloy` — Kubernetes log collection. **Not** interchangeable with
  `server/dev/alloy/config.alloy`, which discovers containers over `docker.sock`
  for the dev stack; that mechanism does not exist in a cluster.
- `grafana.yaml` — Deployment + Service (`grafana:3000`) + 2Gi PVC.
- `grafana/provisioning/datasources/timescaledb.yml` — the metrics datasource
  (`postgres:5432`). Its password comes from `shopnexus-secret` via the pod's
  `POSTGRES_PASSWORD` env, expanded by Grafana at provisioning time.
- `grafana/provisioning/datasources/loki.yml` — the logs datasource.
- `grafana/provisioning/dashboards/dashboards.yml` — the dashboard provider.

The datasource **uids** (`timescaledb`, `loki`) are load-bearing: the dashboard
JSON references them by uid, so renaming one silently breaks every panel.

## The dashboard comes from the server submodule

`grafana-dashboards` is generated from
`../../server/dev/grafana/dashboards/observability.json` — deliberately across the
submodule boundary, because the dashboard's queries and the hypertable schema they
read must change in one commit. A copy here would go stale.

Kustomize refuses to read outside its root by default. Build it by hand with:

```bash
kubectl kustomize --load-restrictor LoadRestrictionsNone deploy/monitoring
```

For Argo CD this is **not** an Application field — `buildOptions` does not exist on
`Application.spec.source.kustomize` (verified against the CRD). It is a global
setting in `argocd-cm`, applied out-of-band once, like the other bootstrap patches
in `deploy/argocd/ingress.yaml`:

```bash
kubectl -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--load-restrictor LoadRestrictionsNone"}}'
kubectl -n argocd rollout restart deploy/argocd-repo-server
```

This relaxes the restriction for **every** Application on the cluster, not just
this one — fine on a single-tenant cluster, but on a shared one prefer committing a
copy of the dashboard here plus CI that diffs it against the submodule.

It also relies on Argo CD initialising git submodules on checkout (its default; the
submodule URLs are HTTPS so no credentials are needed for these public repos).

## Deploy

Registered once via Argo CD (see the top-level `deploy/README.md` bootstrap):

```bash
kubectl apply -f deploy/argocd/monitoring.yaml
```

Argo then keeps `deploy/monitoring` in sync. Editing any config/manifest here and
pushing triggers a re-sync; the ConfigMap hash suffix rolls the pod on a config
change.

## Access

Grafana is on its own host via the ingress (`grafana.internal`, fronted by Caddy).
Loki has no ingress — it has no auth, so reach it by port-forward when needed:

```bash
kubectl -n shopnexus port-forward svc/grafana 3000:3000  # http://localhost:3000
kubectl -n shopnexus port-forward svc/loki 3100:3100     # http://localhost:3100
```

**Grafana login:** `admin` / `admin` by default (Grafana's built-in). To set a
real password, add an optional key to the existing Secret and let the pod restart:

```bash
kubectl -n shopnexus patch secret shopnexus-secret --type merge \
  -p '{"stringData":{"GRAFANA_ADMIN_PASSWORD":"<pick-one>"}}'
```

(`GF_SECURITY_ADMIN_PASSWORD` reads this key with `optional: true`, so it's not
required for bootstrap.)

## Querying

- **Metrics:** SQL against the `observability` schema. Read p95 from the
  `http_requests_1m` sketch with `approx_percentile(0.95, "latency")` — never by
  averaging stored p95s.
- **Logs:** LogQL, filtered by the labels Alloy attaches —
  `{service="gateway"} | json`. `service` comes from the workload's
  `app.kubernetes.io/name`, so it reads `gateway`, `website`, `docs`, `postgres`,
  `redis`, `nats`.

## Images

Pinned upstream tags (`grafana/grafana`, `grafana/loki`, `grafana/alloy`) — no
Image Updater. Bump the tag in the manifest and push. Grafana is held at the same
version as the dev stack (`server/docker-compose.yml`) so a dashboard that renders
locally renders here.
