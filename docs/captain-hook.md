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
| `push` | qualquer push | **nenhum processamento dedicado hoje.** `controller/webhook_controller.py` não tem handler para `push` em `main` — cai no branch "evento sem processamento dedicado", é só logado e descartado. Ver aviso abaixo |
| `installation` | `created`, `deleted` | registra/desregistra em massa todos os repositórios cobertos pela instalação da App — **nunca** dispara auto-scaffold (evitaria abrir dezenas de PRs simultâneos) |
| `installation_repositories` | `added`, `removed` | idem, para mudança de escopo de repositórios de uma instalação já existente |

Eventos sem processamento dedicado são logados e descartados — não fazem o webhook retornar erro.

!!! warning "Security Baseline (push na default branch) — não está em `main` (corrigido 2026-09-10)"
    Versões anteriores desta página descreviam um fluxo onde `push` na default branch dispararia um "Security Baseline" (scope=`branch`) via `controller/push_controller.py` e `adapter/wire_in/push_adapter.py`. **Esse código não existe em `main`.** Três tentativas de implementar isso (PRs #38, #41, #42) foram abertas e fechadas sem merge. O pequod já sabe processar `scope=branch` de ponta a ponta — só falta o lado do captain-hook (produzir o evento a partir do push) e do moby-dick (consumir/reagir). Ver [Decisão §15](overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--nova) e o `TODO.md` da raiz do monorepo local para o plano de recuperação.

## Scanners disparados

Cada `pull_request` relevante (`opened`/`synchronize`/`reopened`) monta uma lista de `JobDescriptor`, um por scanner habilitado, publicada em `jobs.orchestration`:

| Scanner | Sempre ativo? | Feature flag (captain-hook) | `kind` |
|---|---|---|---|
| SonarQube | ✅ sempre | — | `sonar_scan` |
| Semgrep SAST | opcional | `ENABLE_SEMGREP_SCAN` | `semgrep_scan` |
| Trivy SCA | opcional | `ENABLE_TRIVY_SCAN` | `trivy_scan` |
| OWASP ZAP DAST | opcional | `ENABLE_ZAP_SCAN` (+ `ZAP_TARGET_URL` obrigatório se `DAST_MODE=fixed_url`) | `zap_scan` |

Cada scanner tem seu builder próprio em `adapter/wire_out/scanners/{sonar,semgrep,trivy,zap}_scanner.py`, com a função `build_job` (scope=`pr`, chamado por `pull_request_controller`). Uma função `build_baseline_job` (scope=`branch`) foi desenhada como parte das PRs #38/#41/#42 do Security Baseline, mas não existe em `main` — ver aviso acima. Ver [Adicionar novo scanner](developer/adding-a-scanner.md) para o padrão completo do que existe hoje.

!!! tip "SONAR_PROJECT_KEY"
    `SONAR_PROJECT_KEY` é sempre `f"gh_{repository.id}"`, montado em `adapter/wire_out/scanners/sonar_scanner.py` (`build_job`). `repository.id` é imutável no GitHub — sobrevive a rename/transfer. Ver [Decisão §13](overview/decisions.md#13-sonar_project_key-derivado-de-githubrepositoryid) e [JobDescriptor](reference/job-descriptor.md#convenção-sonar_project_key).

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
  GH -->|ping / installation(_repositories)| CH
  GH -.->|push - recebido, sem handler em main| CH
  HD -->|GET live-info / POST scaffold-pr| CH
  CH -->|publish jobs.orchestration N scanners + quality-gate.workflow.started.v1| K
```

![Fluxo de dados — Captain-hook](assets/captain-hook-flow.svg)
