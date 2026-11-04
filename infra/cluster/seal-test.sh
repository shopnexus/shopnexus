#!/usr/bin/env bash
# seal.sh keeps the keys it generated: a second run seals the same values.
set -euo pipefail
cd "$(dirname "$0")"
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
for s in dev prod; do
  cp ../stack/secrets/example.env "$dir/$s.env"
  sed -i 's/^LLM_API_KEY=$/LLM_API_KEY=test/' "$dir/$s.env"
done
first=$(SECRETS_DIR=$dir ./seal.sh dev --dry-run)
second=$(SECRETS_DIR=$dir ./seal.sh dev --dry-run)
[[ "$first" == "$second" ]] || { echo "FAIL: a second run changed the secrets" >&2; exit 1; }
grep -q 'JWT_PRIVATE_KEY' <<<"$first" || { echo "FAIL: no JWT key" >&2; exit 1; }
grep -q 'private.pem' <<<"$first" || { echo "FAIL: no Restate key" >&2; exit 1; }
if SECRETS_DIR=$dir ./seal.sh prod --dry-run >/dev/null 2>"$dir/err"; then echo "FAIL: prod sealed without FCM_CREDENTIALS" >&2; exit 1; fi
grep -q FCM_CREDENTIALS "$dir/err" || { echo "FAIL: prod refused for another reason: $(cat "$dir/err")" >&2; exit 1; }
echo "seal.sh is idempotent"
