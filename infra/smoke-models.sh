#!/usr/bin/env bash
# Calls every LiteLLM alias of one stack through a port-forward, with the
# server's keys from server-secrets:
#
#   infra/smoke-models.sh dev|prod
set -euo pipefail
stack=${1:?dev or prod}
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
ns=shopnexus-$stack
work="$root/tmp/smoke-models-$stack"
mkdir -p "$work"

kubectl -n "$ns" port-forward svc/litellm 56598:4000 >"$work/port-forward.log" 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 30); do curl -fsS 127.0.0.1:56598/health/readiness >/dev/null 2>&1 && break; sleep 1; done

key() { kubectl -n "$ns" get secret server-secrets -o jsonpath="{.data.$1}" | base64 -d; }
go -C "$root/infra" run ./probes/sample wav 1 "$work/silence.wav"
hurl --test --file-root "$work" \
  --variable litellm=http://127.0.0.1:56598 \
  --secret llm_key="$(key LLM_API_KEY)" \
  --secret stt_key="$(key STT_API_KEY)" \
  --secret assist_key="$(key ASSIST_LLM_API_KEY)" \
  --secret trust_key="$(key TRUST_LLM_API_KEY)" \
  --secret embed_index_key="$(key EMBED_INDEX_API_KEY)" \
  --secret embed_search_key="$(key EMBED_SEARCH_API_KEY)" \
  --variable photo="$(go -C "$root/infra" run ./probes/sample jpeg 256 | tr -d '\n')" \
  "$here/smoke-models.hurl"
