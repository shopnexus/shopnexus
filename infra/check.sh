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

# ── end of checks ──
(( fails == 0 )) || { echo "$fails check(s) failed" >&2; exit 1; }
echo "all checks passed"
