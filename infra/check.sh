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
# The agent is off in prod; validate it on there too.
helm template shopnexus stack -f stack/values-prod.yaml --set secretsDir=tests/secrets --set agent.enabled=true --namespace shopnexus-prod \
  | kubeconform -strict -ignore-missing-schemas -summary -schema-location default -
helm unittest stack || fails=$((fails + 1))
# With source_of_truth config.json a governance section in the file wipes
# what the server made through Bifrost's API; only auth_config may be there.
eq "$(yq -o=json -I=0 '.governance | keys' stack/bifrost/config.json)" '["auth_config"]' "bifrost/config.json governance"

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
# image is pinned by digest with the commit it was built from (X.Y.Z only
# before the first release).
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[].namePattern' | sort | tr '\n' ' ')" "stack-dev " "Image Updater moves dev only"
release=$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.targetRevision')
[[ $release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: stack-prod's targetRevision $release is not vX.Y.Z" >&2; fails=$((fails + 1)); }
for i in server website docs console agent; do
  pin=$(yq ".images.$i.tag + \" \" + (.images.$i.commit // \"\")" stack/values-prod.yaml)
  [[ $pin =~ ^sha256:[0-9a-f]{64}\ [0-9a-f]{40}$ || $pin == "${release#v} " ]] ||
    { echo "FAIL: values-prod $i is '$pin', not a digest and its commit" >&2; fails=$((fails + 1)); }
done
eq "$(yq '.images | keys | .[]' stack/values-prod.yaml | sort | tr '\n' ' ')" "agent console docs server website " "values-prod names the five images"
# First sync of an empty cluster: the ImageUpdater CRD arrives with a child
# Application, every Application retries, and Argo CD judges Application health
# so root's waves wait for the platform. A retry takes the newest commit: one
# pinned to the commit that failed would retry it forever, and no fix pushed
# after it would land.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-options"]')" SkipDryRunOnMissingResource=true "ImageUpdater survives the dry-run"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "ImageUpdater waits for the platform only"
eq "$(q "$apps" 'select(.kind=="Application" and .spec.syncPolicy.retry.limit == -1 and .spec.syncPolicy.retry.refresh == true) | .metadata.name' | sort | tr '\n' ' ')" "blackbox-exporter cnpg image-updater prometheus restate-operator root sealed-secrets stack-dev stack-prod " "every Application retries on the newest commit"
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
# An OOM kills one process, not the agent's whole pod.
for e in direct behind-proxy; do eq "$(yq '.files[] | select(.description=="kubelet OOM") | .source' "cluster/k3d-$e.yaml" | yq .singleProcessOOMKill)" true "k3d-$e kubelet singleProcessOOMKill"; done
# The dashboards' IngressRoute reaches Restate and Argo CD in other namespaces.
for e in "$direct" "$proxy"; do grep -qF -- '--providers.kubernetescrd.allowCrossNamespace=true' <<<"$e" || { echo "FAIL: an edge lacks allowCrossNamespace" >&2; fails=$((fails + 1)); }; done
# Argo CD sits behind the console's sign-in, which lets admins only, and asks for none itself.
argo=$(yq '.spec.valuesContent' cluster/argocd.yaml)
eq "$(yq '.configs.cm["users.anonymous.enabled"]' <<<"$argo")" true "Argo CD takes the gate's admins without a sign-in"
eq "$(yq '.configs.rbac["policy.default"]' <<<"$argo")" role:admin "Argo CD's anonymous user is an admin"

# ── local compose ──
# Every stack of the root docker-compose.yml runs the stack's data services
# from the x-postgres, x-restate, x-garage, x-bifrost and x-imgproxy blocks,
# and imgproxy's cache from x-imgproxy-cache.
for s in postgres restate garage bifrost imgproxy; do
  eq "$(yq ".x-$s.image" ../docker-compose.yml)" "$(yq ".images.$s.repository + \":\" + .images.$s.tag" stack/values.yaml)" "compose $s image"
done
eq "$(yq '.x-garage-webui.image' ../docker-compose.yml)" "$(yq '.images.garageWebui.repository + ":" + .images.garageWebui.tag' stack/values.yaml)" "compose garage-webui image"
# The media host's nginx names the media bucket the server writes to.
bucket=$(sed -n 's/^OBJECT_STORE_BUCKET=//p' stack/env/server.env)
for l in "location /$bucket/media/ {" "proxy_set_header Host $bucket;" "location /$bucket/ {"; do
  grep -qF -- "$l" stack/imgproxy/nginx.conf || { echo "FAIL: imgproxy/nginx.conf lacks '$l' (OBJECT_STORE_BUCKET=$bucket)" >&2; fails=$((fails + 1)); }
done
grep -qF -- "IMGPROXY_ALLOWED_SOURCES=http://imgproxy-cache/$bucket/media/" stack/env/imgproxy.env || { echo "FAIL: imgproxy reads another bucket than $bucket" >&2; fails=$((fails + 1)); }
eq "$(yq '.x-imgproxy-cache.image' ../docker-compose.yml)" "$(yq '.images.nginx.repository + ":" + .images.nginx.tag' stack/values.yaml)" "compose imgproxy-cache image"
eq "$(yq '.x-package-proxy.image' ../docker-compose.yml)" "$(yq '.images.packageProxy.repository + ":" + .images.packageProxy.tag' stack/values.yaml)" "compose package-proxy image"
# objectstore-init-agent-* make the bucket and its expiry the runtime reads
# from env/agent.env, as the chart's job does from the file.
for s in dev prod; do
  eq "$(yq ".services.objectstore-init-agent-$s.environment.OBJECT_STORE_BUCKET" ../docker-compose.yml 2>/dev/null)" "$(sed -n 's/^WORKSPACE_BUCKET=//p' stack/env/agent.env)" "compose $s workspace bucket"
  eq "$(yq ".services.objectstore-init-agent-$s.environment.OBJECT_STORE_EXPIRE_DAYS" ../docker-compose.yml 2>/dev/null)" "$(sed -n 's/^WORKSPACE_EXPIRE_DAYS=//p' stack/env/agent.env)" "compose $s workspace expiry"
done
for c in ghtk ghn; do
  eq "$(yq ".x-server-env.CARRIER_${c^^}" ../docker-compose.yml)" "$(yq ".server.carriers.$c.mode" stack/values-dev.yaml)" "compose CARRIER_${c^^}"
done
eq "$(yq '.x-server-env.PAYMENT_VNPAY' ../docker-compose.yml)" "$(yq '.server.payment.mode' stack/values-dev.yaml)" "compose PAYMENT_VNPAY"
# The settings every stack shares are in stack/env/*.env, which compose
# (env_file) and the chart both read; a key
# there is written nowhere else.
# The chart fails its render on a key in both; compose would let its own
# block win, so this catches it.
for f in stack/env/server.env:x-server-env stack/env/agent.env:x-agent-env stack/env/bifrost.env:x-bifrost stack/env/lgtm.env:x-lgtm stack/env/imgproxy.env:x-imgproxy-env; do
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
