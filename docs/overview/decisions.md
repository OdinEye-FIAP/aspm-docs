# Decisões de arquitetura

Registro curto das decisões tomadas e os trade-offs por trás. Formato ADR-lite. Atualizar quando algo mudar.

---

## 1. SonarQube como scanner inicial (status: superado — hoje são 4 scanners)

**Decisão original:** integrar SonarQube como primeiro scanner SAST disparado em PRs.

**Status atual (atualizado 2026-09-10):** `moby-dick/deploy/` hoje mantém 4 imagens de scanner (`sonar-runner`, `semgrep-runner`, `trivy-runner`, `zap-runner`). Captain-hook faz fan-out: um PR gera um `JobDescriptor` por scanner habilitado (`ENABLE_SEMGREP_SCAN`, `ENABLE_TRIVY_SCAN`, `ENABLE_ZAP_SCAN`, mais Sonar sempre ativo), e moby-dick roda até `SCANNER_MAX_CONCURRENCY=4` containers em paralelo por job. O padrão previsto abaixo (§5, image-per-scanner) se confirmou: nenhum dos 3 scanners novos exigiu refactor em moby-dick ou pequod.

**Por quê (contexto histórico, ainda válido):**
- Plataforma madura, cobre múltiplas linguagens out-of-the-box
- Quality Gate dá veredito binário (pass/fail) — encaixa no `check_run` do GitHub
- UI pronta pra inspeção manual durante validação inicial

---

## 2. SonarQube + `sonar-db` dedicado (postgres)

Sem mudanças — decisão ainda vigente como descrita.

**Decisão:** Sonar roda com seu próprio postgres dedicado.

**Por quê:**
- Sonar Community **exige** DB externo desde 2020 (H2 embedded removido)
- Não existe "Sonar stateless" — restrição da própria ferramenta
- DB dedicado mantém o Sonar como black-box: ninguém mais escreve nele

---

## 3. Compose Sonar dentro do captain-hook (provisório)

Sem mudanças — decisão ainda vigente como descrita.

**Decisão:** `sonarqube` + `sonar-db` + rede `aspm-net` vivem no `captain-hook/docker-compose.yml` junto com Redpanda.

**Trade-off:** acoplamento operacional (derrubar captain-hook derruba Sonar/Redpanda).

---

## 4. Storage central de findings (status: superado — pequod é hoje camada de governança completa)

**Decisão original:** não construir storage central de findings; usar só `check_run` do PR como feedback.

