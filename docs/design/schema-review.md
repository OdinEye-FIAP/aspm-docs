# Revisão do schema/fluxo de dados do Pequod

!!! warning "Documento de discussão — nenhuma decisão foi implementada ainda"
    Este documento acumula uma revisão em andamento do schema do Pequod, buscando enxugar
    tabelas redundantes e simplificar o fluxo de dados. **Não é uma decisão fechada** — é um
    rascunho vivo enquanto o schema é discutido item a item. Nenhuma mudança de schema/código
    descrita aqui foi implementada. Ver também [Schema do banco](../reference/database-schema.md)
    para o schema atual (real) completo.

## Contexto / motivação

Ao documentar o schema (22 tabelas), percebemos vários padrões de duplicação de dados
e tabelas intermediárias que talvez não precisem existir da forma como estão hoje.
Este documento existe para não perder o fio da meada enquanto discutimos item a item.

## Fluxo de dados atual (confirmado no código)

```
1 repositório (applications)
    │
    ├──< N quality_gate_runs (1 "vigente" por PR aberto)
    │         │
    │         └──< N quality_gate_scanner_runs (1 por scanner esperado no PR)
    │                   │
    │                   └── scan_id (FK opcional → scans)
    │
    └──< N scans (1 execução de 1 scanner sobre 1 ref/commit)
              │
              ├──< scan_artifacts (relatório bruto do scan, ex: SARIF completo)
              │
              └── moby-dick publica evento Kafka `findings.raw`
                        (payload: SARIF bruto do scan, dentro do campo `sarif`)
                        │
                        ▼
                  pequod consome (ingest_controller.process_findings_raw)
                        │
                        ├── sarif_to_findings() → converte em N `Finding` (findings técnicos)
                        │        - upsert em `finding` por (fingerprint, repo_id)
                        │        - se já existe, SOBRESCREVE (last_seen_at, sarif_raw, etc.)
                        │
                        └──< finding_occurrences (snapshot imutável: este finding, neste scan)
                                 - 1 linha por (finding_id, scan_id), nunca sobrescrita
```

Confirmações da conversa:

- Repositório → N quality gates → N scans → SARIF → `sarif_to_finding` → N findings técnicos.
  Está correto, é a hierarquia real implementada.
