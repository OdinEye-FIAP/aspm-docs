#!/usr/bin/env bash
# Cria (idempotente) os tópicos Kafka e DLQs do ecossistema no Redpanda local.
# Lista alinhada com docs/reference/kafka-topics.md.
set -euo pipefail

CONTAINER="${REDPANDA_CONTAINER:-aspm-redpanda}"
PARTITIONS="${PARTITIONS:-3}"

TOPICS=(
  jobs.orchestration
  jobs.orchestration.dlq
  findings.raw
  findings.raw.dlq
  quality-gate.workflow.started.v1
  quality-gate.scanner.completed.v1
  quality-gate.evaluated.v1
  quality-gate.moby-dick.dlq
  quality-gate.pequod.dlq
)

existing="$(docker exec "$CONTAINER" rpk topic list 2>/dev/null | awk 'NR>1{print $1}')"
for t in "${TOPICS[@]}"; do
  if grep -qx "$t" <<<"$existing"; then
    echo "· $t (já existe)"
  else
    docker exec "$CONTAINER" rpk topic create "$t" -p "$PARTITIONS" -r 1 >/dev/null
    echo "✔ $t"
  fi
done