**Revisão 2026-06-23:** criamos o [`pequod`](https://github.com/OdinEye-FIAP/pequod) como consumer de `findings.raw`.

**Status atual (atualizado 2026-09-10): muito além de storage.** O pequod hoje é a camada de **governança de risco** do ecossistema, não só um storage de findings:

- **Risk Exceptions** — decisão de governança (`false_positive`/`accepted_risk`/`suppressed`) sobre um finding ou cluster.
- **Security Gate** — políticas versionadas (por aplicação ou globais), avaliadas contra findings/clusters de um scan.
- **Quality Gate** — orquestrado pelo pequod via endpoint síncrono chamado pelo moby-dick a cada scanner concluído (`POST /internal/quality-gates/{workflow_id}/evaluate`), com suporte a `scope=pr` (padrão) **e** `scope=branch` (Security Baseline — avaliação contínua da default branch, ver §15).
- **Candidate Clustering** — agrupamento determinístico de findings correlacionados, antes de qualquer decisão semântica.
- **Consolidated Risk** — a unidade de risco "canônica" exibida no heimdall-dashboard, resultado de decisão de IA do TARS (`merge`/`keep`/`split`) ou auto-attach determinístico.
- API REST com ~25 rotas (organizations, applications, scans, risk-exceptions, alerts, audit-logs, security-gate, consolidated-risks, quality-gates, integrações tars/moby-dick).

**Ainda adiado consciente:**
- Reachability analysis e fix suggestions automáticos (a triagem do TARS cobre recomendação/prioridade, não geração de patch)

---

## 5. Image wrapper `aspm-sonar-runner` (e demais scanners) com clone-in-container

**Decisão:** scanner roda numa imagem custom que clona o repo dentro do próprio container.

**Status atual:** o mesmo padrão foi replicado para `semgrep-runner`, `trivy-runner` e `zap-runner` sem alterar moby-dick — confirma a tese original de que adicionar scanner é só "build de image nova".

**Trade-off:** re-clone a cada scan (sem cache). Aceitável enquanto repos são pequenos.

---

## 6. `GIT_TOKEN` injetado em runtime pelo moby-dick

Sem mudanças — decisão ainda vigente como descrita.

---

## 7. Modo de scan: análise principal (sem PR mode) — confirmado, limitação real do Sonar Community

**Decisão:** scanner roda **sem** flags `sonar.pullrequest.*` por padrão. Cada scan sobrescreve a análise principal do projeto Sonar.

**Confirmado no código (`moby-dick/deploy/sonar-runner/entrypoint.sh`):** SonarQube Community Build **não suporta** `sonar.pullrequest.*`/`sonar.branch.*` (features pagas, Developer Edition+). O entrypoint só adiciona essas flags se `SONAR_PR_MODE=enabled` for setado explicitamente (kill switch operacional, não é o default).

!!! warning "Isto contradiz uma afirmação antiga no `DECISIONS.md` do captain-hook"
    O `DECISIONS.md` na raiz do monorepo (`captain-hook`/`moby-dick`/etc.) tem uma seção que descreve PR decoration (`sonar.pullrequest.key/branch/base`) como comportamento vigente. O código real (este entrypoint) mostra que isso está desligado por padrão desde que o Community Build se mostrou incompatível com PR mode. Sinalizado para correção cruzada.

**Trade-off aceito:**
- ❌ Sem isolamento entre PRs no Sonar UI (último scan ganha)
- ❌ Sem decoração visual de PR no Sonar
- ✅ `check_run` no PR ainda funciona (sinal binário) — é o canal de feedback real, não o Sonar UI

---

## 8. Quality Gate FAIL → `conclusion=failure`

Sem mudanças — decisão ainda vigente como descrita.

---

## 9. Persistência do Redpanda

Sem mudanças — decisão ainda vigente como descrita.

---

## 10. Documentação centralizada (este site)

Sem mudanças — decisão ainda vigente como descrita.

---

## 11. Extração de findings dentro da scanner image (status: **concluído**, não é mais "target")

**Decisão atual (antes transitória, hoje vigente):** a chamada à Sonar API (`GET /api/issues/search`) + conversão para SARIF **já migrou para dentro do `sonar-runner`** (`moby-dick/deploy/sonar-runner/entrypoint.sh` + `issues_to_sarif.py`, ambos dentro da image do scanner). `moby-dick/adapter/sonar/issues_to_sarif.py` **não existe mais** nesse path — o adapter que sobrou em `moby-dick/adapter/` (`sarif_to_check_run.py`) é outra coisa: converte SARIF em anotações de `check_run`, não fala com a API do Sonar.

**Confirmado:** moby-dick hoje só usa `container.get_archive(SARIF_OUTPUT_PATH)` pra extrair `/tmp/scan.sarif.json` do container — é Docker-only de fato pra qualquer um dos 4 scanners, exatamente como o plano original previa.

**Consequência prática já observada:** os 3 scanners novos (semgrep/trivy/zap) chegaram sem tocar em moby-dick nem pequod, confirmando a tese central desta decisão.

---

## 12. SARIF como formato comum de finding no pipeline

Sem mudanças — decisão ainda vigente como descrita.

---

## 13. `SONAR_PROJECT_KEY` derivado de `github.repository.id`

Sem mudanças — decisão ainda vigente como descrita.

---

## 14. Pequod como source-of-truth de findings (status: **realizado**, não é mais só intenção)

**Intenção original:** o `pequod` eventualmente substituiria o papel do `sonar-db` como repositório autoritativo.

**Status atual:** confirmado — toda integração nova (heimdall-dashboard, tars-ai, quality gate) consulta o pequod via REST, nunca o Sonar UI ou `sonar-db` diretamente. `sonar-db` continua existindo (Sonar Community exige postgres externo — §2), mas seu papel de "scratch interno do scanner" já é a realidade operacional, não mais uma meta.

**Nota de correção de fingerprint:** o texto original desta decisão descrevia dedup por `(fingerprint, repo)` com fingerprint sobre `scanner+rule+repo+file+line+snippet`. O código real (`pequod/model/finding.py::compute_fingerprint`) usa **`repo_id`** (não `repo`) e uma identidade estruturada de `location` que varia por `location_type` — não uma tupla fixa. Constraint real: `UNIQUE (fingerprint, repo_id)`. Ver [Finding v1](../reference/finding-v1.md) para o algoritmo completo.

---

## 15. Quality Gate com `scope=pr` e `scope=branch` (Security Baseline) — nova

**Decisão:** todo `quality_gate_runs` no pequod tem um `scope`: `pr` (padrão, exige `pull_request_number`) ou `branch` (Security Baseline — avaliação contínua da default branch, exige `branch_name`). Os dois campos são mutuamente exclusivos por constraint no banco.

**Por quê:**
- PRs cobrem o delta de código novo; a Security Baseline cobre o estado atual da `main` sem depender de um push acontecer.
- captain-hook (`controller/push_controller.py`) dispara o baseline em `push` na default branch, publicando job com `scope=branch`; moby-dick (`baseline_issue_sink_enabled`) agrega o resultado numa Issue do GitHub no repo alvo.
- Só é mantido 1 run "vigente" por PR (ou por branch) — novos commits/pushes substituem a run anterior.

**Ainda em aberto:** gatilho de baseline automático no *onboarding* de um repositório novo (hoje o gatilho é só `push`; não há disparo no momento em que o repo é cadastrado). Ver TODO do monorepo.

---

## 16. Quality Gate síncrono via REST entre moby-dick e pequod — nova

**Decisão:** a cada scanner concluído, moby-dick chama `POST /internal/quality-gates/{workflow_id}/evaluate` no pequod (síncrono, `X-Service-Token`), em vez de depender só de round-trip assíncrono via Kafka.

**Por quê:**
- Elimina race condition entre o consumer Kafka do pequod e o retorno do container do scanner.
- Decisão do Quality Gate fica determinística e testável (chamada HTTP idempotente) em vez de depender de ordenação de mensagens.
- O tópico Kafka `quality-gate.evaluated.v1` continua existindo como rede de segurança (publicado quando o gate finaliza sem nenhuma chamada HTTP em andamento), não como caminho principal.

**Trade-off aceito:** acopla moby-dick e pequod por disponibilidade HTTP direta, além do Kafka.

---

## 17. TARS AI consome o pequod via REST (polling), não via tópico Kafka dedicado — nova

**Decisão:** a triagem por IA (TARS AI) não tem tópico Kafka próprio (`ai.enrichments.triage`, previsto na versão anterior deste documento, nunca foi criado). Em vez disso, TARS AI faz *polling* REST contra o pequod (`TARS_PEQUOD_INTEGRATION_ENABLED=true`): busca pendências (`/integrations/tars/pending-findings`, `/pending-clusters`, `/semantic-candidates`) e submete vereditos (`/finding-analyses`, `/cluster-analyses`, `/semantic-clustering-decisions`).

**Por quê:**
- Evita acoplar o schema de enrichment de IA ao barramento de eventos — TARS AI pode rodar em ciclo próprio (`TARS_AUTO_ANALYZE_INTERVAL_SECONDS`), sem exigir consumer group dedicado nem lidar com replay/DLQ de Kafka.
- Provider de IA em uso: Gemini (`gemini-2.5-flash`), com `groq` e `huggingface` disponíveis via factory.

**Trade-off aceito:** latência de polling (não é enrichment em tempo real por evento).

---

## 18. Heimdall Dashboard como única UI, 100% via REST — nova

**Decisão:** o frontend (`heimdall-dashboard`, React/Vite/TS) não acessa nenhum banco nem Kafka diretamente. Fala com 3 backends via HTTP: pequod (governança/quality gate/riscos), TARS AI (análises de IA) e captain-hook (live-info de repositório + scaffold de PR).

**Por quê:** mantém o frontend como camada puramente de apresentação — qualquer mudança de schema é isolada nos serviços de backend.

---

## Princípios em jogo

- **Reuso de schema sobre reuso de código:** serviços falam por contratos versionados (`wire/schemas/`).
- **Stateless onde possível, stateful onde necessário:** scanners stateless; plataformas com UI/histórico ficam stateful em DB próprio.
- **Decisões reversíveis primeiro:** evitamos compromissos caros até o uso real exigir.
- **Token nunca atravessa fronteira de processo desnecessária.**

---

## Open questions

- Onde mora a configuração por repo (`.aspm.yml`?) quando precisarmos rotear scanners diferentes por projeto (hoje é tudo por env var global, `ENABLE_*_SCAN`)
- Gatilho de Security Baseline no onboarding de repositório (§15 — hoje só dispara em `push`)
- Estratégia de retenção de SARIF cru agora que o pequod é o agregador (`sarif_raw` já foi removido como coluna persistida no schema — recomposto via `finding_occurrences.raw_payload`)
- Métricas / observability formal (Prometheus? OTEL?) — moby-dick já expõe `GET /metrics/quality-gate`, mas não em formato Prometheus, e os outros serviços não têm métricas expostas
- Plataforma definitiva pra prod (continuar VPS? K8s? Railway?)
- Auth de usuário final do heimdall-dashboard (hoje não há OAuth/JWT de usuário — só tokens de serviço entre backends)

**Resolvido desde a última revisão (2026-09-10):**
- ~~Storage central de findings~~ → pequod, com governança completa (§4)
- ~~2º/3º scanner~~ → semgrep, trivy e zap já ativos além do Sonar (§1)
- ~~Extração de findings dentro da scanner image~~ → concluído (§11)
- ~~Enriquecimento por IA~~ → TARS AI, via REST contra pequod (§17)
- ~~Correlação cross-scanner~~ → candidate clustering determinístico no pequod + clustering semântico no TARS AI
- ~~UI de triagem~~ → heimdall-dashboard (§18)

Atualizar este documento quando uma das perguntas abertas virar decisão.
