#!/usr/bin/env bash
# Sobe a infraestrutura Docker (rede aspm-net, Redpanda + Console, SonarQube + DB,
# Postgres do pequod) na ordem certa e cria os tópicos Kafka.
#
# Uso:
#   ASPM_HOME=~/aspm-ai ./infra-up.sh          # local (portas em 0.0.0.0, como nos compose dos repos)
#   ASPM_HOME=~/aspm-ai ./infra-up.sh --vps    # VPS: publica portas só em 127.0.0.1 (override)
set -euo pipefail

ASPM_HOME="${ASPM_HOME:?defina ASPM_HOME com o diretório que contém os repos}"
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPS=0; [ "${1:-}" = "--vps" ] && VPS=1

wait_healthy() { # wait_healthy container [timeout_s]
  local c="$1" t="${2:-180}" s=0
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ]; do
    sleep 3; s=$((s+3)); [ "$s" -ge "$t" ] && { echo "✘ $c não ficou healthy em ${t}s" >&2; docker logs --tail 30 "$c" >&2; exit 1; }
  done
  echo "✔ $c healthy"
}

# Sonar exige vm.max_map_count >= 262144 (Elasticsearch embutido)
if [ "$(uname -s)" = Linux ] && [ "$(sysctl -n vm.max_map_count)" -lt 262144 ]; then
  echo "· ajustando vm.max_map_count=262144 (requer sudo)"
  sudo sysctl -w vm.max_map_count=262144
  echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-sonarqube.conf >/dev/null
fi

docker network inspect aspm-net >/dev/null 2>&1 || docker network create aspm-net >/dev/null
echo "✔ rede aspm-net"

# 1) Redpanda + Console + SonarQube (+ DB) — compose do captain-hook (dono da rede)
cd "$ASPM_HOME/captain-hook"
if [ "$VPS" -eq 1 ]; then
  docker compose -f docker-compose.yml -f "$OPS_DIR/compose/captain-hook.vps.yml" up -d
else
  docker compose up -d
fi
wait_healthy aspm-redpanda
wait_healthy aspm-sonar-db

# 2) Postgres do pequod (aplica deploy/schema.sql só no primeiro boot do volume)
cd "$ASPM_HOME/pequod"
if [ "$VPS" -eq 1 ]; then
  docker compose -f docker-compose.yml -f "$OPS_DIR/compose/pequod.vps.yml" up -d
else
  docker compose up -d
fi
wait_healthy aspm-pequod-db

# 3) Tópicos Kafka
"$OPS_DIR/scripts/create-topics.sh"

# 4) SonarQube (demora ~1-2 min no primeiro boot)
echo -n "· aguardando SonarQube"
for _ in $(seq 1 60); do
  if curl -sf http://localhost:9000/api/system/status | grep -q '"status":"UP"'; then echo " — UP"; exit 0; fi
  echo -n "."; sleep 5
done
echo; echo "✘ SonarQube não ficou UP (veja: docker logs aspm-sonarqube)" >&2; exit 1
