# Backlog de melhorias e débitos técnicos

> Este documento centraliza itens pendentes discutidos/anotados ao longo do
> desenvolvimento do ecossistema OdinEye ASPM (pequod, heimdall-dashboard,
> tars-ai, captain-hook, moby-dick), que ainda não foram implementados.
> Itens concluídos são removidos daqui (o histórico de decisão pode ficar
> registrado em PRs/issues referenciados).

## Bugs ativos

### #54 — Quality Gate Timeout Worker entra em loop infinito quando policy ausente
**Repo:** pequod · **Área:** `controller/quality_gate_timeout_worker.py` / `quality_gate_controller.py` / `quality_gate_security_controller.py`

Observado em 2026-09-01: merge na main, scanner nao completou, gate ficou
expirado. `quality_gate_timeout_worker` (ciclo ~15s) tenta finalizar via
`expire_due_quality_gates` → `_finalize_locked` → `evaluate_quality_gate_security`.
Como `security_gate_policies` estava vazia (perdida em reset de DB), a
funcao levanta `ValueError("nenhuma política ativa foi encontrada para o
Quality Gate")`. Excecao aborta a transacao, run NUNCA vira terminal,
proximo ciclo pega a MESMA run vencida, repete o erro — loop de log
infinito, `pequod.log` cresce sem parar.

**Root cause:** `security_gate_evaluations.policy_id` é `NOT NULL` (FK
pra `security_gate_policies`), e TODO caminho de finalizacao —inclusive
timeout/erro operacional, que nao é uma decisao de negocio sob rubrica—
passa por `evaluate_quality_gate_security`, que exige policy resolvida.

