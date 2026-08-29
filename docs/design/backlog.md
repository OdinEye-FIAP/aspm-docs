# Backlog de melhorias e débitos técnicos

> Este documento centraliza itens pendentes discutidos/anotados ao longo do
> desenvolvimento do ecossistema OdinEye ASPM (pequod, heimdall-dashboard,
> tars-ai, captain-hook, moby-dick), que ainda não foram implementados.
> Itens concluídos são removidos daqui (o histórico de decisão pode ficar
> registrado em PRs/issues referenciados).

## Bugs ativos

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
