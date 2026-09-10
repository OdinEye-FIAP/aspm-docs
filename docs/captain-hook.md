# Captain-hook

Ponto de entrada do GitHub: recebe webhooks, valida HMAC e publica `JobDescriptor v1` no Kafka (`jobs.orchestration`). Também expõe endpoints HTTP síncronos consumidos diretamente pelo `heimdall-dashboard` e para disparo manual do auto-scaffold.

## Quick start

```bash
docker compose up -d            # redpanda + sonarqube + sonar-db
cp .env.example .env
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8080
```

## Endpoints

| Método | Path | Descrição |
|---|---|---|
| `POST` | `/webhook` | recebe webhooks do GitHub (`ping`, `pull_request`, `push`, `installation`, `installation_repositories`) |
| `GET` | `/health` | liveness |
| `GET` | `/repos/{owner}/{repo}/live-info` | issues abertas + dependências (Dependency Graph/SBOM) do repositório, buscadas ao vivo no GitHub — sem persistência, sem publicar evento; consumido diretamente pelo `heimdall-dashboard` |
| `POST` | `/repos/{owner}/{repo}/scaffold-pr` | dispara manualmente o auto-scaffold (PR sugerindo `docker-compose.aspm.yml` + lint config + workflow) para um repositório específico — necessário para repositórios registrados em massa via `installation`, que nunca recebem `ping` individual |
| `GET` | `/docs` | Swagger |

!!! note "CORS e live-info"
    `/repos/{owner}/{repo}/live-info` é chamado diretamente do navegador pelo `heimdall-dashboard` na tela de Governança. As duas buscas (issues + dependências) rodam em paralelo e falham de forma independente. Origens permitidas via `CORS_ALLOWED_ORIGINS`.

## Eventos do GitHub processados

| Evento | Action(s) monitoradas | O que dispara |
|---|---|---|
| `ping` | — | registra o repositório no pequod (`repository.registered.v1`) e, em background, avalia o auto-scaffold (`ENABLE_REPO_SCAFFOLD_PR`) |
| `pull_request` | `opened`, `synchronize`, `reopened` | inicia o **Quality Gate** (scope=`pr`): publica `quality-gate.workflow.started.v1` + 1 `JobDescriptor` por scanner habilitado em `jobs.orchestration` |
| `push` | push na **default branch** do repositório | inicia o **Security Baseline** (scope=`branch`): mesma máquina do Quality Gate (`workflow.started` + `jobs.orchestration`), sem `SONAR_PULLREQUEST_*`/`base_ref` (full-branch scan) — ver `controller/push_controller.py` |
| `installation` | `created`, `deleted` | registra/desregistra em massa todos os repositórios cobertos pela instalação da App — **nunca** dispara auto-scaffold (evitaria abrir dezenas de PRs simultâneos) |
| `installation_repositories` | `added`, `removed` | idem, para mudança de escopo de repositórios de uma instalação já existente |

Eventos sem processamento dedicado são logados e descartados — não fazem o webhook retornar erro.

