#!/usr/bin/env bash
# seal.sh dev|prod [--dry-run]
#
# Seals <stack>.env into infra/stack/secrets/<stack>/*.yaml. On first use it
# copies example.env, generates every key the stack needs and keeps them in
# the git-ignored <stack>.env, so a later run seals the same keys.
# --dry-run prints the plain Secrets instead of sealing them; it needs no cluster.
set -euo pipefail
stack=${1:?usage: seal.sh dev|prod [--dry-run]}
[[ $stack == dev || $stack == prod ]] || { echo "stack must be dev or prod" >&2; exit 2; }
dry=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
dir=${SECRETS_DIR:-$here/../stack/secrets}
env_file=$dir/$stack.env
pem=$dir/$stack.restate.pem
image=${SERVER_IMAGE:-ghcr.io/shopnexus/server:main}

[[ -f $env_file ]] || cp "$here/../stack/secrets/example.env" "$env_file"
get() { grep -m1 "^$1=" "$env_file" | cut -d= -f2-; }
has() { grep -q "^$1=." "$env_file"; }

has JWT_KEY_ID || docker run --rm --entrypoint /keygen "$image" >> "$env_file"
has STAFF_KEY || docker run --rm --entrypoint /keygen "$image" -staff >> "$env_file"
if ! has RESTATE_IDENTITY_KEY || [[ ! -f $pem ]]; then
  sed -i '/^RESTATE_IDENTITY_KEY=/d' "$env_file"
  docker run --rm --user "$(id -u)" -v "$dir:/out" --entrypoint /keygen "$image" \
    -restate "/out/$(basename "$pem")" >> "$env_file"
fi
has OBJECT_STORE_ACCESS_KEY || echo "OBJECT_STORE_ACCESS_KEY=$(openssl rand -hex 12)" >> "$env_file"
has OBJECT_STORE_SECRET_KEY || echo "OBJECT_STORE_SECRET_KEY=$(openssl rand -hex 24)" >> "$env_file"

has LLM_API_KEY || { echo "$env_file: set LLM_API_KEY" >&2; exit 1; }
if [[ $stack == prod ]] && ! has FCM_CREDENTIALS; then
  echo "$env_file: prod needs FCM_CREDENTIALS (APP_ENV=prod refuses to only log pushes)" >&2; exit 1
fi

server_keys=(JWT_KEY_ID JWT_PRIVATE_KEY STAFF_KEY RESTATE_IDENTITY_KEY OBJECT_STORE_ACCESS_KEY OBJECT_STORE_SECRET_KEY LLM_API_KEY FCM_CREDENTIALS)
args=(); for k in "${server_keys[@]}"; do args+=(--from-literal="$k=$(get "$k")"); done

out() { if [[ $dry == --dry-run ]]; then echo ---; cat; else kubeseal --format yaml > "$1"; fi; }
mkdir -p "$here/../stack/secrets/$stack"
kubectl create secret generic server-secrets -n "shopnexus-$stack" "${args[@]}" --dry-run=client -o yaml \
  | out "$here/../stack/secrets/$stack/server-secrets.yaml"
kubectl create secret generic restate-secrets -n "restate-$stack" \
  --from-file=private.pem="$pem" \
  --from-literal=AWS_ACCESS_KEY_ID="$(get OBJECT_STORE_ACCESS_KEY)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(get OBJECT_STORE_SECRET_KEY)" \
  --dry-run=client -o yaml \
  | out "$here/../stack/secrets/$stack/restate-secrets.yaml"
[[ $dry == --dry-run ]] || echo "sealed into infra/stack/secrets/$stack/; commit and push"
