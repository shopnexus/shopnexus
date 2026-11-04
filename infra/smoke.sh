#!/usr/bin/env bash
# smoke.sh <domain> [-k]: requests every host of one stack. -k accepts a
# staging certificate.
set -euo pipefail
d=${1:?usage: smoke.sh <domain> [-k]}
k=${2:-}
fails=0
check() {
  code=$(curl -s $k -o /dev/null -w '%{http_code}' --max-time 10 "$1") || code=000
  if [[ $code =~ ^$2$ ]]; then echo "ok   $1 $code"; else echo "FAIL $1 got $code want $2"; fails=$((fails + 1)); fi
}
check "https://$d/" 200
check "https://api.$d/healthz" 200
check "https://api.$d/readyz" 200
check "https://docs.$d/" 200
check "https://media.$d/health" 200
check "http://api.$d/healthz" 30[18]   # plain HTTP is redirected: 308 by Caddy behind a proxy, 301 by Traefik in direct mode
(( fails == 0 ))
