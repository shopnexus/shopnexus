# Monitoring (Prometheus + Grafana)

Wired into the cluster as a **separate Argo CD Application** (`deploy/argocd/
monitoring.yaml`) so it's optional and its health never gates the app rollout.
Runs in the `shopnexus` namespace alongside the apps, so scrape/datasource use
short DNS names.

## What's here

- `kustomization.yaml` — the stack; mounts the configs below as hashed ConfigMaps.
- `prometheus.yaml` — Deployment + Service (`prometheus:9090`) + 5Gi PVC.
- `grafana.yaml` — Deployment + Service (`grafana:3000`) + 2Gi PVC.
- `prometheus/prometheus.yml` — scrape config. Targets `server:5005/metrics`
  (the Go backend's Echo port) and Prometheus itself. Static targets, no k8s
  service-discovery ⇒ no RBAC needed.
- `grafana/provisioning/datasources/prometheus.yml` — auto-registers the
  Prometheus datasource (`http://prometheus:9090`) on startup.

## Deploy

Registered once via Argo CD (see the top-level `deploy/README.md` bootstrap):

```bash
kubectl apply -f deploy/argocd/monitoring.yaml
```

Argo then keeps `deploy/monitoring` in sync. Editing any config/manifest here and
pushing triggers a re-sync; the ConfigMap hash suffix rolls the pod on a config
change.

## Access

Ops tools — reach them by port-forward (like the Argo UI), no public ingress:

```bash
kubectl -n shopnexus port-forward svc/grafana 3000:3000     # http://localhost:3000
kubectl -n shopnexus port-forward svc/prometheus 9090:9090  # http://localhost:9090
```

**Grafana login:** `admin` / `admin` by default (Grafana's built-in). To set a
real password, add an optional key to the existing Secret and let the pod restart:

```bash
kubectl -n shopnexus patch secret shopnexus-secret --type merge \
  -p '{"stringData":{"GRAFANA_ADMIN_PASSWORD":"<pick-one>"}}'
```

(`GF_SECURITY_ADMIN_PASSWORD` reads this key with `optional: true`, so it's not
required for bootstrap.)

## Images

Pinned upstream tags (`prom/prometheus`, `grafana/grafana`) — no Image Updater.
Bump the tag in the manifest and push.

## Later

- Dashboards: mount JSON dashboards via a `grafana/provisioning/dashboards/`
  ConfigMap the same way the datasource is provisioned.
- If you outgrow static scraping (multiple replicas, pod churn), switch to the
  Prometheus Operator / kube-prometheus-stack — but that pulls in CRDs + an
  operator, heavier than this KISS setup needs today.
