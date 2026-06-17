# Endpoints HTTP

Catálogo dos endpoints expostos por cada serviço. Onde aplicável, link pro Swagger nativo do FastAPI.

## captain-hook (porta 8080)

### `POST /webhook`

**Função:** receber webhooks do GitHub.

**Headers esperados:**

| Header | Obrigatório | Uso |
|---|---|---|
| `X-GitHub-Event` | sim | `pull_request`, `ping`, etc |
| `X-GitHub-Delivery` | sim | UUID único do delivery |
| `X-Hub-Signature-256` | sim | HMAC-SHA256 do payload com `GITHUB_WEBHOOK_SECRET` |
| `Content-Type` | sim | `application/json` |

**Body:** payload JSON do GitHub (varia por event).

**Responses:**

| Status | Quando |
|---|---|
| `202 Accepted` | Webhook aceito, publicado em Kafka |
| `401 Unauthorized` | HMAC inválido |
| `400 Bad Request` | Body malformado |
| `500 Internal Server Error` | Falha ao publicar em Kafka (raro) |

**Side effects:**

1. Publica em `github.events.raw` (sempre)
2. Se for `pull_request.{opened,synchronize,reopened}`, publica também em `jobs.orchestration`

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

Sempre 200. Não checa dependências (Kafka). Pra readiness real, expandir no futuro.

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

### Background consumer

moby-dick **não** expõe endpoint de scan (não há "POST /scan"). Toda atividade é triggered por consumo de `jobs.orchestration`.

### Swagger UI

http://localhost:9090/docs — só `/health` por enquanto. Endpoints HTTP adicionais virão se decidirmos expor API de listagem de jobs em execução.

## SonarQube (porta 9000) — referência externa

Não fazemos chamadas custom — usamos só sonar-scanner CLI. Mas vale documentar endpoints úteis pra bootstrap e debug.

### `GET /api/system/status`

**Função:** healthcheck.

**Response:**
```json
{"id":"...","version":"12.37.0.3460","status":"UP"}
```

`status` possíveis: `STARTING`, `UP`, `DOWN`, `RESTARTING`, `DB_MIGRATION_NEEDED`, `DB_MIGRATION_RUNNING`.

### `POST /api/users/change_password`

**Function:** trocar senha (necessário no primeiro login com admin/admin).

**Auth:** Basic Auth.

**Body (form-urlencoded):**
- `login=admin`
- `previousPassword=admin`
- `password=<nova>`

### `POST /api/user_tokens/generate`

**Function:** gerar token de análise.

**Auth:** Basic Auth.

**Body (form-urlencoded):**
- `name=<nome>`
- `type=GLOBAL_ANALYSIS_TOKEN`

**Response:**
```json
{"login":"admin","name":"...","token":"sqa_xxxxxxxx","createdAt":"...","type":"GLOBAL_ANALYSIS_TOKEN"}
```

### `POST /api/projects/create`

**Function:** criar projeto manualmente (Community Build não auto-cria).

**Auth:** Basic Auth.

**Body:**
- `name=<display name>`
- `project=<project key>`

### `GET /api/projects/search`

**Function:** listar/buscar projetos.

**Query:** `q=<search>` (opcional).

### `GET /api/qualitygates/project_status`

**Function:** consultar status do QG.

**Query:**
- `projectKey=<key>`
- `pullRequest=<n>` (opcional, só funciona em Developer Edition+)

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

**Function:** trocar JWT por installation token.

**Auth:** JWT no header `Authorization: Bearer <jwt>`.

**Response:**
```json
{"token":"ghs_xxx","expires_at":"2026-06-17T16:45:00Z","permissions":{...}}
```

### `POST /repos/{owner}/{repo}/check-runs`

**Function:** criar check_run no PR.

**Auth:** installation token.

**Body:**
```json
{
  "name": "SonarQube Scan",
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

**Function:** atualizar check_run com resultado.

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

### findings-api (futuro)

| Endpoint | Função |
|---|---|
| `GET /findings` | listar findings com filtros |
| `GET /findings/{id}` | detalhe |
| `PATCH /findings/{id}` | triagem (false positive, accepted, fixed) |
| `GET /findings/{id}/sarif` | SARIF cru |
| `GET /repos/{repo}/summary` | métricas agregadas |
| `POST /findings/import` | importar SARIF manualmente |

### policy-engine (futuro)

| Endpoint | Função |
|---|---|
| `GET /policies` | listar políticas ativas |
| `POST /policies/evaluate` | testar uma policy contra um job hipotético |

Quando esses serviços nascerem, esta página será atualizada.
