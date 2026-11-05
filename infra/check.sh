#!/usr/bin/env bash
# Checks infra/. The facts about the stack chart are unit tests in
# stack/tests (helm-unittest); this script lints the chart, validates its
# manifests, runs those tests, and checks the files outside the chart: the
# Argo CD Applications, the Traefik edge and the root compose file.
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
eq "$(q "$apps" 'select(.kind=="Application") | .metadata.name' | sort | tr '\n' ' ')" "cnpg image-updater restate-operator root sealed-secrets stack-dev stack-prod " "applications"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.helm.valueFiles[0]')" values-prod.yaml "prod values"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.destination.namespace')" shopnexus-prod "prod namespace"
eq "$(q "$apps" 'select(.kind=="Application") | (.spec.source.repoURL, .spec.sources[].repoURL)' | grep github.com | sort -u | wc -l | tr -d ' ')" 1 "one repo URL for the umbrella"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="root") | .spec.ignoreDifferences[0].jsonPointers[0]')" /spec/source/helm/parameters "root keeps Image Updater's parameters"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-prod") | .images[0].commonUpdateSettings.updateStrategy')" semver "prod by semver"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-dev") | .images[0].commonUpdateSettings.updateStrategy')" digest "dev by digest"
for s in dev prod; do eq "$(q "$apps" "select(.kind==\"ImageUpdater\") | .spec.applicationRefs[] | select(.namePattern==\"stack-$s\") | .images[].alias" | sort | tr '\n' ' ')" "console docs server website " "stack-$s images"; done
# First sync of an empty cluster: the ImageUpdater CRD arrives with a child
# Application, every Application retries, and Argo CD judges Application health
# so root's waves wait for the platform.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-options"]')" SkipDryRunOnMissingResource=true "ImageUpdater survives the dry-run"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "ImageUpdater waits for the platform only"
eq "$(q "$apps" 'select(.kind=="Application" and .spec.syncPolicy.retry.limit == -1) | .metadata.name' | sort | tr '\n' ' ')" "cnpg image-updater restate-operator root sealed-secrets stack-dev stack-prod " "every Application retries"
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
grep -qF -- 'redirections' <<<"$proxy" && { echo "FAIL: behind-proxy edge must not redirect" >&2; fails=$((fails + 1)); }
for e in direct behind-proxy; do eq "$(yq '.image' "cluster/k3d-$e.yaml")" rancher/k3s:v1.37.1-k3s1 "k3s version the edge check assumes"; done

# ── local compose ──
# The prod profile of the root docker-compose.yml runs the stack's data services.
for s in postgres restate rustfs; do
  eq "$(yq ".services.$s.image" ../docker-compose.yml)" "$(yq ".images.$s.repository + \":\" + .images.$s.tag" stack/values.yaml)" "compose $s image"
done

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
