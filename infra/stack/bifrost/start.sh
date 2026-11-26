#!/bin/sh
# Starts Bifrost on config.json. base_url takes no env. reference, so the
# upstream's URL is filled in here; the chart and compose both run this.
set -eu
sed "s|\${LLM_UPSTREAM_BASE_URL}|$LLM_UPSTREAM_BASE_URL|" /etc/bifrost/config.json >"$APP_DIR/config.json"
exec /app/docker-entrypoint.sh