!!! note "Push só dispara Security Baseline na default branch"
    `adapter/wire_in/push_adapter.py::to_baseline_context` filtra estritamente `refs/heads/{repository.default_branch}`, ignora `deleted=true` e commits vazios (`after` zerado). Push em feature branch, tag ou delete de branch não gera nenhum job — o webhook é recebido, mas `to_baseline_context` retorna `None` e `process_push_event` só loga "push ignorado". Confirmado em `main` desde 31/ago/2026 (PR #38) — ver [Decisão §15](overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10). Ver também [onboarding de repositório](integration/onboarding-repo.md).

## Como `ping` e `installation(_repositories)` são processados (sequência)

Esses eventos não geram `JobDescriptor`/scanner — só afetam o inventário de repositórios no pequod (`repository.registered.v1` / `repository.unregistered.v1`). Não havia ainda um diagrama sequencial pra esse fluxo (só a tabela acima); fica registrado aqui, ao lado dos diagramas de check_run.

### `ping`

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant CH as captain-hook
    participant K as Kafka (repository.registered.v1)
    participant PQ as pequod

    GH->>CH: POST /webhook (ping)
    CH->>CH: process_ping_event
    alt payload utilizável (repo individual, com dados completos)
        CH->>K: publish repository.registered.v1
        K->>PQ: consome e registra o repositório
        CH->>CH: background_tasks.add_task(process_repository_scaffold)
        Note over CH: scaffold só é avaliado aqui —<br/>chamadas à API do GitHub (branch/commit/PR)<br/>rodam depois da resposta HTTP
    else payload incompleto (sem repositório individual — ex.: ping de app/org)
        Note over CH: nenhum evento publicado, nenhum scaffold
    end
    CH-->>GH: 200 OK
```

### `installation` / `installation_repositories`

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant CH as captain-hook
    participant K as Kafka (repository.*)
    participant PQ as pequod

    GH->>CH: POST /webhook (installation | installation_repositories)
    CH-->>GH: 200 OK imediato
    Note over CH: processamento agendado via background_tasks —<br/>publicar N repositórios pode passar<br/>do timeout curto do webhook (~10s)

    CH->>CH: process_installation(_repositories)_event
    alt action = created | added
        loop 1 por repositório, sequencial, falha isolada
            CH->>K: publish repository.registered.v1
        end
    else action = deleted | removed
        loop 1 por repositório, sequencial, falha isolada
            CH->>K: publish repository.unregistered.v1
        end
    end
    K->>PQ: consome e registra/desregistra em massa
    Note over CH: nunca dispara auto-scaffold —<br/>evitaria abrir dezenas de PRs simultâneos numa org grande
```

!!! note "Fonte"
    `controller/webhook_controller.py` (roteamento), `controller/ping_controller.py`, `controller/installation_controller.py`. Confirmado em `main` em 2026-09-10.

## Scanners disparados

Cada evento relevante (`pull_request` relevante ou `push` na default branch) monta uma lista de `JobDescriptor`, um por scanner habilitado, publicada em `jobs.orchestration`:

| Scanner | Sempre ativo? | Feature flag (captain-hook) | `kind` |
|---|---|---|---|
| SonarQube | ✅ sempre | — | `sonar_scan` |
| Semgrep SAST | opcional | `ENABLE_SEMGREP_SCAN` | `semgrep_scan` |
| Trivy SCA | opcional | `ENABLE_TRIVY_SCAN` | `trivy_scan` |
| OWASP ZAP DAST | opcional | `ENABLE_ZAP_SCAN` (+ `ZAP_TARGET_URL` obrigatório se `DAST_MODE=fixed_url`) | `zap_scan` |

Cada scanner tem seu builder próprio em `adapter/wire_out/scanners/{sonar,semgrep,trivy,zap}_scanner.py`, com duas funções: `build_job` (scope=`pr`, chamado por `pull_request_controller`) e `build_baseline_job` (scope=`branch`, chamado por `push_controller`) — mesma matriz de feature flags nos dois casos, só muda o contexto (sem `SONAR_PULLREQUEST_*`/`base_ref` no baseline). Ver [Adicionar novo scanner](developer/adding-a-scanner.md) para o padrão completo.

!!! tip "SONAR_PROJECT_KEY"
    `SONAR_PROJECT_KEY` é sempre `f"gh_{repository.id}"`, montado em `adapter/wire_out/scanners/sonar_scanner.py` (`build_job`/`build_baseline_job`). `repository.id` é imutável no GitHub — sobrevive a rename/transfer. Ver [Decisão §13](overview/decisions.md#13-sonar_project_key-derivado-de-githubrepositoryid) e [JobDescriptor](reference/job-descriptor.md#convenção-sonar_project_key).

## Links

- README completo: ../captain-hook/README.md
- JobDescriptor: ../reference/job-descriptor.md
- Onboarding de repositório: ../integration/onboarding-repo.md
- Adicionar novo scanner: ../developer/adding-a-scanner.md

## Fluxo de dados

```mermaid
flowchart LR
  GH[GitHub Webhook]
  CH[captain-hook]
  K[(Kafka/Redpanda)]
  HD[heimdall-dashboard]

  GH -->|pull_request opened/synchronize/reopened| CH
  GH -->|push na default branch| CH
  GH -->|ping / installation(_repositories)| CH
  HD -->|GET live-info / POST scaffold-pr| CH
  CH -->|publish jobs.orchestration N scanners + quality-gate.workflow.started.v1| K
```

![Fluxo de dados — Captain-hook](assets/captain-hook-flow.svg)