- O SARIF bruto viaja pelo Kafka (`findings.raw`, campo `sarif` do evento) publicado pelo moby-dick,
  e o pequod é quem grava esse conteúdo no banco (em até 3 lugares — ver item #1 abaixo).

## Itens em discussão

### #0 — `findings.raw` via Kafka vs. HTTP direto (moby-dick → pequod)

**Status:** discussão concluída, recomendação registrada — não implementado.

O usuário questionou por que `findings.raw` (moby-dick → pequod) usa Kafka, já que moby-dick já é
um serviço assíncrono e o próprio momento de publicação (fim do scan) não parece exigir uma fila.
Reforça o ponto o fato de já existir, hoje, comunicação **HTTP direta** entre os dois serviços para
outra finalidade: `moby-dick/diplomat/http_out/pequod_client.py` chama
`POST /api/v1/internal/quality-gates/{workflow_id}/evaluate` no pequod diretamente, sem Kafka.

**Motivos originalmente documentados para Kafka (`decisions.md` §12/§14):**

1. Desacoplamento de disponibilidade — se o pequod estiver fora do ar, o Kafka retém a mensagem.
2. Fan-out futuro — outros consumidores do mesmo tópico (ex: auditoria, data lake) sem o moby-dick
   precisar saber quem mais consome.
3. Backpressure — picos de scans terminando ao mesmo tempo são absorvidos pela fila.

**Por que esses motivos não se sustentam hoje, segundo a análise:**

- **Fan-out (2):** hoje existe exatamente **1 consumidor real** de `findings.raw` — o próprio
  pequod. É especulativo, não uma necessidade atual.
- **Backpressure (3):** o pequod já é FastAPI (assíncrono nativo) com pool de conexões `asyncpg` —
  a concorrência já é absorvida pelo próprio serviço, sem precisar de fila externa como buffer.
- **Disponibilidade (1):** resolvido de forma equivalente com HTTP + retry/backoff — mecanismo que
  **já existe** no `pequod_client.py` para o outro endpoint (`evaluate_quality_gate`). A única
  lacuna real é: se o **moby-dick** cair no meio do retry, a mensagem em memória se perde (o Kafka
  não teria esse problema, pois a mensagem já estaria persistida no broker antes do consumo).

**Conclusão / recomendação:** trocar `findings.raw` de Kafka para uma chamada HTTP direta
moby-dick → pequod (ou via um BFF dedicado, se a plataforma evoluir para múltiplos
consumidores/serviços de borda), com retry/backoff no client — no mesmo padrão já usado para
`evaluate_quality_gate`. Isso simplifica a infraestrutura (menos um tópico Kafka + menos um
consumer a operar) sem perda de garantias relevantes ao estado atual do sistema. Se, no futuro,
surgir necessidade real de múltiplos consumidores do resultado do scan, o Kafka pode voltar a
fazer sentido nesse ponto específico — mas isso deve ser decidido quando/se essa necessidade
aparecer, não antecipado hoje.

**Risco residual aceito:** perda da mensagem se moby-dick cair durante o retry (sem persistência
teimosa própria). Mitigável com uma fila leve (outbox/BFF) se o usuário quiser essa garantia sem
reintroduzir Kafka.

### #1 — Triplicação do payload SARIF (`finding.sarif_raw` / `scan_artifacts.inline_content` / `finding_occurrences.raw_payload`)

**Status:** análise concluída, aguardando decisão de implementação.

O mesmo conteúdo (ou partes dele) acaba armazenado em 3 lugares:

1. `scan_artifacts.inline_content` — o relatório SARIF **inteiro** daquele scan.
2. `finding.sarif_raw` — o resultado **daquele finding específico** dentro do SARIF,
   mas **sobrescrito a cada novo scan** que toca esse finding (upsert por fingerprint+repo_id).
3. `finding_occurrences.raw_payload` — o mesmo conteúdo de (2), mas **snapshot imutável por scan**
   (chave única `finding_id + scan_id`, nunca sobrescrito).

**Achado-chave:** `finding.sarif_raw` é sempre igual ao `raw_payload` da ocorrência mais recente
daquele finding em `finding_occurrences`. É 100% derivável via:

```sql
SELECT raw_payload FROM finding_occurrences
WHERE finding_id = $1 ORDER BY observed_at DESC LIMIT 1
```

**Único consumidor de `finding.sarif_raw` hoje:** `GET /findings/{id}` (`findings_handler.py` →
`query_controller.get_finding` → `finding_repo.get_by_id`), leitura direta sem JOIN.

**Proposta:** remover a coluna `finding.sarif_raw`, trocar o handler para buscar via
`finding_occurrences` (JOIN/subquery pelo finding_id, ORDER BY observed_at DESC LIMIT 1).
Ganho: elimina duplicação real de um JSON potencialmente grande, e remove a inconsistência de
"qual desses 2 lugares é a fonte de verdade" (resposta: `finding_occurrences` sempre foi).

**Ainda em aberto:** decidir se implementamos agora ou se ainda dá pra achar mais casos
parecidos antes de mexer (ver #2, tabelas intermediárias).

### #2 — Tabelas intermediárias entre repositório e scan (quality_gate_runs / quality_gate_scanner_runs)

**Status:** análise concluída — **não são redundantes**, mas o motivo de existirem separadas de `scans` não é óbvio à primeira vista. Detalhado abaixo.

**Por que `quality_gate_scanner_runs` existe separado de `scans`:**

O evento que dispara o Quality Gate a acompanhar um PR chega **antes** de existir qualquer SARIF/scan
persistido. O CI (GitHub Actions) inicia N jobs de scanner em paralelo para o PR, e cada scanner
"anuncia" seu progresso (`pending` → `running` → `completed`/`failed`) via eventos correlacionados por
`job_id` (identificador do job do orquestrador de CI, não do banco). Só quando o scanner efetivamente
termina e o SARIF é ingerido (`findings.raw` consumido) é que existe uma linha real em `scans`.

Ou seja:

- `quality_gate_scanner_runs` = "o scanner X foi anunciado/está rodando/terminou para este PR"
  (pode existir e mudar de status ANTES de qualquer scan/SARIF existir).
- `scans` = "um scan realmente aconteceu e produziu (ou não) findings" (fato consumado).
- A correlação entre os dois é feita depois, via `attach_scan_by_job_id()` (chamado quando a ingestão
  do SARIF é persistida), preenchendo `quality_gate_scanner_runs.scan_id`.

Isso resolve um problema real: sem essa tabela intermediária, não haveria como saber, no meio do
processo, "quais scanners eu esperava, quais já terminaram, quais ainda faltam" — que é exatamente
o que decide quando o Quality Gate pode avaliar (`_assert_expected_scanner`, timeout por
`quality_gate_runs.expires_at`).

**Conclusão preliminar:** a tabela não é fundível com `scans` sem perder a capacidade de rastrear
"scanner anunciado mas ainda sem scan associado" (estado transitório importante para timeout/gate).
Mas pode haver espaço para reduzir colunas duplicadas entre as duas (ex: `scanner_class`,
`findings_count` já existem em `finding`/`scans` de outra forma) — não aprofundado ainda.

**Próxima pergunta a explorar:** dado que `quality_gate_scanner_runs` cumpre um papel de
"placeholder/rastreamento de progresso", será que faz sentido ela viver tão perto do domínio de
`scans`, ou seria mais claro se pensarmos nela como parte do domínio "Quality Gate" (workflow de CI),
enquanto `scans`/`scan_artifacts`/`finding*` seriam o domínio "Findings" — dois fluxos que se
encontram apenas via `scan_id`? Isso conversa com o pedido do usuário de reorganizar o entendimento
como Organização → Repositório → Quality Gate → (scanners → scans → findings) → Risco Consolidado.

### #2b — Proposta do usuário: fundir `quality_gate_scanner_runs` dentro de `scans` (entidade genérica de "scan")

**Status:** análise concluída — **não é seguro fundir totalmente** *(conclusão revisada em #2c)*.

**A ideia:** ter uma única entidade `scan` capaz de existir num estado "anunciado" (pending/running,
sem SARIF ainda) e evoluir para "completo" (com SARIF), eliminando `quality_gate_scanner_runs` como
tabela separada — o Quality Gate apenas listaria/referenciaria `scans`.

**Achado que destrava parte do problema:** `scans.external_run_id` já é, na prática, o mesmo
`job_id` usado para correlacionar `quality_gate_scanner_runs` com o CI (`model/scan.py`, `Scan.from_event()`).
Ou seja, a chave de correlação entre "anúncio do CI" e "scan real" já existe hoje — só está
espalhada em duas tabelas com nomes diferentes (`job_id` vs `external_run_id`) para o mesmo conceito.

**Pergunta que decide a fusão, feita ao usuário:** "todo scan nasce dentro de um Quality Gate/PR,
ou existem scans fora desse contexto (ex: scan agendado na branch main, sem PR)?"
**Resposta do usuário: existem scans fora do contexto de Quality Gate** (agendados, branch principal, etc.)

**Por que isso parecia impedir a fusão total:** se `quality_gate_scanner_runs` fosse absorvida por
`scans`, toda linha de `scans` passaria a carregar colunas que só fazem sentido dentro de um
Quality Gate (`error_code`, `error_message`, `quality_gate_run_id`, status do ponto de vista do
*gate* e não do *scan em si*). Isso "vazaria" o domínio de Quality Gate (CI/workflow) para dentro
do domínio de Scan/Finding, contaminando semanticamente uma tabela que hoje é (aparentemente)
agnóstica de PR — **mas essa premissa se mostrou errada, ver #2c**.

**Recomendação inicial (meio-termo, não fusão total, depois superada por #2c):**

1. Manter as duas tabelas (pelo motivo acima), mas **parar de duplicar campos** que já existem em
   `scans` assim que `quality_gate_scanner_runs.scan_id` é preenchido — hoje `scanner_class`,
   `findings_count`, `started_at` existem nas duas tabelas e ficam redundantes a partir do momento
   do link. Ler esses campos de `scans` via JOIN quando `scan_id IS NOT NULL`, ao invés de manter
   cópias.
2. Antes do link existir (scanner anunciado, sem `scan_id` ainda), `quality_gate_scanner_runs`
   continua sendo o único lugar onde esse estado pode existir.
3. `job_id`/`external_run_id` são conceitualmente a mesma coisa (identificador do job de CI) —
   vale considerar renomear para o mesmo nome nas duas tabelas.

### #2c — Revisão: `quality_gate_runs` já foi desenhado para ser genérico (PR ou não)

**Status:** conclusão revisada — a fusão volta a ser viável, com um desenho concreto proposto.

O usuário questionou a recomendação #2b com um argumento válido: "por que `error_code` não
poderia existir num scan da branch `main`? Main também precisa de checks. Eu poderia querer
pesquisar por branch em governança e ver os dados da main."

Investigando o código para responder, dois achados mudam a conclusão:

1. **Hoje, na prática, só existe o caminho de PR.** `captain-hook/controller/pull_request_controller.py`
   é o único lugar que dispara `quality-gate.workflow.started` — não há listener de `push` (branch
   main) nem de `schedule` hoje. Ou seja, o cenário "scan solto fora de Quality Gate" não é real
   hoje, é hipotético/futuro.
2. **Mas o schema já foi desenhado pensando nisso.** `quality_gate_runs.pull_request_number` é
   `bigint` **nullable** (sem `NOT NULL`), e o model Python (`model/quality_gate_run.py`) já trata
   `pull_request_number: int | None = None` como caso válido. Ou seja, `quality_gate_runs` já é,
   por design, um **"CI Run" genérico** (pode ou não ter PR associado) — não uma tabela exclusiva
   de pull request, mesmo que hoje só seja populada via PR.

**Isso muda a conclusão de #2b:** o receio de que `error_code`/`quality_gate_run_id` "vazariam"
o domínio de Quality Gate para dentro de `scans` só fazia sentido se scans fora de PR não tivessem
Quality Gate Run. Como o desenho já prevê Quality Gate Run sem PR (ex: run "agendado" ou "de push
na main", sem `pull_request_number`), **todo scan, presente ou futuro, nasce dentro de um Quality
Gate Run** — logo, a hierarquia pedida pelo usuário (Quality Gate lista N Scans, cada Scan tem N
Findings, Findings viram Risco Consolidado) é válida como regra geral, não como caso particular de PR.

**Desenho proposto (fusão real, com correlação por `quality_gate_run_id`):**

```
quality_gate_runs (workflow/CI run — com ou sem pull_request_number)
    │
    └──< scans (FK quality_gate_run_id NOT NULL)
              - status: pending → running → completed/failed/timed_out
              - job_id (renomeado de external_run_id, mesmo conceito)
              - error_code / error_message (preenchidos só se status=failed)
              - scan_id populado incrementalmente: nasce no anúncio do CI
                (scanner.completed/started, sem SARIF ainda), e ganha os
                campos derivados do SARIF quando findings.raw é ingerido
```

Isso elimina `quality_gate_scanner_runs` como tabela separada: `scans` passa a ser a única fonte
de verdade tanto para "scanner anunciado/rodando" quanto para "scan com SARIF processado". A
correlação por `job_id` (hoje `external_run_id` em `scans`, `job_id` em `quality_gate_scanner_runs`)
já é a mesma coisa — vira uma coluna só.

**O que precisa ser resolvido para essa fusão funcionar (pontos técnicos, não são bloqueadores,
mas precisam de decisão de implementação):**

- `scans.application_id` e `scans.tool_id` são hoje `NOT NULL` — no momento do anúncio
  (`scanner.completed` chegando antes do SARIF), talvez não se tenha `tool_id` ainda resolvido
  (só o nome do scanner). Precisaria permitir `tool_id` nullable até a ingestão do SARIF, ou
  resolver `tool_id` a partir do nome do scanner no momento do anúncio (parece viável, já que
  `security_tools` é um catálogo fixo).
- A lógica de "N esperados vs M completados" (`_assert_expected_scanner`, timeout via
  `quality_gate_runs.expires_at`) passaria a contar linhas de `scans` filtradas por
  `quality_gate_run_id`, ao invés de `quality_gate_scanner_runs` — mudança direta, sem perda de
  funcionalidade aparente.
- `scans` ganharia uma FK `quality_gate_run_id` (NOT NULL, diferente do desenho atual onde `scans`
  não tem nenhuma referência a Quality Gate).

**Conclusão final:** a fusão é recomendada. Ela simplifica a hierarquia para exatamente o que o
usuário descreveu: Quality Gate → N Scans → N Findings → Risco Consolidado, sem uma tabela paralela
"fantasma" cumprindo um papel que `scans` já pode cumprir, desde que:

- (a) `scans` ganhe `quality_gate_run_id` (FK), e
- (b) `tool_id`/`application_id` tenham um caminho para serem preenchidos (ou tolerarem estado
  temporário) entre o anúncio do CI e a ingestão do SARIF.

## Fluxo de dados reorganizado (visão pedida: Org → Repo → Quality Gate → ...)

Reagrupando as mesmas tabelas pela ordem que faz mais sentido para entender a regra de negócio
(ao invés da ordem em que aparecem no `schema.sql`):

```
Organização (GitHub) ─── agrupamento em runtime de applications.owner_name (NÃO é uma tabela)
    │
    └── Repositório = applications (1 linha = 1 repo registrado via GitHub App)
              │
              └── Quality Gate Run = quality_gate_runs (1 por PR "vigente", ou por CI run sem PR)
                        │
                        ├──< Quality Gate Scanner Run = quality_gate_scanner_runs
                        │         (1 por scanner esperado; nasce ANTES do scan existir,
                        │          rastreia pending/running/completed via job_id do CI)
                        │              │
                        │              └── scan_id (preenchido depois, via attach_scan_by_job_id)
                        │
                        └── evaluation_id → security_gate_evaluations (resultado da policy)
                                  │
                                  └──< security_gate_items (detalhe por finding/cluster)

Scan = scans (1 execução real de 1 scanner sobre 1 ref, SÓ existe quando o SARIF chega)
    │
    ├──< scan_artifacts (relatório bruto, ex: SARIF completo)
    │
    └── (ingestão do findings.raw) ──< finding (upsert por fingerprint+repo_id)
                                            │
                                            ├──< finding_occurrences (snapshot por scan)
                                            ├──< finding_identifiers (CVE/CWE)
                                            ├──< finding_ai_analysis
                                            └──< finding_cluster_member ──> finding_cluster
                                                                                  │
                                                                                  └──< consolidated_risk_candidate
                                                                                            │
                                                                                            ▼
                                                                                  consolidated_risk (risco final)
```

> Nota: este diagrama reflete o estado **atual** (duas tabelas separadas). O desenho proposto em
> #2c fundiria `quality_gate_scanner_runs` para dentro de `scans` — ver seção acima.

### #3 — Tabelas satélite de `finding` (finding_occurrences / finding_identifiers / finding_ai_analysis / finding_cluster_member): todas precisam ser tabelas separadas?

**Status:** análise concluída para 2 das 4; outras 2 têm decisão pendente do usuário.

O usuário questionou por que existem 4 tabelas satélite de `finding` ao invés de campos na própria
tabela. A resposta varia por tabela — duas são genuinamente 1:N, duas são hoje 1:1 (`UNIQUE(finding_id)`).

**`finding_occurrences` — 1:N real, não fundível.** Um finding (por fingerprint) pode ser detectado
em múltiplos scans ao longo do tempo (aparece, some, reaparece). Cada linha é uma detecção em um
scan específico, com sua própria evidência/localização. É histórico genuíno — colapsar em `finding`
perderia a distinção entre ocorrências.

**`finding_identifiers` — 1:N real, não fundível.** Um finding pode ter múltiplos identificadores
externos simultâneos (ex: CVE-2023-1 + CVE-2023-2 + CWE-79 para o mesmo finding). Não cabe em
colunas fixas de `finding` sem virar array/jsonb (o que perderia a capacidade de indexar/filtrar
por identificador individual).

**`finding_ai_analysis` — hoje é 1:1 (`UNIQUE(finding_id)`), candidata a fusão.** Cada finding tem
no máximo uma análise de IA hoje (recomendação, prioridade, confiança, modelo) — não há histórico
de reanálises, é sobrescrita. Se essa regra for permanente, faz mais sentido como colunas nullable
dentro de `finding` (`ai_recommendation`, `ai_priority`, `ai_confidence`, `ai_model_name`),
eliminando um JOIN em toda consulta que precisa da análise.

**`finding_cluster_member` — hoje é 1:1 (`UNIQUE(finding_id)`), candidata a fusão.** Apesar do nome
sugerir tabela de associação N:N, a constraint `UNIQUE(finding_id)` (não apenas `UNIQUE(cluster_id,
finding_id)`) mostra que, na prática, cada finding pertence a no máximo 1 cluster hoje. Se essa
regra for permanente, poderia virar `finding.cluster_id` (FK nullable), eliminando a tabela inteira.

**Pergunta em aberto (usuário optou por não responder ainda):** existe plano de, no futuro, um
finding ter mais de uma análise de IA (histórico de reanálises) ou pertencer a mais de um cluster
simultaneamente (ex: clusterização por critérios diferentes rodando em paralelo)? Se sim, manter as
tabelas separadas como estão evita uma migração dolorosa depois. Se não (regra 1:1 é definitiva),
a fusão em `finding` é recomendada.

**Conclusão parcial:** `finding_occurrences` e `finding_identifiers` ficam como estão (1:N genuíno).
`finding_ai_analysis` e `finding_cluster_member` aguardam decisão do usuário sobre planos futuros
antes de decidir fundir ou manter.

## Outros itens registrados (não aprofundados ainda)

- `security_gate_evaluations`: as 5 colunas de contagem (`total_findings`, `total_clusters`,
  `blocking_items`, `warning_items`, `ignored_items`) são denormalização pura, deriváveis via
  agregação sobre `security_gate_items`. Como as evaluations são imutáveis após escritas, isso
  nunca fica desatualizado — é uma escolha de performance de leitura, não de auditoria.
- `quality_gate_runs.decision` duplica `security_gate_evaluations.decision` (mesmo padrão acima).
  `repository_id`/`repository_full_name`/`installation_id` em `quality_gate_runs` podem ser
  um snapshot histórico intencional (o repo pode ser renomeado depois) — avaliar antes de mexer.
- `alerts`: tem infraestrutura de delivery/retry (`delivery_channel`, `destination`, `attempts`,
  `max_attempts`, `next_retry_at`, `last_error`, `sent_at` + funções `create_or_update_alert`,
  `claim_alerts_for_delivery`, `mark_alert_sent`, `mark_alert_failed`) nunca chamada em produção
  fora de testes — o único caminho real de escrita é o específico de falha de Quality Gate
  (`upsert_active_alert_on_connection`, chamado direto por `security_gate_controller.py`).
- `applications.business_criticality`/`exposure`/`team_name`: persistidos e expostos via API,
  mas nunca lidos por nenhuma regra de negócio/policy hoje — campos decorativos.

## Próximos passos desta discussão

- [x] Explorar se `quality_gate_scanner_runs` deveria reduzir colunas duplicadas com `scans`
      (ex: `scanner_class`, `findings_count`, `started_at`) — concluído com a fusão completa
      proposta em #2c.
- [ ] Decidir #1 (sarif_raw): implementar agora ou aguardar mais achados.
- [ ] Decidir #2c (fusão scans + quality_gate_scanner_runs): desenhar migração e plano de código.
- [ ] Continuar vasculhando as demais tabelas em busca do mesmo padrão (tabelas paralelas
      que modelam a "mesma coisa" em contextos diferentes) — candidatos: `consolidated_risk_candidate`
      vs `consolidated_risk_finding`, `risk_exceptions`, `finding_identifiers`.
- [ ] Confirmar se a reorganização conceitual (Org → Repo → Quality Gate → Scan/Finding → Risco)
      deveria virar a ordem oficial de apresentação no `database-schema.md` também.
