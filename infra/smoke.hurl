# Requests every host of one stack:
#
#   hurl --test --continue-on-error --variable domain=dev.shopnexus.id.vn infra/smoke.hurl
#
# --insecure accepts a Let's Encrypt staging certificate.

GET https://{{domain}}/
HTTP 200

GET https://api.{{domain}}/healthz
HTTP 200

GET https://api.{{domain}}/readyz
HTTP 200

GET https://docs.{{domain}}/
HTTP 200

GET https://console.{{domain}}/
HTTP 200

GET https://media.{{domain}}/health
HTTP 200

# Plain HTTP is redirected to HTTPS: 308 by Caddy behind a proxy, 301 by
# Traefik in direct mode.
GET http://api.{{domain}}/healthz
HTTP *
[Asserts]
status toString matches "^30[18]$"
header "Location" startsWith "https://"
