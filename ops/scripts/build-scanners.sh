#!/usr/bin/env bash
# Builda localmente as imagens dos scanners (não estão em registry). Rode na
# mesma máquina onde o moby-dick executa os jobs.
#
# Uso: ASPM_HOME=~/aspm-ai ./build-scanners.sh [sonar semgrep trivy zap]   (padrão: todos)
set -euo pipefail

ASPM_HOME="${ASPM_HOME:?defina ASPM_HOME com o diretório que contém os repos}"
CTX="$ASPM_HOME/moby-dick/deploy"
SCANNERS=("$@"); [ "${#SCANNERS[@]}" -eq 0 ] && SCANNERS=(sonar semgrep trivy zap)

for s in "${SCANNERS[@]}"; do
  [ -d "$CTX/$s-runner" ] || { echo "scanner desconhecido: $s" >&2; exit 2; }
  echo "→ aspm-$s-runner:latest"
  docker build -t "aspm-$s-runner:latest" "$CTX/$s-runner/"
done
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E '^aspm-.*-runner' || true
