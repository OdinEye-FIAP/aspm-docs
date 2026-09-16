# Endpoints HTTP

Catálogo dos endpoints expostos por cada serviço. Onde aplicável, link pro Swagger nativo do FastAPI.

## captain-hook (porta 8080)

### `POST /webhook`

**Função:** receber webhooks do GitHub (`pull_request`, `push`, `ping`, `installation`, `installation_repositories`).

**Headers esperados:**

| Header | Obrigatório | Uso |
|---|---|---|
| `X-GitHub-Event` | sim | `pull_request`, `push`, `ping`, `installation`, `installation_repositories` |
| `X-GitHub-Delivery` | sim | UUID único do delivery |
| `X-Hub-Signature-256` | sim | HMAC-SHA256 do payload com `GITHUB_WEBHOOK_SECRET` |
| `Content-Type` | sim | `application/json` |

**Body:** payload JSON do GitHub (varia por event).

**Responses:**

| Status | Quando |
|---|---|
| `202 Accepted` | Webhook aceito (mesmo status pra todo event_type — processamento real acontece depois, em `background_tasks` pra `ping`/`installation`/`installation_repositories`) |
| `401 Unauthorized` | HMAC inválido |
| `400 Bad Request` | Body malformado |
| `422 Unprocessable Entity` | Payload não bate com o contrato esperado |
| `500 Internal Server Error` | Falha ao publicar em Kafka (raro) |

**Side effects (por `event_type`):**

1. `pull_request.{opened,synchronize,reopened}`: publica jobs em `jobs.orchestration` (`scope=pr`) — um por scanner habilitado
2. `push` na default branch: publica jobs em `jobs.orchestration` (`scope=branch`, Security Baseline)
3. `ping` (payload utilizável) ou `installation`/`installation_repositories` (`action=created`/`added`): registra o repositório no pequod via REST (`POST /internal/repositories/register`), dispara o mesmo Security Baseline do item 2 e, se `ENABLE_REPO_SCAFFOLD_PR`, o auto-scaffold — tudo em `background_tasks`, pela pipeline compartilhada `onboard_repository` (ver [captain-hook.md](../captain-hook.md))
4. `installation`/`installation_repositories` (`action=deleted`/`removed`): desregistra via REST (`POST /internal/repositories/unregister`) — sem baseline nem scaffold

**Exemplo:**

```bash
curl -X POST http://localhost:8080/webhook \
  -H "X-GitHub-Event: pull_request" \
  -H "X-GitHub-Delivery: $(uuidgen)" \
  -H "X-Hub-Signature-256: sha256=<calculado>" \
  -H "Content-Type: application/json" \
  -d @sample-pr-payload.json
```

### `GET /health`

**Função:** liveness probe.

**Response:**

```json
{"status": "ok"}
```

### `GET /repos/{owner}/{repo}/live-info`

**Função:** issues abertas e dependências ao vivo de um repositório (usado pelo heimdall-dashboard). Requer CORS liberado via `CORS_ALLOWED_ORIGINS`.

### `POST /repos/{owner}/{repo}/scaffold-pr`

**Função:** dispara manualmente a abertura do PR de onboarding (scaffold) para um repositório, sem esperar o evento automático de `installation`.

### Swagger UI

http://localhost:8080/docs — FastAPI auto-gera. Mostra OpenAPI spec com schemas Pydantic.

http://localhost:8080/openapi.json — spec cru.

## moby-dick (porta 9090)

### `GET /health`

**Função:** liveness probe.

**Response:**

```json
{"status": "ok"}
```

### `GET /metrics/quality-gate`

**Função:** snapshot de métricas do orquestrador do Quality Gate (não é formato Prometheus).

### Background consumers

moby-dick **não** expõe endpoint de scan (não há "POST /scan"). Toda atividade é triggered por consumo de `jobs.orchestration` (scan) e `quality-gate.scanner.completed.v1` (fallback assíncrono do quality gate) — o caminho principal do quality gate é a chamada síncrona que o próprio moby-dick faz ao pequod (`POST /internal/quality-gates/{workflow_id}/evaluate`), não um endpoint que moby-dick expõe.

### Swagger UI

http://localhost:9090/docs

## pequod (porta 7070)

Prefixo versionado: `/api/v1`. Rotas legadas (`/findings*`) e as de integração service-to-service (`/integrations/tars/*`, `/internal/quality-gates/*`) não usam esse prefixo.

### `GET /health`

**Função:** liveness + readiness (checa DB).

**Response:**

```json
{"status": "ok", "db": "ok"}
```

### `GET /metrics/quality-gate`

**Função:** snapshot de métricas do orquestrador do Quality Gate.

### Findings (legado — mantido por compatibilidade)

