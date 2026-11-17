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

# ── ai ──
# argocd/ai.yaml deploys the ai repo's chart into each stack with the values
# it holds; they render, validate, and keep the stack's photo vectors off when
# ai-models loads no SigLIP 2.
ai_chart=${AI_CHART:-../ai/chart}
[[ -f $ai_chart/Chart.yaml ]] || { echo "FAIL: no ai chart at $ai_chart (git submodule update --init ai, or set AI_CHART)" >&2; exit 1; }
for s in dev prod; do
  vals=$(yq "select(.metadata.name==\"ai-$s\") | .spec.source.helm.valuesObject" argocd/ai.yaml)
  helm lint --quiet "$ai_chart" -f <(echo "$vals") >/dev/null
  helm template ai "$ai_chart" -f <(echo "$vals") --namespace "shopnexus-$s" \
    | kubeconform -strict -ignore-missing-schemas -summary -schema-location default - >/dev/null
  eq "$(yq '.stack' <<<"$vals")" "$s" "ai-$s stack"
  eq "$(yq "select(.metadata.name==\"ai-$s\") | .spec.destination.namespace" argocd/ai.yaml)" "shopnexus-$s" "ai-$s namespace"
  embed=$(yq '.models.embedModels' <<<"$vals")
  image=$(yq '.server.embed.image' "stack/values-$s.yaml")
  [[ $image == null ]] && image=$(yq '.server.embed.image' stack/values.yaml)
  eq "$([[ -n $embed ]] && echo true || echo false)" "$image" "$s: photo vectors on exactly when ai-models loads SigLIP 2"
done

