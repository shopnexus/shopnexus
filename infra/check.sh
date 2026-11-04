#!/usr/bin/env bash
# Renders the stack chart for dev and prod, validates the manifests and
# checks the facts the spec fixes. Run from anywhere: infra/check.sh
set -euo pipefail
cd "$(dirname "$0")"

fails=0
render() { helm template shopnexus stack -f "stack/values-$1.yaml" --namespace "shopnexus-$1" "${@:2}"; }
q() { yq ea -N "$2" <<<"$1"; }
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

# ── data and jobs ──
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.instances')" 2 "prod postgres instances"
eq "$(q "$dev" 'select(.kind=="Cluster") | .spec.instances')" 1 "dev postgres instances"
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.postgresql.shared_preload_libraries[0]')" pg_search "pg_search preloaded"
eq "$(q "$prod" 'select(.kind=="Cluster") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 0 "postgres in wave 0"
eq "$(q "$prod" 'select(.kind=="StatefulSet" and .metadata.name=="rustfs") | .spec.replicas')" 1 "one rustfs"
eq "$(q "$prod" 'select(.kind=="Job") | .metadata.name' | sort | tr '\n' ' ')" "migrate objectstore-init objectstore-init-snapshots " "jobs"
eq "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="migrate") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "migrate in wave 1"
eq "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="migrate") | .spec.template.spec.containers[0].command[0]')" /migrate "migrate runs /migrate"
eq "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="objectstore-init-snapshots") | .spec.template.spec.containers[0].env[] | select(.name=="OBJECT_STORE_BUCKET") | .value')" restate-snapshots "snapshot bucket"

