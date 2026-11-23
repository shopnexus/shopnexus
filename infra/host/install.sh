#!/bin/sh
# Installs the web guard on the host: sudo sh infra/host/install.sh
# Run it again after editing a file here; it replaces the installed copies.
set -eu
cd "$(dirname "$0")"

nft -c -f web-guard.nft
install -Dm644 web-guard.nft /etc/nftables.d/web-guard.nft
install -Dm644 90-web-guard.conf /etc/sysctl.d/90-web-guard.conf
install -Dm644 web-guard.service /etc/systemd/system/web-guard.service

sysctl -q -p /etc/sysctl.d/90-web-guard.conf
systemctl daemon-reload
systemctl enable web-guard.service
systemctl restart web-guard.service
nft list table inet web_guard | head -n 3