# ── argo ──
apps=$(for f in argocd/*.yaml platform/*.yaml; do cat "$f"; echo ---; done 2>/dev/null || true)
eq "$(q "$apps" 'select(.kind=="Application") | .metadata.name' | sort | tr '\n' ' ')" "ai-dev ai-prod cnpg image-updater prometheus restate-operator root sealed-secrets stack-dev stack-prod " "applications"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.source.helm.valueFiles[0]')" values-prod.yaml "prod values"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="stack-prod") | .spec.destination.namespace')" shopnexus-prod "prod namespace"
eq "$(q "$apps" 'select(.kind=="Application") | (.spec.source.repoURL, .spec.sources[].repoURL)' | grep github.com | sort -u | tr '\n' ' ')" "https://github.com/shopnexus/ai.git https://github.com/shopnexus/shopnexus.git " "the umbrella's and the ai repo's URLs"
eq "$(q "$apps" 'select(.kind=="Application" and .metadata.name=="root") | .spec.ignoreDifferences[0].jsonPointers[0]')" /spec/source/helm/parameters "root keeps Image Updater's parameters"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-prod") | .images[0].commonUpdateSettings.updateStrategy')" semver "prod by semver"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="stack-dev") | .images[0].commonUpdateSettings.updateStrategy')" digest "dev by digest"
for s in dev prod; do eq "$(q "$apps" "select(.kind==\"ImageUpdater\") | .spec.applicationRefs[] | select(.namePattern==\"stack-$s\") | .images[].alias" | sort | tr '\n' ' ')" "agent console docs server website " "stack-$s images"; done
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="ai-dev") | .images[0].commonUpdateSettings.updateStrategy')" digest "ai-dev by digest"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .spec.applicationRefs[] | select(.namePattern=="ai-prod") | .images[0].commonUpdateSettings.updateStrategy')" semver "ai-prod by semver"
# First sync of an empty cluster: the ImageUpdater CRD arrives with a child
# Application, every Application retries, and Argo CD judges Application health
# so root's waves wait for the platform.
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-options"]')" SkipDryRunOnMissingResource=true "ImageUpdater survives the dry-run"
eq "$(q "$apps" 'select(.kind=="ImageUpdater") | .metadata.annotations["argocd.argoproj.io/sync-wave"]')" 1 "ImageUpdater waits for the platform only"
eq "$(q "$apps" 'select(.kind=="Application" and .spec.syncPolicy.retry.limit == -1) | .metadata.name' | sort | tr '\n' ' ')" "ai-dev ai-prod cnpg image-updater prometheus restate-operator root sealed-secrets stack-dev stack-prod " "every Application retries"
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
# The dashboards' IngressRoute reaches Restate and Argo CD in other namespaces.
for e in "$direct" "$proxy"; do grep -qF -- '--providers.kubernetescrd.allowCrossNamespace=true' <<<"$e" || { echo "FAIL: an edge lacks allowCrossNamespace" >&2; fails=$((fails + 1)); }; done
# Argo CD sits behind the console's sign-in, which lets admins only, and asks for none itself.
argo=$(yq '.spec.valuesContent' cluster/argocd.yaml)
eq "$(yq '.configs.cm["users.anonymous.enabled"]' <<<"$argo")" true "Argo CD takes the gate's admins without a sign-in"
eq "$(yq '.configs.rbac["policy.default"]' <<<"$argo")" role:admin "Argo CD's anonymous user is an admin"

# ── local compose ──
# Every stack of the root docker-compose.yml runs the stack's data services
# from the x-postgres, x-restate and x-rustfs blocks.
for s in postgres restate rustfs; do
  eq "$(yq ".x-$s.image" ../docker-compose.yml)" "$(yq ".images.$s.repository + \":\" + .images.$s.tag" stack/values.yaml)" "compose $s image"
done
# The embedding versions the local server stores, and ai-models' settings,
# follow the charts.
eq "$(yq '.x-server-env.EMBED_TEXT_VERSION' ../docker-compose.yml)" "$(yq '.server.embed.textVersion' stack/values.yaml)" "compose EMBED_TEXT_VERSION"
eq "$(yq '.x-server-env.EMBED_IMAGE_VERSION' ../docker-compose.yml)" "$(yq '.server.embed.imageVersion' stack/values.yaml)" "compose EMBED_IMAGE_VERSION"
for k in EMBED_MAX_INPUTS:embedMaxInputs EMBED_MAX_CONCURRENT:embedMaxConcurrent EMBED_MAX_IMAGE_MB:embedMaxImageMB \
  FRAMES_MAX_CONCURRENT:framesMaxConcurrent FRAMES_MAX_SECONDS:framesMaxSeconds FRAMES_MIN_SHARPNESS:framesMinSharpness; do
  eq "$(yq ".x-ai-models.environment.AI_${k%%:*}" ../docker-compose.yml)" "$(yq ".models.${k#*:}" "$ai_chart/values.yaml")" "compose AI_${k%%:*}"
done
eq "$(yq '.x-server-env.ASSIST_CALL_TIMEOUT' ../docker-compose.yml)" "$(yq '.server.assist.callTimeout' stack/values.yaml)" "compose ASSIST_CALL_TIMEOUT"
eq "$(yq '.x-server-env.CHOTOT_GATEWAY_URL' ../docker-compose.yml)" "$(yq '.server.assist.chototGatewayURL' stack/values.yaml)" "compose CHOTOT_GATEWAY_URL"
eq "$(yq '.x-server-env.CHOTOT_CDN_URL' ../docker-compose.yml)" "$(yq '.server.assist.chototCDNURL' stack/values.yaml)" "compose CHOTOT_CDN_URL"
eq "$(yq '.x-server-env.TRUST_CALL_TIMEOUT' ../docker-compose.yml)" "$(yq '.server.trust.callTimeout' stack/values.yaml)" "compose TRUST_CALL_TIMEOUT"
eq "$(yq '.x-server-env.CARRIER' ../docker-compose.yml)" "$(yq '.server.carrier' stack/values-dev.yaml)" "compose CARRIER"
eq "$(yq '.x-server-env.CARRIER_POLL_EVERY' ../docker-compose.yml)" "$(yq '.server.carrierPollEvery' stack/values.yaml)" "compose CARRIER_POLL_EVERY"
# The console agent's settings and the server's MCP port follow the chart.
for k in MAX_TOKENS:maxTokens THINKING_BUDGET:thinkingBudget MAX_TURNS:maxTurns TOOL_OUTPUT_CAP:toolOutputCap \
  MEMORY_ENTRY_CAP:memoryEntryCap MEMORY_MAX_ENTRIES:memoryMaxEntries CONVERSATION_WINDOW:conversationWindow \
  HISTORY_TURNS:historyTurns HISTORY_CHARS:historyChars TURN_DEADLINE_MS:turnDeadlineMs SWEEP_INTERVAL_MS:sweepIntervalMs; do
  eq "$(yq ".x-agent-env.AGENT_${k%%:*}" ../docker-compose.yml)" "$(yq ".agent.${k#*:}" stack/values.yaml)" "compose AGENT_${k%%:*}"
done
eq "$(yq '.x-agent-env.RETRIEVAL_CONTEXT_CHARS' ../docker-compose.yml)" "$(yq '.agent.retrievalContextChars' stack/values.yaml)" "compose RETRIEVAL_CONTEXT_CHARS"
eq "$(yq '.x-agent-env.DOCUMENT_CHUNK_CHARS' ../docker-compose.yml)" "$(yq '.agent.documentChunkChars' stack/values.yaml)" "compose DOCUMENT_CHUNK_CHARS"
eq "$(yq '.x-server-env.AGENT_MCP_ADDR' ../docker-compose.yml)" "$(helm template shopnexus stack -f stack/values-dev.yaml --set secretsDir=tests/secrets -s templates/server.yaml | yq 'select(.kind=="ConfigMap") | .data.AGENT_MCP_ADDR')" "compose AGENT_MCP_ADDR"

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
