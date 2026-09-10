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
- **Quality Gate** — orquestrado pelo pequod via endpoint síncrono chamado pelo moby-dick a cada scanner concluído (`POST /internal/quality-gates/{workflow_id}/evaluate`). Suporta `scope=pr` e `scope=branch` (Security Baseline) — os dois em produção de ponta a ponta, ver §15.
- **Candidate Clustering** — agrupamento determinístico de findings correlacionados, antes de qualquer decisão semântica.
- **Consolidated Risk** — a unidade de risco "canônica" exibida no heimdall-dashboard, resultado de decisão de IA do TARS (`merge`/`keep`/`split`) ou auto-attach determinístico.
- API REST com **38 rotas reais** (contadas 2026-09-10: 5 top-level incluindo `/findings*` legado, 22 em `/api/v1/*`, 3 em quality-gates, 7 em `/integrations/tars/*`, 1 em `/internal/quality-gates/*`). Uma versão anterior desta página citava "~25 rotas" — contagem manual imprecisa, corrigida.

**Ainda adiado consciente:**
- Reachability analysis e fix suggestions automáticos (a triagem do TARS cobre recomendação/prioridade, não geração de patch)

---

## 5. Image wrapper `aspm-sonar-runner` (e demais scanners) com clone-in-container

**Decisão:** scanner roda numa imagem custom que clona o repo dentro do próprio container.

**Status atual:** o mesmo padrão foi replicado para `semgrep-runner`, `trivy-runner` e `zap-runner` sem alterar moby-dick — confirma a tese original de que adicionar scanner é só "build de image nova". Isso vale tanto para o fluxo de PR (`build_job`) quanto para o Security Baseline (`build_baseline_job`, ver §15) — cada scanner builder tem as duas funções lado a lado.

**Trade-off:** re-clone a cada scan (sem cache). Aceitável enquanto repos são pequenos.

---

## 6. `GIT_TOKEN` injetado em runtime pelo moby-dick

Sem mudanças — decisão ainda vigente como descrita.

---

## 7. Modo de scan: análise principal (sem PR mode) — confirmado, limitação real do Sonar Community

**Decisão:** scanner roda **sem** flags `sonar.pullrequest.*` por padrão. Cada scan sobrescreve a análise principal do projeto Sonar.

**Confirmado no código (`moby-dick/deploy/sonar-runner/entrypoint.sh`):** SonarQube Community Build **não suporta** `sonar.pullrequest.*`/`sonar.branch.*` (features pagas, Developer Edition+). O entrypoint só adiciona essas flags se `SONAR_PR_MODE=enabled` for setado explicitamente (kill switch operacional, não é o default). Isso vale tanto para PRs quanto para o Security Baseline — o baseline nem tenta setar essas flags (`build_baseline_job` não popula `SONAR_PULLREQUEST_*`), então cada push na default branch também sobrescreve o snapshot anterior do mesmo `projectKey` (aceito, pequod é source-of-truth — ver §14).

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

## 15. Quality Gate com `scope=pr` e `scope=branch` (Security Baseline) — ponta a ponta em `main` (reconfirmado 2026-09-10)

**Decisão:** todo `quality_gate_runs` no pequod tem um `scope`: `pr` (padrão, exige `pull_request_number`) ou `branch` (Security Baseline — avaliação contínua da default branch a cada `push`, exige `branch_name`). Os dois campos mutuamente exclusivos por constraint no banco.

**Rollout coordenado (31/ago/2026), confirmado nos três repositórios:**

