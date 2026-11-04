#!/usr/bin/env bash
# Renders the stack chart for dev and prod, validates the manifests and
# checks the facts the spec fixes. Run from anywhere: infra/check.sh
set -euo pipefail
cd "$(dirname "$0")"

fails=0
# The chart refuses to render without sealed secrets or a language model, so
# the checks render a copy that carries probe SealedSecrets and set the model.
probe() { printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata: {name: probe, namespace: shopnexus-%s}\nspec: {encryptedData: {k: %s}}\n' "$1" "$2"; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r stack "$work/"; chart=$work/stack
for s in dev prod; do mkdir -p "$chart/secrets/$s"; probe "$s" one > "$chart/secrets/$s/probe.yaml"; done
render() { helm template shopnexus "$chart" -f "stack/values-$1.yaml" --namespace "shopnexus-$1" --set server.llmModel=probe-model "${@:2}"; }
q() { yq ea -N "$2" <<<"$1"; }
eq() { [[ "$1" == "$2" ]] || { echo "FAIL: $3: got '$1', want '$2'" >&2; fails=$((fails + 1)); }; }
ok() { (( $1 == 0 )) || { echo "FAIL: $2" >&2; fails=$((fails + 1)); }; }

for s in dev prod; do
  helm lint --quiet "$chart" -f "stack/values-$s.yaml" --set server.llmModel=probe-model >/dev/null
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
eq "$(hosts "$prod")" "api.shopnexus.id.vn console.shopnexus.id.vn docs.shopnexus.id.vn media.shopnexus.id.vn shopnexus.id.vn " "prod hosts"
eq "$(hosts "$dev")" "api.dev.shopnexus.id.vn console.dev.shopnexus.id.vn dev.shopnexus.id.vn docs.dev.shopnexus.id.vn media.dev.shopnexus.id.vn " "dev hosts"
eq "$(q "$prod" 'select(.kind=="Deployment" and .metadata.name=="console") | .spec.template.spec.containers[0].image')" ghcr.io/shopnexus/console:0.1.0 "prod console image"
eq "$(q "$dev" 'select(.kind=="Deployment" and .metadata.name=="console") | .spec.template.spec.containers[0].image')" ghcr.io/shopnexus/console:main "dev console image"
withconsole=$(render prod --set console.enabled=true --set images.console.repository=ghcr.io/shopnexus/console --set images.console.tag=0.1.0)
eq "$(q "$withconsole" 'select(.kind=="Ingress") | .spec.rules[] | select(.host=="console.shopnexus.id.vn") | .http.paths[0].backend.service.name')" console "console host when enabled"
eq "$(q "$prod" 'select(.kind=="Ingress") | .spec.rules[] | select(.host=="api.shopnexus.id.vn") | .http.paths[0].backend.service.name')" server-api "api goes to server-api"
eq "$(q "$prod" 'select(.kind=="Deployment" and .metadata.name=="website") | .spec.replicas')" 2 "prod website replicas"
eq "$(q "$dev" 'select(.kind=="Deployment" and .metadata.name=="website") | .spec.replicas')" 1 "dev website replicas"
eq "$(q "$prod" 'select(.kind=="Deployment" and .metadata.name=="docs") | .spec.template.spec.containers[0].image')" ghcr.io/shopnexus/docs:0.1.0 "prod docs image"
eq "$(q "$prod" 'select(.kind=="Ingress") | .spec | has("tls")')" false "ingress leaves TLS to the edge"

# ── data and jobs ──
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.instances')" 2 "prod postgres instances"
eq "$(q "$dev" 'select(.kind=="Cluster") | .spec.instances')" 1 "dev postgres instances"
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.postgresql.shared_preload_libraries[0]')" pg_search "pg_search preloaded"
# CNPG reads the major version from a tag like 18.1; ParadeDB's 0.26.4-pg18 needs a catalog entry.
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.imageCatalogRef.major')" 18 "postgres major from the catalog"
eq "$(q "$prod" 'select(.kind=="ImageCatalog") | .spec.images[0].image')" paradedb/paradedb:0.26.4-pg18 "catalog image"
eq "$(q "$prod" 'select(.kind=="Cluster") | .spec.postgresUID')" 999 "postgres runs as the image's postgres user"
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
# restate-operator admits ingress and admin traffic only from networkPeers, and
# lets Restate pods reach in-cluster pods labelled allow.restate.dev/<cluster>.
eq "$(q "$prod" "$rc | .spec.security.networkPeers.ingress[0].podSelector.matchLabels[\"app.kubernetes.io/name\"]")" server "server reaches restate ingress"
eq "$(q "$prod" "$rc | .spec.security.networkPeers.admin[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]")" shopnexus-prod "server reaches restate admin"
eq "$(q "$prod" 'select(.kind=="StatefulSet" and .metadata.name=="rustfs") | .spec.template.metadata.labels["allow.restate.dev/restate-prod"]')" true "restate reaches rustfs"
eq "$(q "$prod" "$rc | .spec.compute.topologySpreadConstraints[0].labelSelector.matchLabels[\"app.kubernetes.io/instance\"]")" restate-prod "restate pods spread over nodes"
rd='select(.kind=="RestateDeployment")'
eq "$(q "$prod" "$rd | .spec.template.metadata.labels[\"allow.restate.dev/restate-prod\"]")" true "restate reaches the server"
eq "$(q "$prod" "$rd | .spec.replicas")" 3 "prod server replicas"
eq "$(q "$prod" "$rd | .spec.restate.register.cluster")" restate-prod "server registers with prod restate"
eq "$(q "$prod" "$rd | .spec.restate.useHttp11")" true "HTTP/1.1 to the endpoint"
eq "$(q "$prod" 'select(.kind=="Service" and .metadata.name=="server-api") | .spec.selector["app.kubernetes.io/name"]')" server "server-api selects every server pod"
cm='select(.kind=="ConfigMap" and .metadata.name=="server-env") | .data'
eq "$(q "$prod" "$cm | .RESTATE_REGISTER")" false "the operator registers"
eq "$(q "$prod" "$cm | .APP_ENV")" prod "prod APP_ENV"
eq "$(q "$prod" "$cm | .PNV_TEST_NUMBERS")" false "prod refuses test numbers"
eq "$(q "$prod" "$cm | .STAFF_CONSOLE_ORIGIN")" https://console.shopnexus.id.vn "console origin"
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
eq "$(q "$dev" 'select(.kind=="SealedSecret") | .metadata.name')" probe "chart includes secrets/<stack>/*.yaml"
err=$(helm template x stack -f stack/values-dev.yaml --set server.llmModel=m 2>&1 >/dev/null || true)
ok $(grep -q 'seal.sh dev' <<<"$err"; echo $?) "rendering without sealed secrets fails and names seal.sh"
err=$(helm template x "$chart" -f stack/values-dev.yaml 2>&1 >/dev/null || true)
ok $(grep -q 'server.llmModel' <<<"$err"; echo $?) "rendering without a language model fails and names server.llmModel"
# A reseal must reach the pods: the secrets' checksum is on the pod templates.
probe prod two > "$chart/secrets/prod/probe.yaml"; resealed=$(render prod); probe prod one > "$chart/secrets/prod/probe.yaml"
for w in 'select(.kind=="RestateDeployment")' 'select(.kind=="StatefulSet" and .metadata.name=="rustfs")'; do
  a=$(q "$prod" "$w | .spec.template.metadata.annotations[\"checksum/secrets\"]"); b=$(q "$resealed" "$w | .spec.template.metadata.annotations[\"checksum/secrets\"]")
  ok $([[ $a != null && -n $a && $a != "$b" ]]; echo $?) "a reseal rolls $w"
done

# ── argo ──
apps=$(for f in argocd/*.yaml platform/*.yaml; do cat "$f"; echo ---; done 2>/dev/null || true)
eq "$(q "$apps" 'select(.kind=="Application") | .metadata.name' | sort | tr '\n' ' ')" "cnpg image-updater restate-operator root sealed-secrets stack-dev stack-prod " "applications"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.helm.valueFiles[0]')" values-prod.yaml "prod values"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.destination.namespace')" shopnexus-prod "prod namespace"
eq "$(q "$apps" 'select(.kind=="Application") | (.spec.source.repoURL, .spec.sources[].repoURL)' | grep github.com | sort -u | wc -l | tr -d ' ')" 1 "one repo URL for the umbrella"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="root") | .spec.ignoreDifferences[0].jsonPointers[0]')" /spec/source/helm/parameters "root keeps Image Updater's parameters"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-prod") | .images[0].commonUpdateSettings.updateStrategy')" semver "prod by semver"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-dev") | .images[0].commonUpdateSettings.updateStrategy')" digest "dev by digest"
for s in dev prod; do eq "$(q "$apps" "select(.kind==\"ImageUpdater\") | .spec.applicationRefs[] | select(.namePattern==\"stack-$s\") | .images[].alias" | sort | tr '\n' ' ')" "console docs server website " "stack-$s images"; done
ok $(! grep -rq 'from Step 1\|from Task 12' platform cluster 2>/dev/null; echo $?) "chart versions pinned"
# First sync of an empty cluster: the ImageUpdater CRD arrives with a child
# Application, every Application retries, and Argo CD judges Application health
# so root's waves wait for the platform.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-options"]')" SkipDryRunOnMissingResource=true "ImageUpdater survives the dry-run"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "ImageUpdater waits for the platform only"
eq "$(q "$apps" 'select(.kind=="Application" and .spec.syncPolicy.retry.limit == -1) | .metadata.name' | sort | tr '\n' ' ')" "cnpg image-updater restate-operator root sealed-secrets stack-dev stack-prod " "every Application retries"
ok $(grep -q 'obj.status.health' <<<"$(yq '.configs.cm["resource.customizations.health.argoproj.io_Application"]' cluster/argocd-values.yaml 2>/dev/null)"; echo $?) "Argo CD judges Application health"
ok $(grep -q -- '-f argocd-values.yaml' cluster/up.sh; echo $?) "up.sh installs Argo CD with those values"

# ── edge ──
# k3s v1.37.1 (cluster/k3d.yaml) bundles Traefik chart 41.4.0, whose schema
# refuses unknown keys; k3s then runs Traefik with its defaults.
edge() { yq '.spec.valuesContent' "cluster/edge-$1.yaml" | sed -e 's|${ACME_EMAIL}|a@b.c|' -e 's|${ACME_SERVER}|https://x|' \
  | helm template t traefik --repo https://traefik.github.io/charts --version 41.4.0 -f - 2>&1; }
direct=$(edge direct); proxy=$(edge behind-proxy)
eq "$(yq ea -N 'select(.kind=="Service") | .spec.externalTrafficPolicy' <<<"$direct")" Local "direct edge keeps the client address"
for f in -- '--entryPoints.websecure.http.tls.certResolver=le' '--entryPoints.web.http.redirections.entryPoint.to=:443' '--certificatesresolvers.le.acme.tlsChallenge=true' '--accesslog=true'; do
  [[ $f == -- ]] && continue; grep -qF -- "$f" <<<"$direct" || { echo "FAIL: direct edge lacks $f" >&2; fails=$((fails + 1)); }
done
grep -qF -- '--entryPoints.web.forwardedHeaders.trustedIPs=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16' <<<"$proxy" || { echo "FAIL: behind-proxy edge lacks trusted IPs" >&2; fails=$((fails + 1)); }
grep -qF -- 'redirections' <<<"$proxy" && { echo "FAIL: behind-proxy edge must not redirect" >&2; fails=$((fails + 1)); }
eq "$(yq '.image' cluster/k3d.yaml)" rancher/k3s:v1.37.1-k3s1 "k3s version the edge check assumes"

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
