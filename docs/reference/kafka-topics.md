# Tópicos Kafka

Referência completa dos tópicos usados (e previstos) no pipeline.

## Cluster

Stack atual: **Redpanda** (Kafka-compatible), single-node, sem replicação. Roda no `docker-compose.yml` do captain-hook.

| Endpoint | Uso |
|---|---|
| `localhost:9092` (interno do host) | Producers/consumers Python |
| `redpanda:9092` (dentro de aspm-net) | Containers internos |
| `localhost:9644` | Admin API |
| `localhost:8088` | Redpanda Console (UI) |

!!! tip "UI pra debug"
    Sempre tenha o Console aberto durante dev: http://localhost:8088 mostra tópicos, mensagens, consumer groups, lag.

## Tópicos ativos

### `github.events.raw`

**Producer:** captain-hook
**Consumer ativo:** nenhum (audit/replay)
**Key:** `repo_full_name`

**Value schema:**
```json
{
  "event_type": "pull_request",
  "delivery_id": "12345678-90ab-cdef-1234-567890abcdef",
  "payload": { ...payload bruto do webhook do GitHub... }
}
```

**Propósito:**
- Audit log do que entrou no sistema
- Replay possível pra reprocessar eventos passados
- Source-of-truth se o JobDescriptor v1 não tiver alguma info que precisamos depois

**Retenção:** default Redpanda (7 dias). Aumentar se quiser auditar período maior.

### `jobs.orchestration`

**Producer:** captain-hook
**Consumer:** moby-dick (consumer group `moby-dick`)
**Key:** `repo_full_name`

**Value:** [`JobDescriptor v1`](job-descriptor.md) serializado.

**Propósito:** instrução pro orquestrador executar um job (rodar container scanner + reportar resultado).

**Particionamento:** key = `repo_full_name` garante ordem por repo, paralelismo entre repos.

**Retenção:** default (7 dias). Mensagens já consumidas não precisam ser revisitadas — moby-dick commit do offset.

### `findings.raw`

**Producer:** moby-dick (após scan: extrai issues da Sonar API → converte SARIF v2.1.0)
**Consumer:** pequod (consumer group `pequod`)
**Key:** `repo_id` (= `gh_<github_repository_id>`)

**Value schema:** [`Finding v1`](finding-v1.md).

```json
{
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "repo": "OdinEye-FIAP/clint-eastwood",
  "repo_id": "gh_847291",
  "scanner": "sonarqube",
  "ref": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
  "sarif": { "$schema": "...", "version": "2.1.0", "runs": [ ... ] }
}
```

**Propósito:** evento de findings recém-extraídos, em formato scanner-agnóstico (SARIF). Pequod normaliza em `Finding v1`, dedupa por fingerprint e persiste.

**Particionamento:** key = `repo_id` (imutável a rename/transfer no GitHub).

**Retenção:** default (7 dias). Reprocessar implica re-upsert no pequod (idempotente via fingerprint).

## Tópicos futuros previstos

Nenhum criado ainda. Listados aqui pra alinhar nomenclatura quando virarem reais.

### `findings.created`, `findings.updated`, `findings.resolved`

**Producer:** pequod (após dedup/upsert)
**Consumer:** N (notifier, ai-triage, risk-engine, etc)

**Value:** schema `Finding v1` + diff de estado.

**Propósito:** event bus de findings normalizados. Cada serviço novo é um consumer independente, sem acoplamento ao pequod.

### `ai.enrichments.triage`, `ai.enrichments.reachability`

**Producer:** serviços de IA
**Consumer:** findings-store, dashboard

**Value:** schemas específicos de enrichment.

**Propósito:** anexar classificações IA aos findings sem mexer no store.

### `scans.completed`

**Producer:** moby-dick
**Consumer:** métricas, dashboard

**Value:** metadata do job (duração, exit code, image, scan_id).

**Propósito:** telemetria — quantos scans/dia, latência por scanner, taxa de falha.

## Convenções de naming

| Padrão | Uso |
|---|---|
| `<domain>.<event>.<state>` | findings.scan.completed, jobs.orchestration |
| Plural pro domain | `findings.*`, `jobs.*`, `events.*` |
| sem prefixo de versão no nome | versão fica no schema_version do payload |

## Particionamento

| Topic | Partition key | Razão |
|---|---|---|
| `github.events.raw` | `repo_full_name` | balancear por repo |
| `jobs.orchestration` | `repo_full_name` | ordem por repo (Sonar Community sobrescreve) |
| `findings.raw` | `repo_id` (`gh_<id>`) | ordem por repo, key estável a rename |
| `findings.created` (futuro) | `finding_fingerprint` | dedup por hash |

## Replay / reprocessamento

Pra reprocessar mensagens antigas:

```bash
# Reset consumer group ao início
docker exec aspm-redpanda rpk group seek moby-dick --to start

# OU a um timestamp específico
docker exec aspm-redpanda rpk group seek moby-dick --to-timestamp 1718000000000

# Pra pular acúmulo
docker exec aspm-redpanda rpk group seek moby-dick --to end
```

!!! warning "Cuidado com side effects"
    Reprocessar `jobs.orchestration` vai disparar scans de novo. Em produção, requer flag de "replay mode" no moby-dick que pule chamadas ao GitHub.

## Monitoring

Lag por consumer group:
```bash
docker exec aspm-redpanda rpk group describe moby-dick
docker exec aspm-redpanda rpk group describe pequod
```

Métricas do broker:
```bash
docker exec aspm-redpanda rpk cluster info
docker exec aspm-redpanda rpk cluster health
```

## Quando virar problema

Single-node Redpanda **não é prod-ready**. Sinais pra escalar:

- Lag persistente >1000 mensagens
- Broker dropa em manutenção (falta replicação)
- Throughput acima de ~10K msgs/s
- Necessidade de retenção infinita

Caminho de escala:
1. Redpanda multi-node (3 brokers, replicação 3)
2. Migrar pra Kafka real se ecossistema for crítico (Connect, ksqlDB)
3. Considerar Confluent Cloud / WarpStream pra ops gerenciado