# ── restate and server ──
rc='select(.kind=="RestateCluster")'
eq "$(q "$prod" "$rc | .metadata.name")" restate-prod "prod restate name"
eq "$(q "$prod" "$rc | .spec.compute.replicas")" 3 "prod restate nodes"
eq "$(q "$dev" "$rc | .spec.compute.replicas")" 1 "dev restate nodes"
ok $(grep -q 'default-replication = 2' <<<"$(q "$prod" "$rc | .spec.config")"; echo $?) "prod replicates the log twice"
ok $(grep -q 'default-replication = 1' <<<"$(q "$dev" "$rc | .spec.config")"; echo $?) "dev keeps one copy"
ok $(grep -q 'destination = "s3://restate-snapshots/prod"' <<<"$(q "$prod" "$rc | .spec.config")"; echo $?) "snapshots in rustfs"
eq "$(q "$prod" "$rc | .spec.security.requestSigningPrivateKey.secret.secretName")" restate-secrets "signing key"
rd='select(.kind=="RestateDeployment")'
eq "$(q "$prod" "$rd | .spec.replicas")" 3 "prod server replicas"
eq "$(q "$prod" "$rd | .spec.restate.register.cluster")" restate-prod "server registers with prod restate"
eq "$(q "$prod" "$rd | .spec.restate.useHttp11")" true "HTTP/1.1 to the endpoint"
eq "$(q "$prod" 'select(.kind=="Service" and .metadata.name=="server-api") | .spec.selector["app.kubernetes.io/name"]')" server "server-api selects every server pod"
cm='select(.kind=="ConfigMap" and .metadata.name=="server-env") | .data'
eq "$(q "$prod" "$cm | .RESTATE_REGISTER")" false "the operator registers"
eq "$(q "$prod" "$cm | .APP_ENV")" prod "prod APP_ENV"
eq "$(q "$prod" "$cm | .PNV_TEST_NUMBERS")" false "prod refuses test numbers"
eq "$(q "$prod" "$cm | .STAFF_CONSOLE_ORIGIN")" https://ops.shopnexus.id.vn "console origin"
eq "$(q "$dev" "$cm | .MEDIA_PUBLIC_URL")" https://media.dev.shopnexus.id.vn/shopnexus "dev media URL"
eq "$(q "$dev" "$cm | .RESTATE_INGRESS_URL")" http://restate.restate-dev:8080 "dev restate ingress"
# Review Focus 1: a config change makes a new server version.
sum() { q "$1" "$rd | .spec.template.metadata.annotations[\"checksum/env\"]"; }
ok $([[ -n "$(sum "$prod")" && "$(sum "$prod")" != "$(sum "$(render prod --set server.logLevel=debug)")" ]]; echo $?) "config change rolls the server"
# Review Focus 2: every variable config.Load reads is set by the ConfigMap, the Secret or DATABASE_URL.
secret_keys="JWT_KEY_ID JWT_PRIVATE_KEY STAFF_KEY RESTATE_IDENTITY_KEY OBJECT_STORE_ACCESS_KEY OBJECT_STORE_SECRET_KEY LLM_API_KEY FCM_CREDENTIALS"
cm_keys=$(q "$prod" "$cm | keys | .[]")
for v in APP_ENV HTTP_ADDR LOG_LEVEL LOG_FORMAT RESTATE_INGRESS_URL RESTATE_ADMIN_URL RESTATE_LISTEN_ADDR \
  RESTATE_ENDPOINT_URL RESTATE_SERVICE_PREFIX RESTATE_IDENTITY_KEY RESTATE_REGISTER JWT_KEY_ID JWT_PRIVATE_KEY \
  JWT_PREVIOUS_KEY_ID JWT_PREVIOUS_PUBLIC_KEY JWT_ISSUER JWT_AUDIENCE STAFF_KEY STAFF_CONSOLE_ORIGIN \
  OBJECT_STORE_ENDPOINT OBJECT_STORE_PUBLIC_ENDPOINT OBJECT_STORE_REGION OBJECT_STORE_ACCESS_KEY \
  OBJECT_STORE_SECRET_KEY OBJECT_STORE_BUCKET MEDIA_PUBLIC_URL FCM_CREDENTIALS FIREBASE_PROJECT_ID \
  FIREBASE_PROJECT_NUMBER FIREBASE_AUTH_JWKS_URL PNV_JWKS_URL PNV_TEST_NUMBERS LLM_BASE_URL LLM_API_KEY \
  LLM_MODEL OTEL_EXPORTER_OTLP_ENDPOINT SERVICE_NAME TRUSTED_PROXIES; do
  grep -qx "$v" <<<"$cm_keys" || grep -qw "$v" <<<"$secret_keys" || { echo "FAIL: $v is set nowhere" >&2; fails=$((fails + 1)); }
done

# ── network policies ──
np() { q "$1" 'select(.kind=="NetworkPolicy") | .metadata.name' | sort | tr '\n' ' '; }
eq "$(np "$prod")" "default-deny-ingress from-cnpg from-restate from-stack from-traefik " "policies"
eq "$(q "$prod" 'select(.kind=="NetworkPolicy" and .metadata.name=="from-restate") | .spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]')" restate-prod "restate namespace"
eq "$(q "$prod" 'select(.kind=="NetworkPolicy" and .metadata.name=="from-stack") | .spec.ingress[0].from[0] | has("namespaceSelector")')" false "from-stack is this namespace only"

# ── secrets ──
for k in $secret_keys; do grep -qw "$k" cluster/seal.sh 2>/dev/null || { echo "FAIL: seal.sh does not write $k" >&2; fails=$((fails + 1)); }; done
tmpd=$(mktemp -d); cp -r stack "$tmpd/"; mkdir -p "$tmpd/stack/secrets/dev"
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata: {name: probe, namespace: shopnexus-dev}\nspec: {encryptedData: {}}\n' > "$tmpd/stack/secrets/dev/probe.yaml"
eq "$(helm template x "$tmpd/stack" -f stack/values-dev.yaml | yq ea -N 'select(.kind=="SealedSecret") | .metadata.name')" probe "chart includes secrets/<stack>/*.yaml"
rm -rf "$tmpd"

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