**Acoplamento identificado (discussao em andamento, ver secao "Sair do
gate PR"):** a tabela `security_gate_evaluations` mistura dois conceitos:
julgamento sob policy (decisao real de negocio) e falha operacional
(scanner quebrou, nada foi avaliado). Forcar (2) a depender de (1) é
category error e gera o loop.

**Nao iniciar fix sem novo pedido — pausado para discussao de fluxo
completo do ecossistema (ver secao abaixo).** Opcoes levantadas variam de
workaround rapido (seed de policy default + circuit breaker no worker)
a refactor de modelo (tabela separada para erro operacional, dissociada
de policy).

### #49 — Select de branch na Governance ainda exibe ID/SHA em produção
**Repo:** heimdall-dashboard · **Área:** `GovernanceWorkspace.tsx` / `BranchSelector.tsx`

Mesmo após PR#36 (labels legíveis + main/master como padrão) e PR#37 (filtro
`ref_type == "branch"`), o seletor de branch continua exibindo um valor que
parece SHA/ID em produção (VPS). Issue [heimdall-dashboard#38](https://github.com/OdinEye-FIAP/heimdall-dashboard/issues/38)
aberta com hipóteses:
- cache de build desatualizado na VPS (bundle antigo ainda servido);
- `ref_type` mal classificado no backend (pequod `infer_ref_type`);
- algum caminho no front que ainda usa o `ref` bruto sem passar por `loadBranches`.

### #30 — Riscos consolidados ainda fragmentados (casos gerais)
**Repo:** pequod · **Tipo:** bug

Usuário ainda encontra `consolidated_risk` separados que deveriam ser o
mesmo risco. O merge determinístico (`candidate_clustering_controller.py` /
`_auto_attach_to_existing_risk`, pequod#39) não está unificando todos os
casos esperados. Possíveis causas: `find_risk_by_target_on_connection` não
cobre todas as variações de categoria/pacote/arquivo esperadas, ou os riscos
foram criados antes da lógica determinística existir (fluxo antigo via IA)
sem reconciliação retroativa.

### #35 — Caso concreto de fragmentação: mesma regra, mesmo arquivo, buckets de linha diferentes
**Repo:** pequod · **Tipo:** bug

Exemplo real: 3 findings de `rule_id python:S6965` (SonarQube, "HTTP route
sem métodos explícitos"), mesmo arquivo `app/main.py`, mesmo commit
`a3be5e7`, linhas diferentes (32, 38, 155/175) — viraram **3**
`consolidated_risk` separados em vez de 1. Causa provável: `_correlation_key`
para `kind == "code"` usa bucket de 10 linhas (`int(line/10)*10`), então
ocorrências da mesma regra no mesmo arquivo em buckets diferentes nunca são
auto-anexadas ao mesmo risco. Caso concreto/reproduzível do item #30.

## Clustering / consolidated_risk — design maior (#19–#23)

> A maioria destes itens já foi **superada** pela solução determinística
> (pequod#39, que substituiu o `attach_existing` via IA), mas seguem listados
> por não terem sido formalmente fechados/reavaliados após a mudança.

### #19 — Mesmo pacote com CVEs em lotes diferentes gera riscos duplicados (REABERTO)
**Repo:** pequod/tars-ai

Casos reais reproduzidos: `requests 2.19.1` com `CVE-2018-18074` e
`CVE-2024-47081` viraram 2 `consolidated_risk` separados; `Werkzeug 2.0.3`
com `CVE-2024-49766` e `CVE-2023-25577` idem. Causa: `_auto_attach_to_existing_risk`
só roda no momento da criação do `candidate_cluster` (olhando se já existe
risco pra anexar), nunca retroativamente quando um risco novo é criado depois
para um cluster que já existia sem risco. Se dois CVEs do mesmo pacote são
processados pela IA (`propose_semantic_clustering`) em lotes/execuções
diferentes, cada um vira um risco distinto. pequod#46 só corrigiu o caso de
code/SAST (bucket de linha); o caso de dependency (mesmo pacote, CVEs
diferentes) segue em aberto. Decisões possíveis: (a) considerar todos os
clusters pendentes do mesmo repo/ref de uma vez no prompt, (b) implementar
reabertura/reprocessamento de risco existente quando surge cluster correlato
(merge tardio), ou (c) mudar a `correlation_key` do cluster pra já agrupar
por pacote.

### #20 — attach_existing não recalcula o risco existente
**Repo:** pequod

`technical_severity`/`confidence`/`summary`/`impact`/`recommendation` ficam
desatualizados quando o novo cluster anexado é mais crítico ou muda o
contexto. Precisa decidir regra de merge de campos (ex.: max severity,
recompute confidence, ou regerar summary).

### #21 — Heurística de related_risks pode gerar falso-positivo
**Repo:** pequod

`_RELATED_RISKS_SQL` usa só nome de pacote/arquivo como heurística — pode
sugerir merges falso-positivos (2 CVEs diferentes coincidindo no mesmo
arquivo por acaso). Hoje mitigado só pelo prompt da IA (não determinístico).

### #22 — attach_existing depende de AI_PROVIDER=groq
**Repo:** tars-ai

Único provider que implementa `propose_semantic_clustering`; Gemini/
HuggingFace herdam `NotImplementedError` da base. Se trocarem de provider no
futuro, a feature para de funcionar silenciosamente (sem erro visível, só
volta a criar risks duplicados).

### #23 — Auto-attach de categoria divergente não atualiza título/impacto/recomendação
**Repo:** pequod

Quando auto-attach anexa achado de categoria diferente à mesma
`consolidated_risk` (via match por pacote), o `summary` recebe nota
automática, mas `canonical_title`/`impact`/`recommendation` continuam sem
atualização — reescrevê-los exigiria reavaliar causa raiz combinada, hoje
não determinável só com dados estruturados.

## Frontend / UX

### #38 — JSON cru exibido em FindingDetails/ClusterDetails
**Repo:** heimdall-dashboard

Blocos de "Evidência técnica"/"Propriedades"/"Localização estruturada"
mostram JSON cru (`JSON.stringify` em `<pre>`) para o usuário final.
Melhorar a exibição formatando conforme o tipo de scanner/`location_type`.

### #39 — Enxugar FindingDetails.tsx
**Repo:** heimdall-dashboard

Remover blocos "Impacto" e badge "Confiança: X%" (pouco acionáveis); remover
bloco "Propriedades" (JSON cru do scanner); avaliar remover "Raciocínio
curto" (debug interno da IA) e considerar fundir "Mensagem original" +
"Resumo TARS". Manter "Recomendação". Simplificar "Metadados": remover
"Repo ID" (UUID sem uso prático) e unificar "Tipo da localização" +
"Localização" em uma única linha. Aplicar também em `ClusterDetails.tsx`
onde fizer sentido.

### #40 — Renomear "Cluster" para "Risco Consolidado" no front
**Repo:** heimdall-dashboard

`ClusterDetails.tsx` → `RiskDetails.tsx`, `ClusterTable.tsx` → `RiskTable.tsx`,
`ClusterDashboardCards` → possivelmente `RiskDashboardCards`, variáveis
`clusterAnalyses`/`selectedCluster`. Motivo: "Cluster" é resíduo histórico do
agrupamento técnico bruto (`finding_cluster`/`candidate_cluster`, anterior à
IA); o conceito exibido hoje na aba "Riscos consolidados" é o
`consolidated_risk`. Avaliar escopo: só componentes de UI, ou também tipos TS
(`FindingCluster`, `ClusterAnalysis` em `types/finding.ts`) e nomes de
estado/props em `App.tsx`.

## Design — itens adiados (aguardando discussão)

### #41 — Categoria semântica unificada entre scanners
**Repo:** pequod · **Status:** pausado, aguardando validação do usuário

Repensar agrupamento para NÃO particionar por `scanner_class` (SAST/DAST/
SCA/IaC). Hoje `_category()` deriva de `rule_id`+`scanner_class`,
`_correlation_key()` inclui `scanner_class` explicitamente, e
`find_risk_by_target_on_connection` compara `file_path`+`category` (já
carregando a marca do scanner). Resultado: SAST e DAST apontando o MESMO
problema no MESMO arquivo/endpoint nunca são unificados no mesmo
`consolidated_risk`. Precisa desenhar noção de "categoria semântica"
unificada entre scanners (ex.: "SQL Injection" independente do scanner de
origem) antes de mudar `correlation_key`/`category`/`find_risk_by_target`.
Achado da investigação: correlacionar entre tipos de scanner exige taxonomia
semântica (CWE-like) + match frouxo entre tipos de localização incompatíveis
(`file_path` vs `endpoint` vs `package`), não só remover `scanner_class` da
chave. Escopo maior que o #19 (que é só sobre mesmo scanner, mesmo pacote,
momentos de IA diferentes).

### #42 — Renomear finding_cluster/candidate_cluster
**Repo:** pequod/tars-ai · **Status:** adiado até o rename do front (#40)

Considerar renomear `finding_cluster`/`candidate_cluster` (pequod) e
`cluster_repository.py` (tars-ai) para algo que não confunda com
`consolidated_risk` — ex.: `finding_group`/`technical_grouping`. Esse
conceito é o agrupamento técnico BRUTO (pré-IA, só por `correlation_key`),
diferente de `consolidated_risk` (risco de fato decidido). Não renomear
para algo relacionado a "risco", pois criaria confusão nova. Escopo:
`schema.sql` (`finding_cluster`/`finding_cluster_member`/
`finding_cluster_ai_analysis`), `candidate_clustering_controller.py`,
`cluster_repository.py`, contratos pequod↔tars-ai↔front.

## Documentação

### #43 — Documento de referência do schema do pequod
**Repo:** aspm-docs

~~Criar `reference/database-schema.md` listando tabelas do pequod (finding,
candidate_cluster, consolidated_risk, etc.) com colunas e contratos~~ — já
existe hoje (`docs/reference/database-schema.md`, criado via PR#9). Manter
atualizado conforme o schema evolui (ex.: remoções feitas em pequod#49).

## Desnormalização de schema (discussão iniciada no item #44, já concluído)

### #45 — quality_gate_runs
**Repo:** pequod

(a) `decision` duplica `security_gate_evaluations.decision` via
`evaluation_id` — mesmo padrão do #44 (já resolvido): como a run não muda
após concluída, é só performance de listagem, candidato a remover.
(b) `repository_id`/`repository_full_name`/`installation_id` duplicam
`applications`, MAS aqui pode ser **snapshot histórico intencional** (o
repo pode ser renomeado no GitHub depois, e a run antiga deveria manter o
nome de quando rodou) — avaliar se é desnormalização proposital antes de
mexer.

### #48 — Campos decorativos em applications
**Repo:** pequod

`applications.business_criticality`/`exposure`/`team_name` são persistidos
e expostos na API REST mas NUNCA são lidos por nenhuma regra de negócio,
policy ou `security_gate_evaluator.py` — são campos decorativos hoje,
coletados do GitHub/registro mas sem consumidor funcional. Avaliar se faz
sentido manter (dado para futuro uso em policies por criticidade) ou
remover até haver caso de uso real.

## Sair do gate PR — discussão em andamento

> Discussão iniciada em 2026-08-31 sobre expandir o ecossistema para além do
> gate no PR: scan contínuo na main, remediation proativa (PRs automáticos de
> upgrade/fix), e Quality Gate atrelado a branch (não só a PR). Registro
> abaixo separa o que já ficou decidido nesta rodada do que ainda está em
> aberto para próximas conversas.

### Decisões fechadas nesta discussão

- **Sonar Community + `sonar-db` ficam.** `sonar-db` = cache stateful
  sacrificável (não é fonte de verdade). Sem backup, `docker volume rm` sem
  cerimônia. Referência: DECISIONS §2/§3.
- **`pequod` = source-of-truth.** Sonar é worker descartável. UI Sonar vira
  utilitário, não workflow principal. Dev consome check_run (PR) + heimdall
  (visão geral).
- **Substituir Sonar por Semgrep está fora de escopo.** Ecossistema já roda
  4 scanners (Sonar, Semgrep, Trivy, ZAP) cobrindo dimensões distintas
  (SAST/SAST/SCA+secrets+IaC/DAST). Semgrep complementa Sonar, não substitui.
- **MinIO adiado.** Dev reseta `pequod` DB frequente durante MVP, então
  crescimento de `sarif_raw` é tolerado. Quando reset deixar de ser opção
  (ex.: pós-MVP com histórico importando), subir MinIO no compose (~1-2
  dias de trabalho — schema `sarif_uri`, adapter `sarif_store.py`, sem
  backfill se histórico já foi resetado).
- **Sonar Community é suficiente** — não vale upgrade para Developer Edition
  ($$). PR decoration bonito do Sonar UI não é requisito (check_run do
  `moby-dick` cobre); limite de 1 branch por projeto no Community é
  irrelevante porque `pequod` discrimina por `ref`.

### Em aberto (próximas discussões)

- **Contrato `scope: pr|branch`** em `JobContext` + `QualityGateEvent`
  (aditivo, default `pr` para compat). Deve permitir mesmo pipeline rodar
  como gate no PR OU como baseline em branch, com sinks diferentes.
- **Quality Gate por branch = "Security Baseline".** Nome distinto para
  reforçar que na `main` NÃO é gate literal (não bloqueia merge — não tem
  merge). É monitor/alarm: reabre Issue no repo, cria check_run em commit,
  publica evento de regressão para consumers.
- **`ahab`** — novo serviço scheduler (APScheduler ou equivalente) que
  itera repos registrados e dispara baseline periódico via
  `jobs.orchestration` com `context.trigger=main_baseline`. Também consumer
  potencial de `finding.created` para trigger de remediation.
- **Remediation bot** — quem abre PR de upgrade de lib / autofix SAST?
  Opções: (a) Renovate self-hosted para SCA, (b) autoral no `ahab` para
  SAST autofix via SARIF `fixes`, (c) híbrido.
- **Sink de main scan** — check_run em commit (feio mas funciona), Issue no
  repo alvo agrupando findings críticos, notification externa? Provável:
  Issue no repo + evento Kafka `baseline.regressed` para consumers
  decidirem.
- **IA no PR body** — TARS produz summary/impact/recommendation. Colocar no
  corpo do PR ou manter body objetivo (CVE + versão) + link para heimdall?
  Risco: hallucination visível quando IA erra.
- **Rate limit do remediation bot** — default proposto: máximo N PRs
  abertos simultâneos por repo, batch semanal de deps, dedup por
  `(rule_id, file, fix_hash)`.
- **`sonar.dbcleaner.weeksBeforeDeletingAllSnapshots=4`** — aplicar agora
  ou adiar? Se dev já reseta `pequod`, provavelmente também reseta
  `sonar-db` no mesmo ciclo; retention agressiva pode ser aplicada quando
  reset deixar de ser opção.

### #52 — Heimdall: aba "Quality gate runs" nao discrimina scope=branch de scope=pr

Levantado em 2026-09-01 apos primeiro push direto na `main` de repo de
teste. Heimdall lista o run scope=branch (Security Baseline) na mesma
tabela dos runs scope=pr, sem coluna/badge de discriminacao. Como o run
scope=branch nao tem `pull_request_number`, a linha aparece como se fosse
"um PR fantasma" — confuso pro dev.

**Sintoma observado:** aba "Quality gate runs" no heimdall exibe commit
direto na main como se fosse PR run.

**Contexto tecnico:** o pequod ja persiste `scope` e `branch_name` na
tabela `quality_gate_runs` (schema atualizado no PR#50). O que falta e
o front expor esses campos: badge "Baseline" vs "PR", coluna
`branch_name` visivel, filtro por scope.

**Escopo minimo:**
- Coluna extra na tabela de runs no heimdall — mostrar `branch_name`
  quando `scope=branch`, mostrar `#PR` quando `scope=pr`.
- Badge visual (ex.: cor diferente) discriminando os dois tipos.
- Filtro opcional por scope na tela.

**Nao iniciar sem novo pedido.** Aguardando priorizacao junto com
outros itens de front (#38/#39/#40).

### #53 — Scan inicial automatico ao registrar repositorio no GitHub App

Levantado em 2026-09-01. Hoje o Security Baseline scope=branch so dispara
em `push` na default branch. Isso significa que:
- Repo recem-instalado no GitHub App **so vai ter baseline apos o
  proximo push** — pode demorar dias em repos maduros com merges
  pouco frequentes.
- Repos legado que instalam o app "hoje" ficam invisiveis ate alguem
  mexer no codigo.

**Proposta:** ao instalar o GitHub App (webhook `installation.created`
ou `installation_repositories.added`), captain-hook dispara
automaticamente um baseline inicial na default branch — reusa exatamente
o mesmo pipeline scope=branch que hoje dispara em push.

**Depende de** (ou anda junto com) — **Scaffold PR** discutido em
paralelo: quando o app e instalado num repo, alem do baseline inicial,
abrir um PR de scaffold com arquivos de configuracao esperados pelo
ecossistema (ex.: `.aspm.yml`, workflows GitHub Actions se aplicavel,
issue templates com label `aspm-risk`). O baseline inicial e o PR
scaffold sao os dois "hello-world" que o repo recebe ao entrar no
ecossistema.

**Bonus:** trigger manual via heimdall (botao "Rodar baseline agora")
resolve o mesmo problema para repos que ja estao instalados mas sem
baseline vigente — util em recovery de reset de DB.

**Nao iniciar sem novo pedido.** Requer alinhamento previo sobre o
que exatamente vai no Scaffold PR.

### Consolidacao de contexto Git em servico dedicado — adiado, nao iniciar sem novo pedido

Ideia levantada durante esta discussao: extrair para um servico proprio toda
responsabilidade que hoje **fala com github.com** — hoje espalhada entre
moby-dick (mint installation token da GitHub App, `create_check_run` /
`update_check_run`) e futuros consumidores (`ahab` para trigger de baseline
na main, remediation bot para abrir PRs automaticos).

Motivacao: se `ahab` e remediation nascerem sem consolidar, cada um vai
duplicar auth logic, cache de token, e a chave privada da GitHub App vai
morar em N lugares (piora superficie de exposicao + rotacao/auditoria).

**Escopo tentativo** (mais conservador): novo servico cuida apenas de
    - mint + cache de installation token,
    - abstracao HTTP para chamadas GitHub API (check_run, PR, comment, issue,
      label),
    - rate limit centralizado (GitHub App tem 5k reqs/h por installation),
    - observabilidade das chamadas.

**Fora deste escopo** — cada um continua no dono natural:
    - clone/checkout continua nos scanners (nao faz sentido centralizar),
    - scheduler fica em `ahab`,
    - logica de "quando abrir PR" fica no remediation bot,
    - lifecycle do container fica no moby-dick.

**Fase 1 sugerida** (curto prazo, sem impacto funcional): criar servico
copiando codigo do moby-dick, moby-dick vira cliente. Chave privada
migra. Deploy separado.

**Fase 2 / 3:** `ahab` e remediation ja nascem clientes do servico novo,
sem duplicacao.

**Status:** anotado, aguardando decisao explicita para retomar. Nao
comecar sem novo pedido. Escopo/timing/nome ficam para quando retomarmos
(candidatos de nome discutidos: `queequeg`, `starbuck`).

### Escopo consciente que fica de fora nesta rodada

- **Storage retention estratégico** — só volta quando MinIO subir.
- **SBOM ingest** — Trivy emite CycloneDX; ingest formal fica para depois
  do baseline por branch estabilizar.
- **Policy engine** — regras `severity × repo_tier × scanner_class`
  ficam para pós-MVP.
- **Cross-scanner dedup semântico** — item #41 do backlog cobre isso.

---

## Ideias futuras (não validadas — não iniciar sem confirmação explícita)

### Página de Organizações
**Repo:** heimdall-dashboard/pequod · **Status:** bloqueado, aguardando validação

Hoje não existe entidade `organization` no pequod, só `owner_name`/
`team_name` como texto livre em `applications`.
- **Fase 1** (rápida, sem backend): agrupar applications por `owner_name`
  no frontend.
- **Fase 2** (futura, maior): criar tabela `organizations` + FK em
  `applications` para permitir RBAC/políticas por org.

---

## Itens já resolvidos (referência histórica)

| Item | Resolução |
|---|---|
| #27 | Branch selector na Governance — heimdall-dashboard#35 (parcialmente corrigido por #36/#37, ver bug #49 acima) |
| #44 | Remoção das 5 colunas de contagem em `security_gate_evaluations` — pequod#49 |
| #46 | Remoção de `finding.sarif_raw` (agora via subquery em `finding_occurrences`) — pequod#49 |
| #47 | Infra de delivery/retry de alerts já era código morto removido; só docs desatualizadas — aspm-docs#10 |
