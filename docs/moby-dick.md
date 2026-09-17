# Moby-dick

Orquestrador Docker responsável por consumir jobs do Kafka (`jobs.orchestration`), executar scanners em containers efêmeros e publicar results em `findings.raw`. Também materializa o **Quality Gate** — consolidado e por scanner — como `check_run` do GitHub, e mantém uma **Issue** agregada quando o escopo é `branch` (Security Baseline).

## Executando local

```bash
pip install -r requirements.txt
cp .env.example .env
python3 main.py
# servidor em http://localhost:9090
```

## Papel principal

- Consumir `jobs.orchestration` (Kafka) — 1 job por scanner (sonar/semgrep/trivy/zap)
- Criar containers de scanner (Docker SDK) e extrair o SARIF produzido em `${SARIF_OUTPUT_PATH}`
- Publicar `findings.raw` no Kafka
- Criar/atualizar o **check individual** do scanner (`external_id=job_id`, nome vindo de `job.context.callback.name`)
- Consumir `quality-gate.workflow.started.v1` e criar/reconciliar o **check consolidado** (`OdinEye / Quality Gate`, ou `Security Baseline ...` quando `scope=branch`)
- Depois de cada scanner concluir, chamar **sincronamente** o pequod (`POST /api/v1/internal/quality-gates/{workflow_id}/evaluate`) para tentar finalizar o Quality Gate; se finalizado, atualiza o check consolidado imediatamente
- Consumir `quality-gate.evaluated.v1` apenas como **rede de segurança** (fallback) — não é mais o caminho principal de finalização
- Quando `scope=branch` (Security Baseline), fazer upsert de uma Issue agregada por (repo, branch) no repositório alvo (`controller/baseline_sink_controller.py`) — best-effort, não bloqueia a atualização do check_run se falhar. Kill switch: `BASELINE_ISSUE_SINK_ENABLED` (default `true`)
- Expor `GET /metrics/quality-gate` — contadores in-memory (checks criados/reconciliados/completados por decisão, replays ignorados)

