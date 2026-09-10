# Tópicos Kafka

Referência completa dos tópicos usados no pipeline. Nomes confirmados em `config/settings.py` de captain-hook, moby-dick e pequod (2026-09-10).

## Cluster

Stack atual: **Redpanda** (Kafka-compatible), single-node, sem replicação. Roda no `docker-compose.yml` do captain-hook.

| Endpoint | Uso |
|---|---|
| `localhost:9092` (interno do host) | Producers/consumers Python |
| `redpanda:9092` (dentro de aspm-net) | Containers internos |
| `localhost:9644` | Admin API |
| `localhost:8088` | Redpanda Console (UI) |

!!! tip "UI pra debug"
    http://localhost:8088 mostra tópicos, mensagens, consumer groups, lag.

## Tópicos ativos

### `jobs.orchestration`

**Producer:** captain-hook · **Consumer:** moby-dick (`kafka_consumer_group=moby-dick`) · **Key:** `repo_full_name`

**Value:** [`JobDescriptor v1`](job-descriptor.md).

!!! warning "Não é mais 1 mensagem por PR"
    Um único evento de PR gera **uma mensagem por scanner habilitado** (Sonar sempre + Semgrep/Trivy/ZAP condicionados a `ENABLE_SEMGREP_SCAN`/`ENABLE_TRIVY_SCAN`/`ENABLE_ZAP_SCAN`). moby-dick roda até `SCANNER_MAX_CONCURRENCY=4` desses jobs em paralelo.

### `repository.registered.v1`

**Producer:** captain-hook · **Consumer:** pequod · **Key:** `repo_full_name`

**Propósito:** registra um repositório no pequod quando o evento `installation`/`installation_repositories`/`ping` indica que ele passou a fazer parte do onboarding.

### `repository.unregistered.v1`

**Producer:** captain-hook · **Consumer:** pequod · **Key:** `repo_full_name`

**Propósito:** baixa de repositório (ex: app desinstalado, repo removido da installation).

### `quality-gate.workflow.started.v1`

**Producer:** captain-hook · **Consumer:** moby-dick · **Key:** `repo_full_name`

**Propósito:** sinaliza o início de um workflow de quality gate para um PR.

!!! warning "Sem `scope=branch` em produção (corrigido 2026-09-10)"
    O pequod já sabe processar esse evento com `scope=branch` (Security Baseline) — schema, validação e controller estão prontos em `main`. Mas captain-hook (o produtor) nunca chegou a publicar esse evento a partir de um `push`: três tentativas de PR ficaram sem merge. Hoje este tópico só carrega eventos com `scope=pr`, implícito. Ver [Decisão §15](../overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--nova) e o `TODO.md` da raiz do monorepo local para o gap detalhado.

### `findings.raw`

**Producer:** moby-dick (após `container.get_archive()` extrair `/tmp/scan.sarif.json` do container do scanner) · **Consumer:** pequod · **Key:** `repo_id` (`gh_<github_repository_id>`)