| Método | Path | Função |
|---|---|---|
| `GET` | `/findings` | lista paginada (filtros: `repo`, `repo_id`, `severity`, `status`) |
| `GET` | `/findings/{finding_id}` | detalhe (recompõe `sarif_raw` a partir da ocorrência mais recente em `finding_occurrences`) |
| `PATCH` | `/findings/{finding_id}` | atualiza `status` (`open`/`triaged_fp`/`fixed`/`wontfix`) |

### Organizations / Applications / Scans

| Método | Path |
|---|---|
| `GET` | `/api/v1/organizations` |
| `GET` | `/api/v1/applications` |
| `GET` | `/api/v1/applications/{application_id}` |
| `GET` | `/api/v1/applications/{application_id}/scans` |
| `GET` | `/api/v1/scans/{scan_id}` |

### Risk Exceptions

| Método | Path |
|---|---|
| `GET` | `/api/v1/risk-exceptions` |
| `POST` | `/api/v1/risk-exceptions` |
| `POST` | `/api/v1/risk-exceptions/expire` |
| `GET` | `/api/v1/risk-exceptions/{exception_id}` |
| `POST` | `/api/v1/risk-exceptions/{exception_id}/revoke` |

### Alerts

| Método | Path |
|---|---|
| `GET` | `/api/v1/alerts` |
| `GET` | `/api/v1/alerts/{alert_id}` |

### Audit Log

| Método | Path |
|---|---|
| `GET` | `/api/v1/audit-logs` |
| `GET` | `/api/v1/audit-logs/{audit_log_id}` |

### Security Gate

| Método | Path |
|---|---|
| `GET` | `/api/v1/security-gate/policies` |
| `POST` | `/api/v1/security-gate/policies` |
| `GET` | `/api/v1/security-gate/policies/effective` |
| `GET` | `/api/v1/security-gate/evaluations` |
| `POST` | `/api/v1/security-gate/evaluations` |
| `GET` | `/api/v1/security-gate/evaluations/{evaluation_id}` |

### Consolidated Risks

| Método | Path |
|---|---|
| `GET` | `/api/v1/consolidated-risks` |
| `GET` | `/api/v1/consolidated-risks/{risk_id}` |

### Quality Gates

| Método | Path | Função |
|---|---|---|
| `GET` | `/api/v1/quality-gates` | lista runs |
| `GET` | `/api/v1/quality-gates/by-pr` | resolve o run mais recente por `application_id`+`pull_request_number` |
| `GET` | `/api/v1/quality-gates/{workflow_id}` | detalhe completo (run, scanners, evaluation, policy, items, risk exceptions) |

### `/integrations/tars/*` (service-to-service, header `X-Service-Token`)

| Método | Path |
|---|---|
| `GET` | `/integrations/tars/capabilities` |
| `GET` | `/integrations/tars/pending-findings` |
| `POST` | `/integrations/tars/finding-analyses` |
| `GET` | `/integrations/tars/pending-clusters` |
| `POST` | `/integrations/tars/cluster-analyses` |
| `GET` | `/integrations/tars/semantic-candidates` |
| `POST` | `/integrations/tars/semantic-clustering-decisions` |

### `/internal/quality-gates/*` (service-to-service, header `X-Service-Token`)

| Método | Path | Função |
|---|---|---|
| `POST` | `/internal/quality-gates/{workflow_id}/evaluate` | chamado pelo moby-dick a cada scanner concluído; resposta síncrona `{ready, event}` (idempotente) |

### Swagger UI

http://localhost:7070/docs

## tars-ai (porta 6060)

Dois grupos de rotas coexistem no mesmo processo: as legadas (`/ai/*`, acesso direto ao banco do pequod) e as de integração REST (`/integrations/pequod/*`, sem acesso direto ao banco — controladas por `TARS_PEQUOD_INTEGRATION_ENABLED`).

### `GET /health`

```json
{"status": "ok", "service": "tars_ai", "ai_provider": "gemini", "auto_analyze_enabled": true, "auto_analyze_interval_seconds": 60}
```

### Legado (`/ai/*`)

| Método | Path | Função |
|---|---|---|
| `GET` | `/ai/pending` | findings pendentes de análise |
| `GET` | `/ai/pending-refs` | grupos `repo`/`ref` com pendências |
| `POST` | `/ai/analyze-pending` | analisa findings pendentes |
| `POST` | `/ai/analyze-ref` | analisa findings pendentes de um `repo`+`ref` |
| `POST` | `/ai/analyze/{finding_id}` | analisa um finding específico |
| `GET` | `/ai/analyses` | lista análises individuais |
| `GET` | `/ai/stats` | totais ingeridos vs. enriquecidos |
| `POST` | `/ai/clusterize-pending` | clustering determinístico legado |
| `GET` | `/ai/clusters` / `/ai/clusters/{cluster_id}` | lista/detalhe de clusters |
| `POST` | `/ai/analyze-clusters` | analisa clusters pendentes |
| `GET` | `/ai/cluster-analyses` | lista análises de clusters |

