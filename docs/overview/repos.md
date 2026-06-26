# Repositórios

## Mapa rápido

| Repo | Função | Stack | Estado |
|---|---|---|---|
| [`captain-hook`](https://github.com/OdinEye-FIAP/captain-hook) | Ingest de webhook GitHub → publica jobs no Kafka | FastAPI + aiokafka | ✅ ativo |
| [`moby-dick`](https://github.com/OdinEye-FIAP/moby-dick) | Consumer Kafka → spawna container scanner → extrai SARIF → publica `findings.raw` → reporta check_run | FastAPI + Docker SDK + PyJWT | ✅ ativo |
| [`pequod`](https://github.com/OdinEye-FIAP/pequod) | Consumer `findings.raw` → normaliza SARIF → upsert por fingerprint → REST | FastAPI + aiokafka + asyncpg | ✅ ativo |
| [`clint-eastwood`](https://github.com/OdinEye-FIAP/clint-eastwood) | Repo de teste/demo com código intencionalmente vulnerável | JS | 🧪 demo |
| [`aspm-docs`](https://github.com/OdinEye-FIAP/aspm-docs) | Esta documentação | MkDocs Material | 📚 doc |

## captain-hook

**Papel:** ponto de entrada do GitHub no pipeline.

**Responsabilidades:**

- Receber webhooks do GitHub (`POST /webhook`)
- Validar HMAC do webhook (`GITHUB_WEBHOOK_SECRET`)
- Publicar o evento bruto em `github.events.raw` (audit/replay)
- Traduzir `pull_request.{opened,synchronize,reopened}` em `JobDescriptor v1`
- Publicar o job em `jobs.orchestration`

**O que NÃO faz:**

- Não conhece Docker
- Não conhece scanners
- Não tem credenciais da GitHub App
- Não responde quando o scan termina

**Entry:** `main.py` → FastAPI app.

**Settings principais:**

```env
GITHUB_WEBHOOK_SECRET=...
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
SONAR_HOST_URL=http://aspm-sonarqube:9000
SONAR_TOKEN=<global analysis token>
DEFAULT_JOB_IMAGE=aspm-sonar-runner:latest
```

## moby-dick

**Papel:** orquestrador da execução + extrator de findings.

**Responsabilidades:**

- Consumir `jobs.orchestration` do Kafka
- Mintar `installation_token` via GitHub App (JWT → access_tokens)
- Criar `check_run` no PR com status `in_progress`
- Mesclar `GIT_TOKEN` no env do container
- Rodar container Docker da image especificada no `JobDescriptor`
- Coletar exit code + logs
- Após scan: chamar `GET /api/issues/search` na Sonar API, converter para SARIF v2.1.0 e publicar em `findings.raw`
- Atualizar `check_run` com `conclusion=success/failure`

**O que NÃO faz:**

- Não persiste findings (delega ao `pequod`)
- Não normaliza SARIF em entidade de domínio (delega ao `pequod`)
- Não conhece schema do banco do pequod

**Entry:** `main.py` → FastAPI + background consumer loop.

**Settings principais:**

```env
GITHUB_APP_ID=...
GITHUB_APP_PRIVATE_KEY_PATH=./config/github-app-private-key.pem
GITHUB_INSTALLATION_ID=...
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
DOCKER_NETWORK=aspm-net
DOCKER_RUN_TIMEOUT_SECONDS=600
SONAR_HOST_URL=http://aspm-sonarqube:9000
SONAR_TOKEN=<global analysis token>
SONAR_API_TIMEOUT_SECONDS=30
TOPIC_FINDINGS_RAW=findings.raw
```

**Pastas-chave:**

- `controller/job_controller.py` — fluxo de processamento de job + publicação de findings
- `adapter/sonar/issues_to_sarif.py` — Sonar API → SARIF v2.1.0
- `diplomat/http_out/github_client.py` — GitHub App API client
- `diplomat/runner/docker_runner.py` — Docker SDK wrapper
- `diplomat/messaging/kafka_consumer.py` — consumer Kafka (`jobs.orchestration`)
- `diplomat/messaging/kafka_producer.py` — producer Kafka (`findings.raw`)
- `deploy/sonar-runner/` — Dockerfile + entrypoint do scanner

## pequod

**Papel:** camada de persistência de findings normalizados.

**Responsabilidades:**

- Consumir `findings.raw` do Kafka
- Parsear SARIF v2.1.0 → entidade `Finding`
- Calcular `fingerprint` SHA-256 determinístico (scanner + rule + repo + file + line + snippet)
- Upsert idempotente `ON CONFLICT (fingerprint, repo)` — atualiza `last_seen_at` + ref/severity/message
- Expor REST: `GET /findings` (filtros por repo/severity/status), `GET /findings/{id}`, `PATCH /findings/{id}` (triage)

**O que NÃO faz:**

- Não chama scanners (consumer puro de evento)
- Não decide policy / quality gate (responsabilidade de moby-dick + Sonar)
- Não enriquece com IA (fica em serviço separado quando entrar)

**Entry:** `main.py` → FastAPI + lifespan (DB pool + Kafka consumer).

**Settings principais:**

```env
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_CONSUMER_GROUP=pequod
TOPIC_FINDINGS_RAW=findings.raw
DATABASE_URL=postgresql://pequod:pequod@localhost:5433/pequod
```

**Pastas-chave:**

- `controller/ingest_controller.py` — orquestração da ingestão
- `controller/query_controller.py` — orquestração das queries REST
- `adapter/sarif/sarif_to_finding.py` — parser SARIF tolerante
- `model/finding.py` — entidade + `compute_fingerprint`
- `diplomat/db/finding_repo.py` — SQL puro (asyncpg, sem ORM)
- `diplomat/db/pool.py` — pool asyncpg
- `diplomat/messaging/kafka_consumer.py` — consumer Kafka
- `deploy/migrations/001_init.sql` — schema inicial

## clint-eastwood

**Papel:** repo de demonstração.

Contém arquivos com vulnerabilidades intencionais (`security-issues.js`, `code-smells.js`, `sonarqube-demo.js`) pra validar que o pipeline detecta findings de:

- Hardcoded credentials
- SQL/Command injection
- Weak cryptography (MD5, DES)
- Hotspots de regex / Math.random / HTTP
- Bugs (NaN compare, dead code)
- Code smells (cognitive complexity, magic numbers, `==`, console.log)

Cada bloco anotado com a regra Sonar correspondente.

**Não é parte da plataforma.** É um repo onboardado pra validação. Outros repos onboardados seguem o mesmo padrão de integração.

## aspm-docs

**Papel:** documentação central (este site).

**Estrutura:**

```
docs/
├── index.md              # landing
├── overview/             # stakeholder
├── developer/            # você + time
├── integration/          # devs onboardando seus repos
└── reference/            # schemas + APIs
```

**Deploy:** push em `main` → GitHub Actions → GitHub Pages.

## Convenções entre repos

- **Branches feat:** `feat/<scope>`, `fix/<scope>`, `docs/<scope>`
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`)
- **Tags:** semver futuramente
- **Releases:** sem release formal por enquanto — deploy é via `git pull` + `systemctl restart` na VPS
- **Schemas compartilhados:** copiados entre captain-hook/moby-dick por enquanto. Quando virar pacote pip (`aspm-wire`), vai ser source-of-truth único.

## Componentes futuros previstos

| Nome candidato | Função | Stack provável |
|---|---|---|
| `policy-engine` | Decide quais scanners rodar por repo/PR (`.aspm.yml`) | Python + YAML config |
| `ai-triage` | Classifica findings via LLM (false-positive, severity ajustada) | Python + Anthropic SDK |
| `correlation-service` | Embeddings + grafo cross-scanner | Python + pgvector |
| `findings-ui` | UI Web pra triagem manual | Next.js ou Streamlit |
| `notifier` | Posta findings críticos em Slack/email | Python |

Os papéis de `findings-ingestor` e `findings-api` foram absorvidos pelo [`pequod`](https://github.com/OdinEye-FIAP/pequod). Os outros serão criados conforme o roadmap avança.
