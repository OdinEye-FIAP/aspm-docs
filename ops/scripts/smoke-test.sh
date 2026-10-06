#!/usr/bin/env bash
# Verifica se o ecossistema subiu: rede, containers, tópicos, imagens de scanner
# e /health de cada serviço. Sai com código != 0 se algo falhar.
#
# Uso: ./smoke-test.sh [--public BASE_DOMAIN]
set -uo pipefail

PUBLIC=""; [ "${1:-}" = "--public" ] && PUBLIC="${2:?informe BASE_DOMAIN}"
fail=0
ok()  { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$1"; fail=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

echo "Infra"
check "rede aspm-net"                    docker network inspect aspm-net
check "redpanda healthy"                 bash -c "docker exec aspm-redpanda rpk cluster health | grep -qiE 'Healthy: +true'"
check "sonarqube UP"                     bash -c "curl -sf http://localhost:9000/api/system/status | grep -q '\"status\":\"UP\"'"
check "postgres do pequod (pg_isready)"  docker exec aspm-pequod-db pg_isready -U pequod

echo "Tópicos Kafka"
topics="$(docker exec aspm-redpanda rpk topic list 2>/dev/null | awk 'NR>1{print $1}')"
for t in jobs.orchestration findings.raw quality-gate.workflow.started.v1 \
         quality-gate.scanner.completed.v1 quality-gate.evaluated.v1; do
  if grep -qx "$t" <<<"$topics"; then ok "$t"; else bad "$t ausente (rode create-topics.sh)"; fi
done

echo "Imagens de scanner"
check "aspm-sonar-runner" docker image inspect aspm-sonar-runner:latest
for s in semgrep trivy zap; do
  docker image inspect "aspm-$s-runner:latest" >/dev/null 2>&1 \
    && ok "aspm-$s-runner" || echo "  · aspm-$s-runner não buildada (ok se ENABLE_${s^^}_SCAN=false)"
done

echo "Serviços (/health)"
check "captain-hook :8080" curl -sf http://localhost:8080/health
check "moby-dick    :9090" curl -sf http://localhost:9090/health
check "pequod       :7070" curl -sf http://localhost:7070/health
check "tars-ai      :6060" curl -sf http://localhost:6060/health

if [ -n "$PUBLIC" ]; then
  echo "Público (https://*.$PUBLIC)"
  check "hook.$PUBLIC/health"          curl -sf "https://hook.$PUBLIC/health"
  # 200 (sem auth) ou 401 (basic auth ligado) significam que o TLS e o host estão ok
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://heimdall.$PUBLIC/")"
  if [ "$code" = 200 ] || [ "$code" = 401 ]; then ok "heimdall.$PUBLIC (HTTP $code)"; else bad "heimdall.$PUBLIC (HTTP $code)"; fi
fi

[ "$fail" -eq 0 ] && echo -e "\nTudo certo." || echo -e "\nHá falhas acima."
exit "$fail"
