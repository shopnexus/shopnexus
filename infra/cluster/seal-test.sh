#!/usr/bin/env bash
# seal.sh keeps the keys it generated: a second run seals the same values.
set -euo pipefail
cd "$(dirname "$0")"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
for s in dev prod; do
  cp ../stack/secrets/example.env "$dir/$s.env"
  sed -i 's/^LLM_UPSTREAM_API_KEY=$/LLM_UPSTREAM_API_KEY=test/' "$dir/$s.env"
done
first=$(SECRETS_DIR=$dir ./seal.sh dev --dry-run)
second=$(SECRETS_DIR=$dir ./seal.sh dev --dry-run)
[[ "$first" == "$second" ]] || { echo "FAIL: a second run changed the secrets" >&2; exit 1; }
grep -q 'JWT_PRIVATE_KEY' <<<"$first" || { echo "FAIL: no JWT key" >&2; exit 1; }
grep -q 'private.pem' <<<"$first" || { echo "FAIL: no Restate key" >&2; exit 1; }
[[ $(yq ea -N 'select(.kind=="Secret") | .metadata.name' <<<"$first" | sort | tr '\n' ' ') == "litellm-db litellm-secrets restate-secrets server-secrets " ]] || { echo "FAIL: --dry-run does not print two Secret documents" >&2; exit 1; }
if SECRETS_DIR=$dir ./seal.sh prod --dry-run >/dev/null 2>"$dir/err"; then echo "FAIL: prod sealed without FCM_CREDENTIALS" >&2; exit 1; fi
grep -q FCM_CREDENTIALS "$dir/err" || { echo "FAIL: prod refused for another reason: $(cat "$dir/err")" >&2; exit 1; }
[[ $(stat -c %a "$dir/dev.env") == 600 ]] || { echo "FAIL: dev.env is readable by others: $(stat -c %a "$dir/dev.env")" >&2; exit 1; }
# A restored .env without its .pem must stop, not rotate the Restate key.
key=$(grep '^RESTATE_IDENTITY_KEY=' "$dir/dev.env")
rm "$dir/dev.restate.pem"
if SECRETS_DIR=$dir ./seal.sh dev --dry-run >/dev/null 2>"$dir/err"; then echo "FAIL: sealed with a missing .pem" >&2; exit 1; fi
grep -q 'dev.restate.pem' "$dir/err" || { echo "FAIL: the error does not name the missing .pem: $(cat "$dir/err")" >&2; exit 1; }
[[ $(grep '^RESTATE_IDENTITY_KEY=' "$dir/dev.env") == "$key" ]] || { echo "FAIL: the Restate key changed" >&2; exit 1; }
echo "seal.sh is idempotent"
