# Repositórios

## Mapa rápido

| Repo | Função | Stack | Estado |
|---|---|---|---|
| [`captain-hook`](https://github.com/OdinEye-FIAP/captain-hook) | Ingest de webhook GitHub (PR + push) → publica jobs no Kafka, 1 por scanner habilitado | FastAPI + aiokafka | ✅ ativo |
| [`moby-dick`](https://github.com/OdinEye-FIAP/moby-dick) | Consumer Kafka → spawna até 4 containers scanner em paralelo → extrai SARIF → avalia quality gate com pequod (síncrono) → reporta check_run (+ Issue de baseline) | FastAPI + Docker SDK + PyJWT | ✅ ativo |
| [`pequod`](https://github.com/OdinEye-FIAP/pequod) | Consumer `findings.raw` + governança de risco: risk exceptions, security gate, quality gate (PR e branch), candidate clustering, consolidated risk. REST com 38 rotas reais | FastAPI + aiokafka + asyncpg | ✅ ativo |
| [`tars-ai`](https://github.com/OdinEye-FIAP/tars-ai) | Triagem por IA (individual + cluster) e clustering semântico, via REST contra o pequod | FastAPI + Gemini/Groq/HF | ✅ ativo |
| [`heimdall-dashboard`](https://github.com/OdinEye-FIAP/heimdall-dashboard) | Frontend: governança, quality gate, riscos consolidados, findings técnicos | React + Vite + TypeScript | ✅ ativo |
| [`clint-eastwood`](https://github.com/OdinEye-FIAP/clint-eastwood) | Repo de teste/demo com código intencionalmente vulnerável | JS | 🧪 demo |
| [`aspm-vuln-lab`](https://github.com/OdinEye-FIAP/aspm-vuln-lab) | Segundo repo de teste/demo vulnerável, usado pra validar o pipeline | Python | 🧪 demo |
| [`aspm-docs`](https://github.com/OdinEye-FIAP/aspm-docs) | Esta documentação | MkDocs Material | 📚 doc |

## captain-hook

**Papel:** ponto de entrada do GitHub no pipeline.

**Responsabilidades:**

- Receber webhooks do GitHub (`POST /webhook`) e validar HMAC (`GITHUB_WEBHOOK_SECRET`)
- Traduzir `pull_request.{opened,synchronize,reopened}` em `JobDescriptor v1` — um job por scanner habilitado (Sonar sempre + Semgrep/Trivy/ZAP via flag)
- Traduzir `push` na default branch em Security Baseline (`scope=branch`) — mesma matriz de scanners, full-branch scan (`controller/push_controller.py` + `adapter/wire_in/push_adapter.py`)
- Publicar registro/baixa de repositório (`repository.registered.v1`/`repository.unregistered.v1`) a partir dos eventos `installation`/`installation_repositories`
- Expor `GET /repos/{owner}/{repo}/live-info` (issues/dependências ao vivo) e `POST /repos/{owner}/{repo}/scaffold-pr` (abre PR de onboarding sob demanda)
- Auto-scaffold de PR (`ENABLE_REPO_SCAFFOLD_PR`) quando um repositório é registrado e não tem os arquivos esperados

**O que NÃO faz:**

- Não conhece Docker
- Não conhece o formato específico de nenhum scanner
- Não tem credenciais da GitHub App (isso é do moby-dick)
- Não responde quando o scan termina
- Não publica nenhum payload bruto de webhook para auditoria/replay — uma versão anterior desta página descrevia um tópico `github.events.raw` que nunca existiu no código (invenção da documentação, corrigida 2026-09-10)

**Settings principais (`config/settings.py`):**

```env
GITHUB_WEBHOOK_SECRET=...
GITHUB_APP_ID=...
GITHUB_INSTALLATION_ID=...
ENABLE_REPO_SCAFFOLD_PR=false
CORS_ALLOWED_ORIGINS=...
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_MESSAGE_SECRET=...
DEFAULT_JOB_IMAGE=aspm-sonar-runner:latest
ENABLE_SEMGREP_SCAN=false
ENABLE_TRIVY_SCAN=false
ENABLE_ZAP_SCAN=false
DAST_MODE=compose_preview
```

!!! note "Default de `DAST_MODE` tem uma nuance"
    O default aqui (`compose_preview`) é o do captain-hook, que monta o env do `JobDescriptor`. Mas o script que efetivamente roda o scan (`moby-dick/deploy/zap-runner/entrypoint.sh`) tem seu próprio fallback interno `DAST_MODE="${DAST_MODE:-fixed_url}"` — se a variável não chegar ao container por algum motivo, o zap-runner assume `fixed_url`, não `compose_preview`. Os dois defaults divergem entre as duas camadas.

## moby-dick

**Papel:** orquestrador de Docker + avaliador de quality gate.

**Responsabilidades:**

- Consumir `jobs.orchestration` do Kafka; mintar `installation_token` via GitHub App
- Criar `check_run` "OdinEye / Quality Gate" (ou `Security Baseline ...` para `scope=branch`) no PR/commit com status `in_progress`
- Rodar até `SCANNER_MAX_CONCURRENCY` containers em paralelo, um por scanner do workflow
- Extrair `/tmp/scan.sarif.json` de cada container via `container.get_archive()` — não fala com a API de nenhum scanner, isso já sai pronto da image
- Publicar SARIF em `findings.raw` e chamar **de forma síncrona** `POST /internal/quality-gates/{workflow_id}/evaluate` no pequod a cada scanner concluído
- Atualizar o check_run com a decisão final quando todos os scanners esperados reportarem
- Quando `scope=branch` (Security Baseline), fazer upsert de uma Issue agregada por (repo, branch) no repositório alvo (`controller/baseline_sink_controller.py`), best-effort
- Expor `GET /metrics/quality-gate`

**O que NÃO faz:**

- Não conhece nenhum scanner específico — toda conversa scanner-específica vive dentro da image do scanner (ver [Decisão §11](decisions.md#11-extração-de-findings-dentro-da-scanner-image-status-concluído-não-é-mais-target))
- Não persiste findings nem decide policy de governança (delega ao pequod)
- Não cria 1 Issue por `consolidated_risk` — hoje é 1 Issue agregada por (repo, branch); o sink per-risco depende do pequod expor leitura/atualização de `consolidated_risk` filtrada por branch (ver [Decisão §15](decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10))

**Settings principais:**

```env
GITHUB_APP_ID=...
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_MESSAGE_SECRET=...
QUALITY_GATE_CONSUMER_GROUP=moby-dick-quality-gate
SCANNER_MAX_CONCURRENCY=4
PEQUOD_BASE_URL=http://localhost:7070
PEQUOD_SERVICE_TOKEN=...
HEIMDALL_BASE_URL=...
DOCKER_NETWORK=aspm-net
SARIF_OUTPUT_PATH=/tmp/scan.sarif.json
BASELINE_ISSUE_SINK_ENABLED=true
```

**Pastas-chave:**

- `controller/job_controller.py`, `controller/quality_gate_check_controller.py`, `controller/baseline_sink_controller.py`
- `diplomat/http_out/github_client.py`, `diplomat/http_out/pequod_client.py`
- `diplomat/runner/docker_runner.py`
- `diplomat/messaging/kafka_consumer.py`, `diplomat/messaging/quality_gate_consumer.py`
- `deploy/{sonar,semgrep,trivy,zap}-runner/` — Dockerfile + entrypoint de cada scanner (dono do conhecimento scanner-específico)

## pequod

**Papel:** camada de persistência **e governança de risco**.

**Responsabilidades:**

- Consumir `findings.raw`, parsear SARIF v2.1.0 → `Finding v1`, fingerprint determinístico por `repo_id`
- Avaliar Quality Gate (síncrono, chamado pelo moby-dick) — `scope=pr` e `scope=branch` (Security Baseline), os dois em produção
- Security Gate: políticas versionadas, avaliações, itens bloqueantes/de aviso
- Risk Exceptions: aceitar/suprimir/marcar falso-positivo um finding ou cluster
- Candidate Clustering: agrupamento determinístico de findings correlacionados
- Consolidated Risk: risco "canônico" pós-decisão de IA (TARS) ou auto-attach determinístico
- Expor REST (38 rotas reais) pra heimdall-dashboard e tars-ai

**O que NÃO faz:**

- Não chama scanners nem conhece Docker/GitHub
- Não roda IA por conta própria — delega ao tars-ai via REST (`/integrations/tars/*`)

**Settings principais:**

```env
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
DATABASE_URL=********
CORS_ALLOWED_ORIGINS=...
```

**Pastas-chave:**

- `diplomat/http_in/{api_v1_router,tars_integration_router,moby_dick_integration_router,quality_gates_router}.py`
- `controller/{tars_integration,candidate_clustering,consolidated_risk,quality_gate_security}_controller.py`
- `model/{finding,risk_exception,security_gate_policy,quality_gate_run}.py`
- `deploy/schema.sql` — schema consolidado (substitui migrations incrementais)

## tars-ai

**Papel:** triagem por IA e clustering semântico.

**Responsabilidades:**

- Modo principal: `TARS_PEQUOD_INTEGRATION_ENABLED=true` — busca pendências no pequod via REST (`/integrations/tars/pending-findings`, `/pending-clusters`, `/semantic-candidates`) e submete vereditos
- Análise individual de finding (campos slim: `recommendation`/`priority`/`confidence`/`model_name`) e análise de cluster (campos completos, incluindo `summary`/`impact`/`false_positive_likelihood`/`reasoning_short`)
- Clustering semântico: propõe `merge`/`keep`/`split` que o pequod grava como `consolidated_risk`
- Provider de IA ativo: Gemini (`gemini-2.5-flash`); `groq` e `huggingface` disponíveis via factory
- Modo legado (acesso direto ao banco do pequod) ainda existe, desligado por padrão

**O que NÃO faz:**

- Não escreve direto no banco quando `TARS_PEQUOD_INTEGRATION_ENABLED=true` — tudo via REST
- Não roda scan nem conhece Docker/GitHub

**Settings principais:**

```env
TARS_PEQUOD_INTEGRATION_ENABLED=true
PEQUOD_BASE_URL=http://localhost:7070
PEQUOD_SERVICE_TOKEN=...
AI_PROVIDER=gemini
GEMINI_MODEL=gemini-2.5-flash
TARS_AUTO_ANALYZE_ENABLED=true
TARS_AUTO_ANALYZE_INTERVAL_SECONDS=60
```

## heimdall-dashboard

**Papel:** frontend de governança/quality gate/riscos.

**Responsabilidades:**

- Consome 3 backends via REST: `pequodApi.ts` (organizações, aplicações, scans, alertas, risk exceptions, audit log, security gate, quality gate, riscos consolidados), `tarsApi.ts` (análises de IA), `captainHookApi.ts` (live-info de repositório, scaffold de PR)
- 6 abas: organizações, repositórios, governança, quality gate, findings técnicos, riscos consolidados
- 23 componentes em `src/components/`

**O que NÃO faz:**

- Não acessa nenhum banco ou Kafka diretamente — é camada 100% de apresentação

**Settings principais:**

```env
VITE_PEQUOD_API_URL=http://localhost:7070
VITE_TARS_API_URL=http://localhost:6060
VITE_CAPTAIN_HOOK_API_URL=http://localhost:8080
```

## clint-eastwood / aspm-vuln-lab

**Papel:** repos de demonstração com vulnerabilidades intencionais, usados pra validar que o pipeline detecta findings (hardcoded credentials, SQL/command injection, weak crypto, dependências vulneráveis, etc). Não fazem parte da plataforma — são repos onboardados pra validação, como qualquer outro.

## aspm-docs

**Papel:** documentação central (este site). Deploy: push em `main` → GitHub Actions → GitHub Pages.

## Convenções entre repos

- **Branches:** `feat/<scope>`, `fix/<scope>`, `docs/<scope>`, `chore/<scope>`, `refactor/<scope>`
- **Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`)
- **Releases:** sem release formal — deploy é via `git pull` + `systemctl restart` na VPS
- **Schemas compartilhados:** copiados entre repos por enquanto (sem pacote `aspm-wire` ainda — ver [Decisão §9 do DECISIONS.md de cada serviço]) — decisão consciente, revisitada quando um 3º consumer Kafka aparecer

## Componentes previstos que já foram criados

A versão anterior desta página listava `ai-triage` e `findings-ui` como componentes futuros. Ambos já existem:

- `ai-triage` → **`tars-ai`** (triagem por IA + clustering semântico)
- `findings-ui` → **`heimdall-dashboard`** (UI de governança/triagem)

## Componentes ainda não criados

| Nome candidato | Função | Observação |
|---|---|---|
| `policy-engine` | Decide quais scanners rodam por repo/PR via config declarativa (`.aspm.yml`) | Hoje o roteamento é só por env var global (`ENABLE_*_SCAN`), não por repositório |
| `correlation-service` | Grafo de correlação cross-scanner mais amplo que o candidate clustering atual | Candidate clustering (determinístico) e clustering semântico (TARS) já cobrem boa parte do caso de uso |
| `notifier` | Posta findings críticos em Slack/email | `alerts` já existe no pequod como modelo de dados; falta o canal de entrega externo |

## Security Baseline (`scope=branch`)

Não é um componente novo, é uma feature cross-repo: push na default branch dispara o mesmo pipeline de scan do PR (`push_controller.py` no captain-hook), só que full-branch e sem PR associado; o pequod avalia com `scope=branch`; o moby-dick, além do check_run no commit, faz upsert de uma Issue agregada por (repo, branch). Ponta a ponta em `main` desde 31/ago/2026 — ver [Decisão §15](decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10) para o histórico (incluindo uma checagem que apontou o contrário mais cedo hoje, feita com refs git locais desatualizadas, já corrigida).
