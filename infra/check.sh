#!/usr/bin/env bash
# Checks infra/. The facts about the stack chart are unit tests in
# stack/tests (helm-unittest); this script lints the chart, validates its
# manifests, runs those tests, and checks the files outside the chart: the
# Argo CD Applications, the ai chart with each stack's values, the Traefik
# edge and the root compose file. The ai chart is read from AI_CHART, the
# ai submodule's chart/ by default.
# Run from anywhere: infra/check.sh
set -euo pipefail
cd "$(dirname "$0")"

fails=0
q() { yq ea -N "$2" <<<"$1"; }
eq() { [[ "$1" == "$2" ]] || { echo "FAIL: $3: got '$1', want '$2'" >&2; fails=$((fails + 1)); }; }
ok() { (( $1 == 0 )) || { echo "FAIL: $2" >&2; fails=$((fails + 1)); }; }

# ── chart ──
# The chart refuses to render without sealed secrets; the probes in
# stack/tests/secrets stand in for them.
for s in dev prod; do
  helm lint --quiet stack -f "stack/values-$s.yaml" --set secretsDir=tests/secrets >/dev/null
  helm template shopnexus stack -f "stack/values-$s.yaml" --set secretsDir=tests/secrets --namespace "shopnexus-$s" \
    | kubeconform -strict -ignore-missing-schemas -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -
done
helm unittest stack || fails=$((fails + 1))

