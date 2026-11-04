#!/usr/bin/env bash
# Renders the stack chart for dev and prod, validates the manifests and
# checks the facts the spec fixes. Run from anywhere: infra/check.sh
set -euo pipefail
cd "$(dirname "$0")"

fails=0
render() { helm template shopnexus stack -f "stack/values-$1.yaml" --namespace "shopnexus-$1" "${@:2}"; }
q() { yq ea "$2" <<<"$1"; }
eq() { [[ "$1" == "$2" ]] || { echo "FAIL: $3: got '$1', want '$2'" >&2; fails=$((fails + 1)); }; }
ok() { (( $1 == 0 )) || { echo "FAIL: $2" >&2; fails=$((fails + 1)); }; }

for s in dev prod; do
  helm lint --quiet stack -f "stack/values-$s.yaml" >/dev/null
  render "$s" | kubeconform -strict -ignore-missing-schemas -summary \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -
done
dev=$(render dev)
prod=$(render prod)

# ── values ──
if helm template x stack >/dev/null 2>&1; then ok 1 "rendering without a stack values file fails"; fi
if helm template x stack -f stack/values-dev.yaml --set stack=qa >/dev/null 2>&1; then ok 1 "stack must be dev or prod"; fi

# ── web apps and ingress ──
hosts() { q "$1" 'select(.kind=="Ingress") | .spec.rules[].host' | sort | tr '\n' ' '; }
eq "$(hosts "$prod")" "api.shopnexus.id.vn docs.shopnexus.id.vn media.shopnexus.id.vn shopnexus.id.vn " "prod hosts"
eq "$(hosts "$dev")" "api.dev.shopnexus.id.vn dev.shopnexus.id.vn docs.dev.shopnexus.id.vn media.dev.shopnexus.id.vn " "dev hosts"
withops=$(render prod --set ops.enabled=true --set images.ops.repository=ghcr.io/shopnexus/ops --set images.ops.tag=0.1.0)
eq "$(q "$withops" 'select(.kind=="Ingress") | .spec.rules[] | select(.host=="ops.shopnexus.id.vn") | .http.paths[0].backend.service.name')" ops "ops host when enabled"
eq "$(q "$prod" 'select(.kind=="Ingress") | .spec.rules[] | select(.host=="api.shopnexus.id.vn") | .http.paths[0].backend.service.name')" server-api "api goes to server-api"
eq "$(q "$prod" 'select(.kind=="Deployment" and .metadata.name=="website") | .spec.replicas')" 2 "prod website replicas"
eq "$(q "$dev" 'select(.kind=="Deployment" and .metadata.name=="website") | .spec.replicas')" 1 "dev website replicas"
eq "$(q "$prod" 'select(.kind=="Deployment" and .metadata.name=="docs") | .spec.template.spec.containers[0].image')" ghcr.io/shopnexus/docs:0.1.0 "prod docs image"
eq "$(q "$prod" 'select(.kind=="Ingress") | .spec | has("tls")')" false "ingress leaves TLS to the edge"

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