| Repo | Commit em `main` | O que entrega |
|---|---|---|
| **pequod** | `fb65ca1` (PR #50) | `deploy/schema.sql`: coluna `scope` + CHECK de exclusividade + índice único parcial `ux_quality_gate_runs_branch`; `wire/schemas/quality_gate_v1.py` valida consistência; `controller/quality_gate_controller.py` processa `scope` em todo o fluxo. |
| **moby-dick** | `b6e7aa5`/`0c866c6` (PR #38) | `wire/schemas/quality_gate_v1.py` com `scope`/`branch_name`; `GitHubClient.create_issue`/`update_issue`/`find_issue_by_label`; `controller/baseline_sink_controller.py` (upsert de Issue agregada por repo+branch); `quality_gate_check_controller.py` discrimina título/texto do check por `scope`. |
| **captain-hook** | `cdd08a6` (PR #38) | `controller/push_controller.py` (`process_push_event`); `webhook_controller.py` roteia `push` pra ele; `adapter/wire_in/push_adapter.py` (`to_baseline_context`, filtra só push na default branch); cada scanner builder ganhou `build_baseline_job` ao lado do `build_job` existente. |

**Follow-ups já mergeados depois do rollout inicial:**
- captain-hook `110b950` (PR #42): removeu `scanner_job_id` morto/duplicado em `push_adapter.py`.
- captain-hook `c350c52` / moby-dick `a982c3f` (docs, 09/set): READMEs atualizados descrevendo o fluxo de push/baseline.

**Kill switch:** `moby-dick` tem `BASELINE_ISSUE_SINK_ENABLED` (default `true`) — desliga só o sink de Issue, não o check_run nem a avaliação do gate em si.

!!! danger "Nota de processo: uma revisão anterior desta seção, feita ainda hoje (2026-09-10), concluiu erroneamente que isso NÃO estava em `main`"
    Essa verificação anterior rodou `git merge-base --is-ancestor` **contra os clones locais do monorepo**, que estavam com os refs de `origin/main` desatualizados (cacheados de antes do rollout de 31/ago — o sandbox não tem acesso de rede a `git fetch`/`git pull` via SSH nem HTTPS, então refs locais só refletem o que já foi baixado antes). Isso deu falso-negativo: os commits pareciam não-ancestrais de uma `main` que, na verdade, já não existia mais (tinha avançado). A checagem correta — feita depois, via GitHub API (`list_commits` direto em `main`, e leitura do conteúdo real dos arquivos em `refs/heads/main`) — confirma que os três repositórios estão sincronizados e a feature funciona de ponta a ponta desde 31/ago/2026. Pedimos desculpas pelo ruído: por um período dentro desta mesma sessão, o `aspm-docs` chegou a ser corrigido para dizer o contrário ("não está em main") — essa correção foi revertida por esta revisão. **Lição registrada:** para verificar o estado real de um repositório remoto, usar a API do GitHub (ou pedir ao usuário pra rodar `git fetch` fora do sandbox) em vez de `git merge-base` local quando o sandbox não tem rede pra atualizar os refs.

---

## 16. Quality Gate síncrono via REST entre moby-dick e pequod — nova

**Decisão:** a cada scanner concluído, moby-dick chama `POST /internal/quality-gates/{workflow_id}/evaluate` no pequod (síncrono, `X-Service-Token`), em vez de depender só de round-trip assíncrono via Kafka.

**Por quê:**
- Elimina race condition entre o consumer Kafka do pequod e o retorno do container do scanner.
- Decisão do Quality Gate fica determinística e testável (chamada HTTP idempotente) em vez de depender de ordenação de mensagens.
- O tópico Kafka `quality-gate.evaluated.v1` continua existindo como rede de segurança (publicado quando o gate finaliza sem nenhuma chamada HTTP em andamento), não como caminho principal.

**Trade-off aceito:** acopla moby-dick e pequod por disponibilidade HTTP direta, além do Kafka.

!!! warning "No radar (levantado por Leandro, 2026-09-10): o `/evaluate` síncrono não é tão síncrono quanto parece"
    Lendo `controller/quality_gate_controller.py` (pequod) de novo hoje: um scanner só conta como "pronto pra fechar o gate" em `_finalize_locked` se, além de `status=completed`, já tiver um `scan_id` correlacionado — e esse `scan_id` só existe depois que o consumer de `findings.raw` grava a `Finding` e chama `attach_scan_by_job_id`. Se `scanner.completed` (via `/evaluate`) chegar antes de `findings.raw` terminar de ser processado, `_finalize_locked` devolve `None` ("ainda não pronto") mesmo com o container do scanner já tendo terminado — e a finalização real só acontece depois, via `process_scan_persisted_for_quality_gate` (hook do consumer de `findings.raw`), publicando o fallback Kafka (`quality-gate.evaluated.v1`) por não ter mais nenhuma chamada HTTP em andamento naquele momento. Ou seja: o caminho "feliz" documentado (moby-dick chama `/evaluate`, recebe a decisão na resposta) depende implicitamente de uma corrida ganha contra dois tópicos Kafka (`findings.raw` publicado + consumido) — quando essa corrida é perdida, o Check consolidado só atualiza pelo caminho de fallback, não pela resposta HTTP. Isso não é bug (tem cobertura — nada trava), mas o acoplamento é pouco explícito: nada na resposta do `/evaluate` distingue "scanner realmente pendente" de "scanner terminou, mas o SARIF ainda não foi correlacionado". Vale revisar com calma se essa dependência deveria ser explícita/observável, ou se `scan_id` deveria deixar de depender do ciclo Kafka pra ser atribuído.

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
- Sink de Security Baseline por `consolidated_risk` (1 Issue por risco) em vez da Issue agregada atual por (repo, branch) — depende do pequod expor leitura/atualização de `consolidated_risk` filtrada por (application_id, branch); colunas `consolidated_risk.github_issue_number`/`github_issue_url` já existem no schema esperando esse mapping (ver §15 e follow-up citado no commit do moby-dick).
- **Acoplamento `findings.raw` → `scan_id` → finalização do Quality Gate (§16, levantado por Leandro em 2026-09-10):** a decisão do gate no caminho "feliz" depende de o SARIF já ter sido consumido de `findings.raw` e correlacionado a um `scan_id` antes do `/evaluate` síncrono conseguir fechar o workflow; quando essa corrida é perdida, quem finaliza de fato é o caminho assíncrono (`process_scan_persisted_for_quality_gate` + fallback Kafka), não a resposta HTTP. Funciona, mas o acoplamento entre uma chamada que parece síncrona e dois tópicos Kafka por trás não é explícito nem observável na resposta do `/evaluate` hoje. Não parece a forma mais direta de fazer isso — revisar com mais detalhe antes de decidir se vale simplificar.
- **Confiabilidade do producer em `installation`/`installation_repositories` → `repository.registered.v1`/`.unregistered.v1` (levantado por Leandro em 2026-09-10 — EM PLANEJAMENTO, ver plano de migração abaixo):** o lado consumer no pequod é sólido — `RepositoryRegistrationConsumer` verifica assinatura HMAC, só comita offset depois do handler rodar, tem retry com backoff (`call_with_retry`) e manda pra DLQ (`repository.registration.pequod.dlq`) se esgotar as tentativas; o handler faz upsert idempotente + audit log na mesma transação. O lado producer no captain-hook não tem o mesmo rigor: `ping` propaga falha de publish pra resposta HTTP do webhook (o GitHub reentrega); mas `installation`/`installation_repositories` roda em `background_tasks` — depois do `200 OK` já devolvido ao GitHub — e `_publish_registrations_sequentially`/`_publish_unregistrations_sequentially` (`controller/installation_controller.py`) capturam a exceção por repositório, logam (`logger.exception`) e seguem pro próximo. Se o Kafka cair nesse momento, o lote inteiro daquele evento nunca chega a ser publicado: não há DLQ possível (a mensagem nunca saiu do captain-hook), não há retry, e o GitHub não reentrega porque o webhook, do lado dele, já teve sucesso. **Direção acordada em 2026-09-10:** em vez de só blindar o producer Kafka, simplificar removendo o Kafka desse fluxo inteiro — captain-hook passa a chamar o pequod diretamente por REST síncrono (mesmo padrão do §16), eliminando `repository.registered.v1`/`.unregistered.v1` e as DLQs correspondentes. Confirmado que são os únicos producer/consumer desses tópicos (sem terceiros dependendo deles). Plano de migração em construção.
- **Ideia para o radar (Leandro, 2026-09-10): um BFF (Backend for Frontend) dedicado ao `heimdall-dashboard`.** Hoje o dashboard fala REST direto com 3 backends (pequod, tars-ai, captain-hook — ver §18), cada um com seu client (`pequodApi.ts`/`tarsApi.ts`/`captainHookApi.ts`) e sua própria base URL exposta ao browser. Um BFF centralizaria essa composição (agregação de chamadas, autenticação de usuário final — hoje inexistente, ver item de auth mais abaixo — e isolamento de qual backend faz o quê) atrás de uma única API voltada pro frontend. Ainda não desenhado; só para não perder o fio quando for discutido.
- Estratégia de retenção de SARIF cru agora que o pequod é o agregador (`sarif_raw` já foi removido como coluna persistida no schema — recomposto via `finding_occurrences.raw_payload`)
- Métricas / observability formal (Prometheus? OTEL?) — moby-dick e pequod já expõem cada um seu próprio `GET /metrics/quality-gate`, mas não em formato Prometheus
- Plataforma definitiva pra prod (continuar VPS? K8s? Railway?)
- Auth de usuário final do heimdall-dashboard (hoje não há OAuth/JWT de usuário — só tokens de serviço entre backends)

**Resolvido desde a última revisão (2026-09-10):**
- ~~Storage central de findings~~ → pequod, com governança completa (§4)
- ~~2º/3º scanner~~ → semgrep, trivy e zap já ativos além do Sonar (§1)
- ~~Extração de findings dentro da scanner image~~ → concluído (§11)
- ~~Enriquecimento por IA~~ → TARS AI, via REST contra pequod (§17)
- ~~Correlação cross-scanner~~ → candidate clustering determinístico no pequod + clustering semântico no TARS AI
- ~~UI de triagem~~ → heimdall-dashboard (§18)
- ~~Security Baseline (`scope=branch`) em captain-hook/moby-dick~~ → confirmado em `main` desde 31/ago/2026 nos três repositórios (§15). Uma dúvida levantada ainda hoje sobre isso veio de uma checagem local com refs desatualizadas, não de uma regressão real — ver nota de processo em §15.

Atualizar este documento quando uma das perguntas abertas virar decisão.
