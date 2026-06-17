# Repositórios

## Mapa rápido

| Repo | Função | Stack | Estado |
|---|---|---|---|
| [`captain-hook`](https://github.com/OdinEye-FIAP/captain-hook) | Ingest de webhook GitHub → publica jobs no Kafka | FastAPI + aiokafka | ✅ ativo |
| [`moby-dick`](https://github.com/OdinEye-FIAP/moby-dick) | Consumer Kafka → spawna container scanner → reporta check_run | FastAPI + Docker SDK + PyJWT | ✅ ativo |
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

**Papel:** orquestrador da execução.

**Responsabilidades:**

- Consumir `jobs.orchestration` do Kafka
- Mintar `installation_token` via GitHub App (JWT → access_tokens)
- Criar `check_run` no PR com status `in_progress`
- Mesclar `GIT_TOKEN` no env do container
- Rodar container Docker da image especificada no `JobDescriptor`
- Coletar exit code + logs
- Atualizar `check_run` com `conclusion=success/failure`

**O que NÃO faz:**

- Não conhece SonarQube especificamente
- Não conhece o conteúdo do scan
- Não persiste findings

**Entry:** `main.py` → FastAPI + background consumer loop.

**Settings principais:**

```env
GITHUB_APP_ID=...
GITHUB_APP_PRIVATE_KEY_PATH=./config/github-app-private-key.pem
GITHUB_INSTALLATION_ID=...
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
DOCKER_NETWORK=aspm-net
DOCKER_RUN_TIMEOUT_SECONDS=600
```

**Pastas-chave:**

- `controller/job_controller.py` — fluxo de processamento de job
- `diplomat/http_out/github_client.py` — GitHub App API client
- `diplomat/runner/docker_runner.py` — Docker SDK wrapper
- `diplomat/messaging/kafka_consumer.py` — consumer Kafka
- `deploy/sonar-runner/` — Dockerfile + entrypoint do scanner

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
| `findings-ingestor` | Consome SARIF/JSON de scans, normaliza, persiste | FastAPI + postgres |
| `findings-api` | API/GraphQL pra consultar/triagear findings | FastAPI ou Strawberry |
| `policy-engine` | Decide quais scanners rodar por repo/PR | Python + YAML config |
| `ai-triage` | Classifica findings via LLM | Python + Anthropic SDK |
| `correlation-service` | Embeddings + grafo | Python + pgvector |

Nenhum desses existe ainda. Serão criados conforme o roadmap avança.
