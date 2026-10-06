#!/usr/bin/env bash
# Builda o heimdall-dashboard apontando para as APIs via mesmo host (proxy do
# Caddy) e publica o dist em /srv/heimdall.
#
# Uso: ASPM_HOME=~/aspm-ai BASE_DOMAIN=aspm.exemplo.com ./build-heimdall.sh
# Requer Node 20+ e npm. Escreve em /srv/heimdall (usa sudo se preciso).
set -euo pipefail

ASPM_HOME="${ASPM_HOME:?defina ASPM_HOME}"
BASE_DOMAIN="${BASE_DOMAIN:?defina BASE_DOMAIN}"
HOST="https://heimdall.${BASE_DOMAIN}"

cd "$ASPM_HOME/heimdall-dashboard"
npm ci
# As variáveis VITE_* são embutidas no bundle em tempo de build.
VITE_PEQUOD_API_URL="$HOST/api/pequod" \
VITE_TARS_API_URL="$HOST/api/tars" \
VITE_CAPTAIN_HOOK_API_URL="$HOST/api/hook" \
  npm run build

SUDO=""; [ -w /srv ] || SUDO="sudo"
$SUDO mkdir -p /srv/heimdall
$SUDO rsync -a --delete dist/ /srv/heimdall/
echo "✔ dashboard publicado em /srv/heimdall ($HOST)"