### Integração REST (`/integrations/pequod/*`)

| Método | Path | Função |
|---|---|---|
| `GET` | `/integrations/pequod/health` | healthcheck do pequod + provider ativo |
| `POST` | `/integrations/pequod/analyze-findings` | busca `pending-findings` no pequod e submete `finding-analyses` |
| `POST` | `/integrations/pequod/analyze-clusters` | busca `pending-clusters` no pequod e submete `cluster-analyses` |
| `POST` | `/integrations/pequod/run` | ciclo completo (findings + clustering semântico); `409` se a integração estiver desabilitada |

### Swagger UI

http://localhost:6060/docs

## SonarQube (porta 9000) — referência externa

Não fazemos chamadas custom de aplicação — apenas o `sonar-runner` chama a API do Sonar (dentro da própria image, ver [Decisão §11](../overview/decisions.md#7-modo-de-scan-análise-principal-sem-pr-mode)) pra extrair issues e converter em SARIF. Vale documentar endpoints úteis pra bootstrap e debug.

### `GET /api/system/status`

**Função:** healthcheck.

**Response:**
```json
{"id":"...","version":"12.37.0.3460","status":"UP"}
```

`status` possíveis: `STARTING`, `UP`, `DOWN`, `RESTARTING`, `DB_MIGRATION_NEEDED`, `DB_MIGRATION_RUNNING`.

### `POST /api/users/change_password`

**Função:** trocar senha (necessário no primeiro login com admin/admin).

**Auth:** Basic Auth.

**Body (form-urlencoded):**
- `login=admin`
- `previousPassword=********
- `password=********

### `POST /api/user_tokens/generate`

**Função:** gerar token de análise.

**Auth:** Basic Auth.

**Body (form-urlencoded):**
- `name=<nome>`
- `type=GLOBAL_ANALYSIS_TOKEN`

**Response:**
```json
{"login":"admin","name":"...","token":"********","createdAt":"...","type":"GLOBAL_ANALYSIS_TOKEN"}
```

### `POST /api/projects/create`

**Função:** criar projeto manualmente (Community Build não auto-cria).

**Auth:** Basic Auth.

**Body:**
- `name=<display name>`
- `project=<project key>`

### `GET /api/projects/search`

**Função:** listar/buscar projetos.

**Query:** `q=<search>` (opcional).

### `GET /api/qualitygates/project_status`

**Função:** consultar status do QG.

**Query:**
- `projectKey=<key>`

!!! warning "PR mode não funciona no Community Build"
    O parâmetro `pullRequest=<n>` só funciona em SonarQube Developer Edition+. Community Build não suporta `sonar.pullrequest.*`/`sonar.branch.*` — ver [Decisão §7](../overview/decisions.md#7-modo-de-scan-análise-principal-sem-pr-mode). O `sonar-runner` roda sem essas flags por padrão (`SONAR_PR_MODE=disabled`).

**Response:**
```json
{
  "projectStatus": {
    "status": "OK",
    "conditions": [
      {"metricKey": "new_security_rating", "status": "OK", ...}
    ]
  }
}
```

## GitHub App API (externa) — endpoints usados

Reference: https://docs.github.com/en/rest

### `POST /app/installations/{id}/access_tokens`

**Função:** trocar JWT por installation token.

**Auth:** JWT no header `Authorization: Bearer <jwt>`.

**Response:**
```json
{"token":"ghs_xxx","expires_at":"2026-06-17T16:45:00Z","permissions":{...}}
```

### `POST /repos/{owner}/{repo}/check-runs`

**Função:** criar check_run no PR (nome real: "OdinEye / Quality Gate").

**Auth:** installation token.

**Body:**
```json
{
  "name": "OdinEye / Quality Gate",
  "head_sha": "<sha>",
  "status": "in_progress",
  "output": {
    "title": "...",
    "summary": "...",
    "text": "..."
  }
}
```

### `PATCH /repos/{owner}/{repo}/check-runs/{id}`

**Função:** atualizar check_run com resultado.

**Body:**
```json
{
  "status": "completed",
  "conclusion": "success",
  "output": {...}
}
```

`conclusion`: `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`, `action_required`.

## Redpanda Admin (porta 9644)

Não usamos direto na aplicação — só pra debug via CLI:

```bash
docker exec aspm-redpanda rpk cluster info
docker exec aspm-redpanda rpk topic list
docker exec aspm-redpanda rpk group describe moby-dick
```

## Endpoints futuros previstos

Nenhuma evolução planejada documentada no momento. As entradas antigas desta seção (`GET /findings/{id}/sarif`, `GET /repos/{repo}/summary`, `POST /findings/import`, `GET /findings/{id}/history`, endpoints de policy-engine, endpoints de ai-triage) já foram implementadas — ver as seções [pequod](#pequod-porta-7070) e [tars-ai](#tars-ai-porta-6060) acima.
