# Monitoring (Prometheus + Grafana)

Moved here from the server repo. **Config only** — these were docker-compose
based and are not yet converted to k8s manifests.

- `prometheus/prometheus.yml` — scrape config (targets the Go server `/metrics`).
- `grafana/provisioning/` — Grafana datasource provisioning.

To wire into the cluster later: convert to a Deployment/Service (or use the
kube-prometheus-stack Helm chart), mount these as ConfigMaps, and add a second
Argo CD Application pointing at `deploy/monitoring`.