!!! note "Confirmado em `main` (reconfirmado 2026-09-10)"
    `baseline_sink_controller.py` e os campos `scope`/`branch_name` em `wire/schemas/quality_gate_v1.py` estão em `main` desde 31/ago/2026 (PR #38), junto com o rollout equivalente em captain-hook e pequod. Ver [Decisão §15](overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10) para o histórico completo (inclui uma verificação que, mais tarde na mesma data, concluiu erroneamente o contrário a partir de refs git locais desatualizadas — já corrigida).

## Execução de um job (`JobConsumer` → scanner → resultado)

Do consumo da mensagem em `jobs.orchestration` até o check individual atualizado no GitHub, passando por assinatura HMAC, DLQ, concorrência limitada e idempotência de execução — nenhuma dessas peças aparecia neste doc antes, embora já estivessem implementadas e documentadas no `README.md` do próprio moby-dick:

```mermaid
sequenceDiagram
    participant K as Kafka (jobs.orchestration)
    participant JC as JobConsumer
    participant DLQ as Kafka (jobs.orchestration.dlq)
    participant PJ as process_job (job_controller)
    participant GH as GitHub API
    participant D as Docker
    participant K2 as Kafka (findings.raw /<br/>scanner.completed.v1)
    participant PQ as Pequod (HTTP síncrono)

    K->>JC: mensagem (job_id, image, command, env, callback)
    JC->>JC: adquire semaphore<br/>(até SCANNER_MAX_CONCURRENCY jobs em paralelo,<br/>mesmo com 1 partição só — ANTES de decodificar/validar a mensagem)
    JC->>JC: decode_json_value + verify_signed_message<br/>(HMAC x-odineye-signature-v1, timestamp anti-replay,<br/>producer esperado = captain-hook)

    alt assinatura ou schema inválidos
        JC->>DLQ: publish_dlq(error_kind=message_rejected)
        Note over JC: offset commitado — mensagem já foi<br/>tratada (rejeitada), não fica "presa"
    else mensagem válida
        JC->>PJ: handler(job) — em task própria

        PJ->>PJ: lock asyncio por job_id +<br/>checa cache de jobs já completados (replay local?)

        alt job_id já materializado nesta instância
            PJ-->>JC: retorna sem reprocessar
        else
            PJ->>GH: find_or_create_check (external_id=job_id)
            alt check individual já "completed"
                PJ-->>JC: retorna (replay ignorado)
            else
                PJ->>GH: get_installation_token (GitHub App)
                PJ->>D: run(image, command, env+GIT_TOKEN, volumes?)
                D-->>PJ: exit_code, logs, SARIF<br/>(arquivo via get_archive; se ausente,<br/>fallback por markers no stdout)
                PJ->>K2: publish findings.raw<br/>(retry local — nunca rereoda o container)
                Note over PJ: pertence a Quality Gate + sem SARIF e sem erro<br/>explícito → vira falha (sarif_missing)
                opt job pertence a um Quality Gate
                    PJ->>K2: publish quality-gate.scanner.completed.v1<br/>(mesmo retry local)
                end
                PJ->>GH: update_check_run (check individual, completed)
                opt job pertence a um Quality Gate
                    PJ->>PQ: POST /internal/quality-gates/{workflow_id}/evaluate
                    alt ready=true e ainda não finalizado
                        PQ-->>PJ: QualityGateEvaluatedEvent
                        PJ->>GH: update_check_run (check consolidado)<br/>+ upsert Issue de baseline se scope=branch
                    else já finalizado por outro scanner (already_finalized)
                        Note over PJ: replay ignorado — sem atualização redundante
                    else ready=false ou Pequod indisponível/5xx
                        Note over PJ: nada a fazer agora — próximo scanner que<br/>terminar tenta de novo, ou o consumer de<br/>quality-gate.evaluated.v1, como fallback, cobre
                    end
                end
                PJ->>PJ: marca job_id como completado<br/>(cache local, limite 4096)
            end
        end

        alt handler propagou exceção não tratada
            JC->>DLQ: publish_dlq(error_kind=handler_failed)
        end

        PJ-->>JC: retorna
        JC->>JC: libera semaphore
        JC->>K: commit offset — só quando todos os offsets<br/>anteriores da mesma partição também terminaram
    end
```

Dois detalhes que não aparecem no diagrama mas mudam o comportamento em produção:

- **Assinatura HMAC** é obrigatória por padrão (`KAFKA_REQUIRE_SIGNATURE=true`); sem `KAFKA_MESSAGE_SECRET` configurado igual nos dois lados (captain-hook produzindo, moby-dick consumindo), toda mensagem cai em DLQ por `message_rejected`.
- **Idempotência tem duas camadas**: o lock/cache de `job_id` evita reprocessar dentro da mesma instância (redelivery do Kafka), e o `external_id=job_id` no check run do GitHub evita duplicar checks mesmo que uma segunda instância do moby-dick processe a mesma mensagem.
- **O semaphore de concorrência é adquirido antes de qualquer validação** — uma mensagem malformada ou com assinatura inválida também ocupa uma vaga de `SCANNER_MAX_CONCURRENCY` até a rejeição terminar, não é filtrada antes.
- **Se publicar `findings.raw` ou `quality-gate.scanner.completed.v1` falhar depois de esgotar os retries**, a exceção propaga pro `JobConsumer`, que trata como `handler_failed` e manda pro DLQ — mesmo que o scanner tenha rodado com sucesso. Nesse caso raro, o offset só não commita se o próprio `publish_dlq` também falhar (preserva at-least-once).

## Subsistema de Quality Gate

Diferente do desenho original (aguardar `quality-gate.evaluated.v1` via Kafka de ponta a ponta), hoje o Moby Dick chama o **pequod diretamente por HTTP** depois de publicar cada `quality-gate.scanner.completed.v1`, evitando ficar preso esperando um evento que pode se perder em caso de instabilidade do broker:

```mermaid
sequenceDiagram
    participant MD as moby-dick (job_controller)
    participant K as Kafka
    participant PQ as pequod (HTTP síncrono)
    participant GH as GitHub API

    MD->>K: publish quality-gate.scanner.completed.v1
    MD->>PQ: POST /api/v1/internal/quality-gates/{workflow_id}/evaluate
    alt Pequod pronto para finalizar (ready=true)
        PQ-->>MD: event=QualityGateEvaluatedEvent
        MD->>GH: update_check_run (check consolidado, completed)
    else scanners ainda pendentes (ready=false)
        PQ-->>MD: sem event
        Note over MD: nada a fazer — próximo scanner que terminar tenta de novo
    else Pequod indisponível / 5xx / 404
        Note over MD: erro é logado como warning e engolido;<br/>consumer de quality-gate.evaluated.v1, como fallback, cobre o caso raro
    end
```

Dois consumers Kafka distintos rodam dentro do `moby-dick`:

| Consumer | Consumer group | Tópicos assinados | Papel |
|---|---|---|---|
| `JobConsumer` | `moby-dick` | `jobs.orchestration` | executa scanners, publica `findings.raw` + `quality-gate.scanner.completed.v1` |
| `QualityGateConsumer` | `moby-dick-quality-gate` | `quality-gate.workflow.started.v1`, `quality-gate.evaluated.v1` | cria/reconcilia o check consolidado (`workflow.started`) e cobre a finalização como fallback (`evaluated`); dispara o sink de Issue quando `scope=branch` |

Cliente HTTP: `diplomat/http_out/pequod_client.py` (`PequodClient.evaluate_quality_gate`), com retry exponencial (`PEQUOD_API_MAX_ATTEMPTS`/`PEQUOD_API_RETRY_BASE_SECONDS`) em 429/5xx/erro de conexão; `404` (workflow_id desconhecido no pequod) não é retryable e levanta `PequodClientError` direto.

## Security Baseline (`scope=branch`)

Quando `process_quality_gate_evaluated` recebe um evento com `scope="branch"`, além de atualizar o check_run (criado no commit, não num PR), chama `baseline_sink_controller.upsert_baseline_issue`: busca por label estável (`aspm-baseline:<branch>`) via `GitHubClient.find_issue_by_label`, cria a Issue se não existir ou atualiza o corpo/labels se existir. Só reabre uma Issue fechada manualmente pelo dev quando o baseline atual reprova (`failed`/`error`) — uma regressão real. Kill switch: `BASELINE_ISSUE_SINK_ENABLED` (default `true`, sem env var dedicada em `.env.example` hoje).

## Scanners suportados

4 scanner images vivem em `deploy/`, todas seguindo o mesmo contrato (§11 do `aspm-docs`: escrever SARIF v2.1.0 em `${SARIF_OUTPUT_PATH}`, exit code é o veredito, `unset GIT_TOKEN` antes de rodar código de terceiros clonado):

| Pasta | Scanner | Categoria | Habilitado via (captain-hook) |
|---|---|---|---|
| `deploy/sonar-runner/` | SonarQube | SAST (+ Quality Gate de projeto) | sempre ativo |
| `deploy/semgrep-runner/` | Semgrep | SAST | `ENABLE_SEMGREP_SCAN` |
| `deploy/trivy-runner/` | Trivy | SCA + misconfig (`TRIVY_SCANNERS=vuln,misconfig`) | `ENABLE_TRIVY_SCAN` |
| `deploy/zap-runner/` | OWASP ZAP | DAST | `ENABLE_ZAP_SCAN` + `DAST_MODE` |

`DAST_MODE` tem dois valores possíveis no env do job do ZAP:

- `fixed_url` — escaneia `TARGET_URL`, uma URL que já está no ar (sem clone).
- `compose_preview` — clona o repo do PR/branch, sobe `docker-compose.aspm.yml` (`DAST_SERVICE_NAME`/`DAST_TARGET_PORT`/`DAST_HEALTH_PATH`) e escaneia a preview. Exige `MOBY_MOUNT_DOCKER_SOCKET=true` no env do `JobDescriptor` — o `moby-dick` só monta `/var/run/docker.sock` no container quando esse flag vem explícito (`controller/job_controller.py::_runner_volumes`), privilégio equivalente a root no host. Usar só com repositórios confiáveis.

Cada scanner, ao terminar, faz o `moby-dick` publicar um `quality-gate.scanner.completed.v1` com `scanner_class` resolvido em `_SCANNER_CLASS_BY_SCANNER` (`sonar`→`sast`, `semgrep`→`sast`, `trivy`→`sca`, `zap`→`dast`).

## Como o SARIF chega no check_run

`adapter/sarif_to_check_run.py::build_output` traduz o SARIF v2.1.0 (comum aos 4 scanners) no `output` do check_run: anotações inline para findings com `path` dentro do repositório (até 50, teto do GitHub) e markdown para findings sem path real (típico do DAST, que reporta URL).

## Links

- README completo: ../moby-dick/README.md
- Arquitetura: ../overview/architecture.md
- Check run consolidado + individual: ../integration/check-run.md
- JobDescriptor: ../reference/job-descriptor.md

## Fluxo de dados

```mermaid
flowchart LR
  GH[GitHub PR / push]
  CH[captain-hook]
  K[(Kafka/Redpanda)]
  MD[moby-dick]
  SR["Scanner container<br/>(sonar / semgrep / trivy / zap)"]
  PQ[pequod]

  GH -->|webhook| CH
  CH -->|publish jobs.orchestration N jobs + workflow.started| K
  K -->|consume jobs.orchestration| MD
  MD -->|docker run, extrai SARIF| SR
  SR -->|SARIF| MD
  MD -->|publish findings.raw + scanner.completed| K
  MD -->|POST evaluate quality-gate síncrono| PQ
  PQ -->|ready=true: QualityGateEvaluatedEvent| MD
  MD -->|update check_run consolidado + individual| GH
  MD -->|upsert Issue de baseline (scope=branch)| GH
  K -->|consume evaluated fallback| MD
```

![Fluxo de dados — Moby-dick](assets/moby-dick-flow.svg)