**Value:** SARIF v2.1.0, já pronto dentro da image do scanner (nenhum dos 4 scanners depende de moby-dick pra gerar o SARIF — ver [Decisão §11](../overview/decisions.md#11-extração-de-findings-dentro-da-scanner-image-status-concluído-não-é-mais-target)).

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

Pequod normaliza em [`Finding v1`](finding-v1.md), dedupa por `(fingerprint, repo_id)`.

### `quality-gate.scanner.completed.v1`

**Producer:** moby-dick · **Consumer:** pequod · **Key:** `repo_full_name`

**Propósito:** fallback assíncrono — o caminho **principal** de avaliação do quality gate hoje é a chamada HTTP síncrona `POST /internal/quality-gates/{workflow_id}/evaluate` (moby-dick → pequod), não este tópico. Ver [Decisão §16](../overview/decisions.md#16-quality-gate-síncrono-via-rest-entre-moby-dick-e-pequod--nova).

### `quality-gate.evaluated.v1`

**Producer:** pequod · **Consumer:** interessados (rede de segurança) · **Propósito:** publicado quando o gate finaliza sem nenhuma chamada HTTP síncrona em andamento (mensagens fora de ordem ou timeout) — não é o caminho principal de decisão.

### Dead-letter queues

Mais numerosas do que uma primeira leitura da arquitetura sugere — confirmadas em `config/settings.py` de moby-dick e pequod:

| DLQ | Serviço | Alimentada por mensagens que falharam em... |
|---|---|---|
| `jobs.orchestration.dlq` | moby-dick | consumo de `jobs.orchestration` |
| `quality-gate.moby-dick.dlq` | moby-dick | consumo de `quality-gate.workflow.started.v1`/`quality-gate.evaluated.v1` |
| `findings.raw.dlq` | pequod | consumo de `findings.raw` |
| `quality-gate.pequod.dlq` | pequod | consumo de `quality-gate.scanner.completed.v1` |
| `repository.registration.pequod.dlq` | pequod | consumo de `repository.registered.v1` |
| `repository.unregistration.pequod.dlq` | pequod | consumo de `repository.unregistered.v1` |

## O que NÃO existe como tópico Kafka (nunca existiu, ou foi só planejado)

- **`github.events.raw`** — uma versão anterior desta página (e do `FLOWCHART.md`/`DECISIONS.md` do monorepo local, ambos já removidos) descrevia esse tópico como "payload bruto do webhook, audit/replay, publicado por captain-hook". **Não existe em nenhum lugar do código** — nenhuma string, setting ou chamada de publish em nenhum dos 5 serviços. Era uma invenção que se propagou pela documentação sem verificação. `controller/webhook_controller.py` do captain-hook só publica os tópicos versionados listados acima; qualquer evento sem handler dedicado é apenas logado e descartado.
- **`findings.created`, `ai.enrichments.triage`, `ai.enrichments.reachability`, `scans.completed`** — previstos numa versão anterior desta página como tópicos futuros. Nunca foram criados — o enriquecimento por IA foi resolvido de outra forma (ver seção abaixo).
- **Notificação de findings críticos:** ainda não existe canal de entrega externo (Slack/email); o modelo `alerts` já existe no pequod, falta o `notifier`.

## Pivô pra REST (enriquecimento por IA)

- **Triagem/clustering por IA:** `tars-ai` faz *polling* REST contra o pequod (`/integrations/tars/pending-findings`, `/pending-clusters`, `/semantic-candidates`) e submete vereditos via REST (`/finding-analyses`, `/cluster-analyses`, `/semantic-clustering-decisions`) — sem tópico Kafka dedicado. Ver [Decisão §17](../overview/decisions.md#17-tars-ai-consome-o-pequod-via-rest-polling-não-via-tópico-kafka-dedicado--nova).
- **Métricas de scan (`scans.completed`):** não existe como tópico; moby-dick e pequod expõem cada um seu próprio `GET /metrics/quality-gate` (não formato Prometheus).

## Convenções de naming

| Padrão | Uso |
|---|---|
| `<domain>.<event>.<state>.v<versão>` | `quality-gate.workflow.started.v1`, `repository.registered.v1` |
| Plural pro domain quando o domínio é uma coleção | `findings.*`, `jobs.*` |
| Versão no nome do tópico (não só no schema) | `.v1` sufixo — diferente da convenção antiga descrita aqui (que previa versão só no `schema_version` do payload) |
| `<topic>.dlq` ou `<domain>.<serviço>.dlq` | dead-letter queue — nomenclatura não é 100% uniforme entre serviços (ex: `jobs.orchestration.dlq` vs `quality-gate.pequod.dlq`) |

## Particionamento

| Topic | Partition key | Razão |
|---|---|---|
| `jobs.orchestration` | `repo_full_name` | ordem por repo |
| `findings.raw` | `repo_id` (`gh_<id>`) | ordem por repo, key estável a rename |
| `repository.registered.v1` / `.unregistered.v1` | `repo_full_name` | ordem por repo |
| `quality-gate.*` | `repo_full_name` | ordem por repo/workflow |

## Replay / reprocessamento

```bash
# Reset consumer group ao início
docker exec aspm-redpanda rpk group seek moby-dick --to start

# OU a um timestamp específico
docker exec aspm-redpanda rpk group seek moby-dick --to-timestamp 1718000000000

# Pra pular acúmulo
docker exec aspm-redpanda rpk group seek moby-dick --to end
```

!!! warning "Cuidado com side effects"
    Reprocessar `jobs.orchestration` vai disparar scans de novo e recriar/atualizar check_runs no GitHub.

## Monitoring

```bash
docker exec aspm-redpanda rpk group describe moby-dick
docker exec aspm-redpanda rpk group describe pequod
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
