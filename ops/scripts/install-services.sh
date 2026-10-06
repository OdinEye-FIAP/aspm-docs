#!/usr/bin/env bash
# VPS (root): instala captain-hook, moby-dick, pequod e tars-ai como serviços
# systemd, a partir dos repos já clonados em $ASPM_HOME. Não depende de
# credenciais do GitHub (usa rsync do clone local). Idempotente — serve também
# para ATUALIZAR: faça `git pull` nos repos e rode de novo com --restart.
#
# Uso: sudo ASPM_HOME=/home/deploy/aspm-ai ./install-services.sh [--start | --restart]
#
# Ordem recomendada no primeiro deploy:
#   1) install-services.sh   (cria usuários, /opt/<svc>, venv, units)
#   2) bootstrap-env.sh --vps (cria /etc/<svc>/env com dono/permissão corretos)
#   3) preencher itens manuais (GitHub App, SONAR_TOKEN, IA)
#   4) install-services.sh --start
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }

ASPM_HOME="${ASPM_HOME:?defina ASPM_HOME com o diretório que contém os repos}"
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"

# serviço:usuário
SERVICES=("pequod:pequod" "tars-ai:tarsai" "captain-hook:captainhook" "moby-dick:mobydick")

for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"; user="${entry##*:}"
  src="$ASPM_HOME/$svc"; dst="/opt/$svc"
  [ -d "$src" ] || { echo "faltando $src" >&2; exit 1; }

  id "$user" >/dev/null 2>&1 || useradd --system --home "$dst" --shell /usr/sbin/nologin "$user"
  # moby-dick precisa do socket do Docker
  [ "$svc" = moby-dick ] && usermod -aG docker "$user"

  mkdir -p "$dst" "/etc/$svc"
  rsync -a --delete \
    --exclude '.git' --exclude '.venv' --exclude 'venv' --exclude '.env' \
    --exclude '__pycache__' --exclude '.pytest_cache' --exclude 'tests' \
    --exclude 'node_modules' "$src/" "$dst/"
  chown -R "$user:$user" "$dst"

  [ -d "$dst/.venv" ] || sudo -u "$user" python3 -m venv "$dst/.venv"
  sudo -u "$user" "$dst/.venv/bin/pip" install -q --upgrade pip
  sudo -u "$user" "$dst/.venv/bin/pip" install -q -r "$dst/requirements.txt"

  unit="$src/deploy/$svc.service"
  [ -f "$unit" ] || unit="$OPS_DIR/systemd/$svc.service"
  install -m 644 "$unit" "/etc/systemd/system/$svc.service"
  echo "✔ $svc instalado em $dst"
done

systemctl daemon-reload
case "$ACTION" in
  --start)   for e in "${SERVICES[@]}"; do systemctl enable --now "${e%%:*}"; done ;;
  --restart) for e in "${SERVICES[@]}"; do systemctl restart "${e%%:*}"; done ;;
  *)         echo "Units instaladas. Preencha os envs e rode com --start." ;;
esac
