#!/bin/sh
# LiteLLM's starting aliases (models/) and its keys, one per line of keys.txt.
#
#   keys.sh gen keys.txt FILE   adds to the env file FILE every key it
#                               lacks, LITELLM_MASTER_KEY and each key's
#                               variable, as sk- and 48 hex digits
#   keys.sh models DIR          adds each alias of DIR (models/, one
#                               /model/new body per <alias>.json) that
#                               LiteLLM has no deployment of, and sets the
#                               prices of the file on the deployment
#                               seed-<alias> when it exists; any other
#                               deployment of an alias stays as it is
#   keys.sh sync keys.txt       makes every key exist in LiteLLM with
#                               its budget: updates it when it exists,
#                               creates it with the client's value when it
#                               does not
#
# The chart's Secrets hold the keys, so the cluster runs models and sync
# only; compose runs gen on its keys volume's .env, then models and sync.
#
# models reads LITELLM_URL and MASTER_KEY. Each seeded deployment has the id
# seed-<alias>; LiteLLM refuses a second deployment with that id. The prices
# are the file's litellm_params *_cost_per_* lines, one per line.
# sync reads LITELLM_URL, MASTER_KEY, each key's variable (column 3 of
# keys.txt) and its limits, LIMITS_<KEY> with KEY the alias upper-cased and
# - as _ (LIMITS_SERVER_LLM), or LIMITS_DEFAULT. A limits value is the JSON
# members of the budget, such as "max_budget":2,"tpm_limit":100000.
# Responses hold the keys, so only their status is printed.
set -eu

keys() { grep -v '^#' "$1" | grep -v '^[[:space:]]*$'; }

gen() {
	for var in LITELLM_MASTER_KEY $(keys "$1" | while read -r _ _ var _; do echo "$var"; done); do
		if ! grep -q "^$var=." "$2" 2>/dev/null; then
			echo "$var=sk-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" >>"$2"
			echo "added $var"
		fi
	done
}

call() {
	curl -s -o /tmp/out -w '%{http_code}' -X POST "$LITELLM_URL/key/$1" \
		-H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' -d "$body"
}

# json_list "a,b" prints ["a","b"].
json_list() {
	printf '[%s]' "$(printf '%s' "$1" | sed 's/[^,][^,]*/"&"/g')"
}

models() {
	code=$(curl -s -o /tmp/models -w '%{http_code}' "$LITELLM_URL/model/info" \
		-H "Authorization: Bearer $MASTER_KEY")
	[ "$code" = 200 ] || { echo "models: /model/info: HTTP $code"; exit 1; }
	for file in "$1"/*.json; do
		alias=$(basename "$file" .json)
		if grep -Eq "\"id\": ?\"seed-$alias\"" /tmp/models; then
			prices=$(grep -E '^ *"[a-z_]*cost_per_[a-z_]*": ' "$file" | tr -d ' \n' | sed 's/,$//')
			body="{\"litellm_params\":{$prices}}"
			code=$(curl -s -o /tmp/out -w '%{http_code}' -X PATCH "$LITELLM_URL/model/seed-$alias/update" \
				-H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' -d "$body")
			echo "model $alias: prices of seed-$alias, HTTP $code"
			[ "$code" = 200 ] || { grep -o '"message":"[^"]*"' /tmp/out; exit 1; }
			continue
		fi
		if grep -Eq "\"model_name\": ?\"$alias\"" /tmp/models; then
			echo "model $alias: present"
			continue
		fi
		code=$(curl -s -o /tmp/out -w '%{http_code}' -X POST "$LITELLM_URL/model/new" \
			-H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' -d @"$file")
		echo "model $alias: HTTP $code"
		[ "$code" = 200 ] || { grep -o '"message":"[^"]*"' /tmp/out; exit 1; }
	done
}

sync() {
	keys "$1" | while read -r alias _secret var allows; do
		value=$(printenv "$var" || true)
		[ -n "$value" ] || { echo "key $alias: $var is not set"; exit 1; }
		limits_var=LIMITS_$(printf '%s' "$alias" | tr 'a-z-' 'A-Z_')
		limits=$(printenv "$limits_var" || printenv LIMITS_DEFAULT || true)
		[ -n "$limits" ] || { echo "key $alias: $limits_var is not set"; exit 1; }
		body="{\"key\":\"$value\",\"key_alias\":\"$alias\",\"budget_duration\":\"1d\",$limits,\"models\":$(json_list "$allows")}"
		code=$(call update)
		[ "$code" = 200 ] || code=$(call generate)
		echo "key $alias: HTTP $code"
		[ "$code" = 200 ] || { grep -o '"message":"[^"]*"' /tmp/out; exit 1; }
	done
}

case "${1:-}" in
gen) gen "$2" "$3" ;;
models) models "$2" ;;
sync) sync "$2" ;;
*) echo "usage: keys.sh gen keys.txt FILE | keys.sh models DIR | keys.sh sync keys.txt" >&2; exit 2 ;;
esac