# ── argo ──
apps=$(for f in argocd/*.yaml platform/*.yaml; do cat "$f"; echo ---; done 2>/dev/null || true)
eq "$(q "$apps" 'select(.kind=="Application") | .metadata.name' | sort | tr '\n' ' ')" "blackbox-exporter cnpg image-updater prometheus restate-operator root sealed-secrets stack-dev stack-prod " "applications"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.helm.valueFiles[0]')" values-prod.yaml "prod values"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.destination.namespace')" shopnexus-prod "prod namespace"
eq "$(q "$apps" 'select(.kind=="Application") | (.spec.source.repoURL, .spec.sources[].repoURL)' | grep github.com | sort -u | tr '\n' ' ')" "https://github.com/shopnexus/shopnexus.git " "the umbrella's URL"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="root") | .spec.ignoreDifferences[0].jsonPointers[0]')" /spec/source/helm/parameters "root keeps Image Updater's parameters"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-dev") | .images[0].commonUpdateSettings.updateStrategy')" digest "dev by digest"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-dev") | .images[].alias' | sort | tr '\n' ' ')" "agent console docs server website " "stack-dev images"
# Prod runs one release of the umbrella (.github/workflows/release.yml):
# Image Updater leaves it alone, stack-prod runs the tag vX.Y.Z, every prod
# image is X.Y.Z.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[].namePattern' | sort | tr '\n' ' ')" "stack-dev " "Image Updater moves dev only"
release=$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.targetRevision')
[[ $release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: stack-prod's targetRevision $release is not vX.Y.Z" >&2; fails=$((fails + 1)); }
eq "$(yq '.images | to_entries | .[] | select(.key | test("^(server|website|docs|console|agent)$")) | .value.tag' stack/values-prod.yaml | sort -u)" "${release#v}" "every prod image is the release's"
eq "$(yq '.images | keys | .[]' stack/values-prod.yaml | sort | tr '\n' ' ')" "agent console docs server website " "values-prod names the five images"
# First sync of an empty cluster: the ImageUpdater CRD arrives with a child
# Application, every Application retries, and Argo CD judges Application health
# so root's waves wait for the platform.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-options"]')" SkipDryRunOnMissingResource=true "ImageUpdater survives the dry-run"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "ImageUpdater waits for the platform only"
eq "$(q "$apps" 'select(.kind=="Application" and .spec.syncPolicy.retry.limit == -1) | .metadata.name' | sort | tr '\n' ' ')" "blackbox-exporter cnpg image-updater prometheus restate-operator root sealed-secrets stack-dev stack-prod " "every Application retries"
ok $(grep -q 'obj.status.health' <<<"$(yq '.spec.valuesContent' cluster/argocd.yaml | yq '.configs.cm["resource.customizations.health.argoproj.io_Application"]')"; echo $?) "Argo CD judges Application health"

# ── edge ──
# k3s v1.37.1 (cluster/k3d-*.yaml) bundles Traefik chart 41.4.0, whose schema
# refuses unknown keys; k3s then runs Traefik with its defaults.
edge() { yq '.files[] | select(.description=="Traefik") | .source' "cluster/k3d-$1.yaml" | yq '.spec.valuesContent' \
  | sed -e 's|${ACME_EMAIL}|a@b.c|' \
  | helm template t traefik --repo https://traefik.github.io/charts --version 41.4.0 -f - 2>&1; }
direct=$(edge direct); proxy=$(edge behind-proxy)
eq "$(yq ea -N 'select(.kind=="Service") | .spec.externalTrafficPolicy' <<<"$direct")" Local "direct edge keeps the client address"
for f in -- '--entryPoints.websecure.http.tls.certResolver=le' '--entryPoints.web.http.redirections.entryPoint.to=:443' '--certificatesresolvers.le.acme.tlsChallenge=true' '--accesslog=true'; do
  [[ $f == -- ]] && continue; grep -qF -- "$f" <<<"$direct" || { echo "FAIL: direct edge lacks $f" >&2; fails=$((fails + 1)); }
done
grep -qF -- '--entryPoints.web.forwardedHeaders.trustedIPs=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16' <<<"$proxy" || { echo "FAIL: behind-proxy edge lacks trusted IPs" >&2; fails=$((fails + 1)); }
grep -qF -- '--accesslog=true' <<<"$proxy" || { echo "FAIL: behind-proxy edge lacks the access log" >&2; fails=$((fails + 1)); }
grep -qF -- 'redirections' <<<"$proxy" &&{ echo "FAIL: behind-proxy edge must not redirect" >&2; fails=$((fails + 1)); }
for e in direct behind-proxy; do eq "$(yq '.image' "cluster/k3d-$e.yaml")" rancher/k3s:v1.37.1-k3s1 "k3s version the edge check assumes"; done
# The dashboards' IngressRoute reaches Restate and Argo CD in other namespaces.
for e in "$direct" "$proxy"; do grep -qF -- '--providers.kubernetescrd.allowCrossNamespace=true' <<<"$e" || { echo "FAIL: an edge lacks allowCrossNamespace" >&2; fails=$((fails + 1)); }; done
# Argo CD sits behind the console's sign-in, which lets admins only, and asks for none itself.
argo=$(yq '.spec.valuesContent' cluster/argocd.yaml)
eq "$(yq '.configs.cm["users.anonymous.enabled"]' <<<"$argo")" true "Argo CD takes the gate's admins without a sign-in"
eq "$(yq '.configs.rbac["policy.default"]' <<<"$argo")" role:admin "Argo CD's anonymous user is an admin"

# ── local compose ──
# Every stack of the root docker-compose.yml runs the stack's data services
# from the x-postgres, x-restate, x-rustfs, x-litellm and x-imgproxy blocks,
# and imgproxy's cache from x-imgproxy-cache.
for s in postgres restate rustfs litellm imgproxy; do
  eq "$(yq ".x-$s.image" ../docker-compose.yml)" "$(yq ".images.$s.repository + \":\" + .images.$s.tag" stack/values.yaml)" "compose $s image"
done
eq "$(yq '.x-imgproxy-cache.image' ../docker-compose.yml)" "$(yq '.images.nginx.repository + ":" + .images.nginx.tag' stack/values.yaml)" "compose imgproxy-cache image"
eq "$(yq '.x-server-env.CARRIER' ../docker-compose.yml)" "$(yq '.server.carrier' stack/values-dev.yaml)" "compose CARRIER"
# The settings every stack shares are in stack/env/*.env, which compose
# (env_file) and the chart both read; a key
# there is written nowhere else.
# The chart fails its render on a key in both; compose would let its own
# block win, so this catches it.
for f in stack/env/server.env:x-server-env stack/env/agent.env:x-agent-env stack/env/litellm.env:x-litellm stack/env/lgtm.env:x-lgtm stack/env/imgproxy.env:x-imgproxy-env; do
  for k in $(grep -oE '^[A-Z0-9_]+' "${f%%:*}"); do
    # yq warns about compose's merge anchors on stderr; the keys read are literal.
    for block in $(yq 'keys | .[] | select(test("^'"${f#*:}"'"))' ../docker-compose.yml 2>/dev/null); do
      [[ $(yq ".\"$block\" | (.environment // .) | has(\"$k\")" ../docker-compose.yml 2>/dev/null) == false ]] ||
        { echo "FAIL: $k is in ${f%%:*} and in compose's $block" >&2; fails=$((fails + 1)); }
    done
  done
done

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
