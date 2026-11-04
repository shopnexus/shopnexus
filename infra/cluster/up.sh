#!/usr/bin/env bash
# up.sh direct|behind-proxy
#
# Creates the k3d cluster, configures Traefik for the edge mode, installs
# Argo CD and applies the root Application. Argo CD does the rest.
#   direct        Traefik takes host ports 80 and 443; needs ACME_EMAIL.
#                 ACME_SERVER defaults to Let's Encrypt staging.
#   behind-proxy  Traefik listens on 127.0.0.1:18080 for a proxy on the host.
set -euo pipefail
edge=${1:?usage: up.sh direct|behind-proxy}
cd "$(dirname "$0")"
ARGOCD_CHART=10.11.7

case $edge in
  direct)
    : "${ACME_EMAIL:?direct needs ACME_EMAIL}"
    ACME_SERVER=${ACME_SERVER:-https://acme-staging-v02.api.letsencrypt.org/directory}
    # Straight onto server-0, where Traefik runs: k3d's serverlb would hide
    # the client's address.
    ports=(--port 80:80@server:0:direct --port 443:443@server:0:direct) ;;
  behind-proxy)
    ports=(--port 127.0.0.1:18080:80@loadbalancer) ;;
  *) echo "edge must be direct or behind-proxy" >&2; exit 2 ;;
esac

k3d cluster create --config k3d.yaml "${ports[@]}"
sed -e "s|\${ACME_EMAIL}|${ACME_EMAIL:-}|" -e "s|\${ACME_SERVER}|${ACME_SERVER:-}|" "edge-$edge.yaml" | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART" \
  --namespace argocd --create-namespace --wait -f argocd-values.yaml
kubectl apply -f ../argocd/root.yaml

echo "Argo CD is syncing. Watch it with: kubectl -n argocd get applications -w"
echo "Then seal the secrets: infra/cluster/seal.sh dev && infra/cluster/seal.sh prod"
