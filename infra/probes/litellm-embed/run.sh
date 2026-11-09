#!/usr/bin/env bash
# Measures, on the pinned LiteLLM, what photo search relies on
# (spec 2026-11-09-server2-photo-similar-search-design.md, "Measured first"):
#   1. a data URL and a text in input reach the upstream unchanged;
#   2. a call is priced from the upstream's usage, not from the input's length;
#   4. no input lands in LiteLLM_SpendLogs.
# It also prints what LiteLLM sends upstream besides input.
#   infra/probes/litellm-embed/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
export OUT_DIR="$root/tmp/probe-litellm-embed"
rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
dc() { docker compose -f "$here/compose.yaml" "$@"; }
trap 'dc down -v >/dev/null 2>&1 || true' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

dc up -d --build --wait
api=http://127.0.0.1:56599
for _ in $(seq 90); do curl -fsS "$api/health/readiness" >/dev/null 2>&1 && break; sleep 1; done
master="Authorization: Bearer sk-probe-master"

key=$(curl -fsS "$api/key/generate" -H "$master" -H 'Content-Type: application/json' \
  -d '{"key_alias":"probe","models":["embed-image"],"max_budget":10,"budget_duration":"1d"}' | jq -r .key)

embed() { # $1: a file holding the request body
  curl -sS -o "$OUT_DIR/answer.json" -w '%{http_code}' "$api/v1/embeddings" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' --data-binary "@$1"; }

# A photo the size the server sends (768 px), one near 1 MB, and a text.
go -C "$root/infra" run ./probes/sample jpeg 768 | tr -d '\n' >"$OUT_DIR/photo.txt"
go -C "$root/infra" run ./probes/sample jpeg 1200 | tr -d '\n' >"$OUT_DIR/big.txt"
calls=0
for f in photo big; do
  jq -Rn --rawfile u "$OUT_DIR/$f.txt" '{model:"embed-image", input:[$u]}' >"$OUT_DIR/$f.req.json"
  code=$(embed "$OUT_DIR/$f.req.json"); calls=$((calls + 1))
  [[ $code == 200 ]] || fail "$f: HTTP $code: $(head -c 300 "$OUT_DIR/answer.json")"
  sent=$(jq -r '.input[0]' "$OUT_DIR/$calls.json" 2>/dev/null || jq -r '.input' "$OUT_DIR/$calls.json")
  [[ $(sha256sum <<<"$sent") == $(sha256sum <<<"$(cat "$OUT_DIR/$f.txt")") ]] || fail "1: the $f data URL changed on its way upstream"
  echo "$f: $(wc -c <"$OUT_DIR/$f.txt") bytes of data URL"
done
jq -n '{model:"embed-image", input:["a blue bicycle"]}' >"$OUT_DIR/text.req.json"
code=$(embed "$OUT_DIR/text.req.json"); calls=$((calls + 1))
[[ $code == 200 ]] || fail "text: HTTP $code"
[[ $(jq -r '.input[0] // .input' "$OUT_DIR/$calls.json") == "a blue bicycle" ]] || fail "1: the text changed on its way upstream"
echo "what LiteLLM sends upstream besides input: $(jq -c 'del(.input)' "$OUT_DIR/1.json")"

# 2. Three inputs at 576 tokens each: 1728 tokens, 0.001728 of budget. Counting
# the data URLs' characters would give about 400,000 tokens.
want=0.001728
spend=0
for _ in $(seq 60); do
  spend=$(curl -fsS "$api/key/info?key=$key" -H "$master" | jq -r '.info.spend // 0')
  awk -v s="$spend" 'BEGIN { exit !(s > 0) }' && break
  sleep 1
done
awk -v s="$spend" -v w="$want" 'BEGIN { d = s - w; if (d < 0) d = -d; exit !(d < 0.000001) }' \
  || fail "2: spend is $spend, want $want (priced from usage)"
echo "spend after $calls calls: $spend"

# 4. Spend logs exist but hold no input.
rows=$(dc exec -T postgres psql -U litellm -d litellm -Atc 'SELECT count(*) FROM "LiteLLM_SpendLogs"')
leaked=$(dc exec -T postgres psql -U litellm -d litellm -Atc \
  "SELECT count(*) FROM \"LiteLLM_SpendLogs\" s WHERE row_to_json(s)::text LIKE '%;base64,%' OR row_to_json(s)::text LIKE '%a blue bicycle%'")
(( rows >= calls )) || fail "4: $rows spend log rows for $calls calls; the check would prove nothing"
(( leaked == 0 )) || fail "4: $leaked spend log rows hold an input"
echo "spend log rows: $rows, holding an input: $leaked"

(( fails == 0 )) || { echo "$fails measurement(s) failed" >&2; exit 1; }
echo "all measurements passed"
