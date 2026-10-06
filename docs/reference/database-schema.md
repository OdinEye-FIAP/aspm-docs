# Schema do banco (Pequod)

Referência das tabelas do banco relacional do Pequod. Source-of-truth em `pequod/deploy/schema.sql` (schema consolidado, sem migrations incrementais).

Convenção de nomenclatura: `finding_cluster`/`finding_cluster_member` representam o **agrupamento técnico bruto, pré-IA** (determinístico, por `correlation_key`). `consolidated_risk` representa o **risco já decidido** (via IA `propose_semantic_clustering` ou auto-attach determinístico), que é o que a UI (heimdall-dashboard) exibe como "Risco consolidado". Ver [decisions.md](../overview/decisions.md) para o histórico dessa distinção.

## Diagrama (estilo dbdiagram)

**Total: 19 tabelas** no schema (`finding`, `finding_ai_analysis`, `finding_cluster`, `finding_cluster_ai_analysis`, `finding_cluster_member`, `applications`, `scans`, `scan_artifacts`, `finding_occurrences`, `finding_identifiers`, `alerts`, `risk_exceptions`, `security_gate_policies`, `security_gate_items`, `quality_gate_runs`, `semantic_clustering_decision`, `consolidated_risk`, `consolidated_risk_candidate`, `consolidated_risk_finding`).

Diagramas Mermaid ER com colunas e tipos, agrupados por domínio (mesma divisão do `schema.sql`). Renderizam como caixas de tabela conectadas no GitHub e no mkdocs-material.

### Visão geral (todas as 19 tabelas)

Colunas reduzidas ao essencial (PK/FK + poucos campos identificadores) para caber as 19 tabelas em um único diagrama. Para o detalhe completo de colunas, veja os diagramas por domínio logo abaixo.

```mermaid
erDiagram
    finding {
        uuid id PK
        text fingerprint
        text scanner_class
        uuid application_id FK
    }
    finding_ai_analysis {
        uuid id PK
        uuid finding_id FK
    }
    finding_cluster {
        uuid id PK
        uuid application_id FK
        text correlation_key
    }
    finding_cluster_ai_analysis {
        uuid id PK
        uuid cluster_id FK
    }
    finding_cluster_member {
        uuid id PK
        uuid cluster_id FK
        uuid finding_id FK
    }
    applications {
        uuid id PK
        text repository_full_name
        text owner_name
    }
    scans {
        uuid id PK
        uuid application_id FK
        text scanner
        uuid quality_gate_run_id FK
    }
    scan_artifacts {
        uuid id PK
        uuid scan_id FK
    }
    finding_occurrences {
        uuid id PK
        uuid finding_id FK
        uuid scan_id FK
    }
    finding_identifiers {
        uuid id PK
        uuid finding_id FK
    }
    alerts {
        uuid id PK
        uuid application_id FK
        uuid finding_id FK
        uuid cluster_id FK
        uuid scan_id FK
    }
    risk_exceptions {
        uuid id PK
        uuid application_id FK
        uuid finding_id FK
        uuid cluster_id FK
    }
    security_gate_policies {
        uuid id PK
        uuid application_id FK
    }
    security_gate_items {
        uuid id PK
        uuid quality_gate_run_id FK
        uuid finding_id FK
        uuid cluster_id FK
        uuid risk_exception_id FK
    }
    quality_gate_runs {
        uuid id PK
        uuid application_id FK
        text workflow_id
        uuid policy_id FK
    }
    semantic_clustering_decision {
        uuid id PK
        uuid application_id FK
    }
    consolidated_risk {
        uuid id PK
        uuid decision_id FK
        uuid application_id FK
        text canonical_title
    }
    consolidated_risk_candidate {
        uuid risk_id PK, FK
        uuid cluster_id PK, FK
    }
    consolidated_risk_finding {
        uuid risk_id PK, FK
        uuid finding_id PK, FK
    }

    applications ||--o{ finding : "application_id"
    applications ||--o{ finding_cluster : "application_id"
    applications ||--o{ scans : "application_id"
    applications ||--o{ alerts : "application_id"
    applications ||--o{ risk_exceptions : "application_id"
    applications ||--o{ security_gate_policies : "application_id (opcional)"
    applications ||--o{ quality_gate_runs : "application_id"
    applications ||--o{ semantic_clustering_decision : "application_id"
    applications ||--o{ consolidated_risk : "application_id"
    scans ||--o{ scan_artifacts : "scan_id"
    scans ||--o{ finding_occurrences : "scan_id"
    scans ||--o{ alerts : "scan_id (opcional)"
    finding ||--o| finding_ai_analysis : "finding_id"
    finding ||--o{ finding_occurrences : "finding_id"
    finding ||--o{ finding_identifiers : "finding_id"
    finding ||--o| finding_cluster_member : "finding_id (1:1)"
    finding ||--o{ alerts : "finding_id (opcional/xor)"
    finding ||--o{ risk_exceptions : "finding_id (xor cluster_id)"
    finding ||--o{ security_gate_items : "finding_id (xor cluster_id)"
    finding ||--o{ consolidated_risk_finding : "finding_id"
    finding_cluster ||--o{ finding_cluster_member : "cluster_id"
    finding_cluster ||--o| finding_cluster_ai_analysis : "cluster_id"
    finding_cluster ||--o{ alerts : "cluster_id (opcional/xor)"
    finding_cluster ||--o{ risk_exceptions : "cluster_id (xor finding_id)"
    finding_cluster ||--o{ security_gate_items : "cluster_id (xor finding_id)"
    finding_cluster ||--o{ consolidated_risk_candidate : "cluster_id"
    risk_exceptions ||--o{ security_gate_items : "risk_exception_id (opcional)"
    security_gate_policies ||--o{ quality_gate_runs : "policy_id (opcional)"
    quality_gate_runs ||--o{ scans : "quality_gate_run_id (opcional)"
    quality_gate_runs ||--o{ security_gate_items : "quality_gate_run_id"
    semantic_clustering_decision ||--o{ consolidated_risk : "decision_id"
    consolidated_risk ||--o{ consolidated_risk_candidate : "risk_id"
    consolidated_risk ||--o{ consolidated_risk_finding : "risk_id"
```


### Findings e correlação

```mermaid
erDiagram
    finding {
        uuid id PK
        text fingerprint
        text scanner
        text rule_id
        text severity
        text ref
        text message
        text status
        timestamptz first_seen_at
        timestamptz last_seen_at
        text scanner_class
        text location_type
        jsonb location
        jsonb evidence
        jsonb properties
        uuid application_id FK
    }
    finding_ai_analysis {
        uuid id PK
        uuid finding_id FK
        text recommendation
        text priority
        numeric confidence
        text model_name
        timestamptz created_at
    }
    finding_cluster {
        uuid id PK
        uuid application_id FK
        text ref
        text title
        text category
        text severity
        numeric confidence
        text correlation_key
        timestamptz created_at
        timestamptz updated_at
        text primary_location_type
        jsonb primary_location
    }
    finding_cluster_ai_analysis {
        uuid id PK
        uuid cluster_id FK
        text summary
        text impact
        text recommendation
        text priority
        text false_positive_likelihood
        numeric confidence
        text reasoning_short
        text model_name
        timestamptz created_at
    }
    finding_cluster_member {
        uuid id PK
        uuid cluster_id FK
        uuid finding_id FK
        text scanner
        text rule_id
        numeric match_score
        timestamptz created_at
    }
    applications {
        uuid id PK
        text repository_full_name
    }

    applications ||--o{ finding : "application_id"
    applications ||--o{ finding_cluster : "application_id"
    finding ||--o| finding_ai_analysis : "finding_id"
    finding ||--o| finding_cluster_member : "finding_id (1:1)"
    finding_cluster ||--o{ finding_cluster_member : "cluster_id"
    finding_cluster ||--o| finding_cluster_ai_analysis : "cluster_id"
```

### Inventário, execuções e occurrences

```mermaid
erDiagram
    applications {
        uuid id PK
        text repository_provider
        text repository_external_id
        text repository_full_name
        text name
        text description
        text repository_url
        text default_branch
        text language
        text business_criticality
        text exposure
        text owner_name
        text team_name
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
        text github_installation_id
        boolean is_active
    }
    scans {
        uuid id PK
        uuid application_id FK
        text scanner
        text scanner_class
        text scan_status
        text source_type
        text external_run_id
        text ref_type
        text ref
        text commit_sha
        text tool_version
        jsonb metadata
        timestamptz started_at
        timestamptz finished_at
        timestamptz created_at
        uuid quality_gate_run_id FK
        text job_id
        text error_code
        text error_message
    }
    scan_artifacts {
        uuid id PK
        uuid scan_id FK
        text artifact_type
        text storage_uri
        text content_hash
        bigint size_bytes
        jsonb metadata
        timestamptz created_at
        text artifact_key
        text mime_type
        jsonb inline_content
        timestamptz updated_at
    }
    finding_occurrences {
        uuid id PK
        uuid finding_id FK
        uuid scan_id FK
        text location_type
        jsonb location
        jsonb evidence
        jsonb properties
        jsonb raw_payload
        text severity
        text message
        timestamptz observed_at
        timestamptz created_at
    }
    finding_identifiers {
        uuid id PK
        uuid finding_id FK
        text identifier_type
        text identifier_value
        text source
        text reference_url
        jsonb metadata
        timestamptz created_at
    }
    finding {
        uuid id PK
        uuid application_id FK
    }
    quality_gate_runs {
        uuid id PK
    }

    applications ||--o{ finding : "application_id"
    applications ||--o{ scans : "application_id"
    applications ||--o{ quality_gate_runs : "application_id"
    scans ||--o{ scan_artifacts : "scan_id"
    scans ||--o{ finding_occurrences : "scan_id"
    finding ||--o{ finding_occurrences : "finding_id"
    finding ||--o{ finding_identifiers : "finding_id"
    quality_gate_runs ||--o{ scans : "quality_gate_run_id (opcional)"
```

### Governança operacional e Quality Gate

```mermaid
erDiagram
    alerts {
        uuid id PK
        uuid application_id FK
        uuid finding_id FK
        uuid cluster_id FK
        uuid scan_id FK
        text alert_type
        text severity
        text title
        text message
        text deduplication_key
        jsonb payload
        timestamptz created_at
        timestamptz updated_at
        timestamptz resolved_at
    }
    risk_exceptions {
        uuid id PK
        uuid application_id FK
        uuid finding_id FK
        uuid cluster_id FK
        text exception_type
        text status
        text reason
        text justification
        text requested_by
        text approved_by
        timestamptz starts_at
        timestamptz expires_at
        timestamptz revoked_at
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
    }
    security_gate_policies {
        uuid id PK
        uuid application_id FK
        text name
        text description
        integer version
        boolean is_active
        text policy_mode
        jsonb rules
        jsonb metadata
        text created_by
        timestamptz created_at
        timestamptz updated_at
    }
    quality_gate_runs {
        uuid id PK
        uuid application_id FK
        text workflow_id
        text delivery_id
        text source
        text repository_id
        text repository_full_name
        text installation_id
        text kind
        text branch_name
        text head_repo
        bigint pull_request_number
        text base_ref
        text head_sha
        jsonb expected_scanners
        text status
        text decision
        jsonb summary
        uuid policy_id FK
        text policy_name
        integer policy_version
        text policy_mode
        timestamptz started_at
        timestamptz expires_at
        timestamptz completed_at
        jsonb metadata
        timestamptz created_at
        timestamptz updated_at
    }
    security_gate_items {
        uuid id PK
        uuid quality_gate_run_id FK
        uuid finding_id FK
        uuid cluster_id FK
        uuid risk_exception_id FK
        text item_type
        text severity
        text decision
        text reason
        jsonb metadata
        timestamptz created_at
    }
    applications {
        uuid id PK
        text repository_full_name
    }
    scans {
        uuid id PK
        uuid application_id FK
        uuid quality_gate_run_id FK
    }
    finding {
        uuid id PK
    }
    finding_cluster {
        uuid id PK
    }

    applications ||--o{ finding : "application_id"
    applications ||--o{ finding_cluster : "application_id"
    applications ||--o{ scans : "application_id"
    applications ||--o{ alerts : "application_id"
    applications ||--o{ risk_exceptions : "application_id"
    applications ||--o{ security_gate_policies : "application_id (opcional)"
    applications ||--o{ quality_gate_runs : "application_id"
    scans ||--o{ alerts : "scan_id (opcional)"
    finding ||--o{ alerts : "finding_id (opcional/xor)"
    finding ||--o{ risk_exceptions : "finding_id (xor cluster_id)"
    finding ||--o{ security_gate_items : "finding_id (xor cluster_id)"
    finding_cluster ||--o{ alerts : "cluster_id (opcional/xor)"
    finding_cluster ||--o{ risk_exceptions : "cluster_id (xor finding_id)"
    finding_cluster ||--o{ security_gate_items : "cluster_id (xor finding_id)"
    risk_exceptions ||--o{ security_gate_items : "risk_exception_id (opcional)"
    security_gate_policies ||--o{ quality_gate_runs : "policy_id (opcional)"
    quality_gate_runs ||--o{ scans : "quality_gate_run_id (opcional)"
    quality_gate_runs ||--o{ security_gate_items : "quality_gate_run_id"
```

### Consolidação semântica de risco

```mermaid
erDiagram
    semantic_clustering_decision {
        uuid id PK
        uuid proposal_id
        uuid application_id FK
        text ref
        text model_name
        text contract_version
        text status
        jsonb proposal
        jsonb metadata
        timestamptz created_at
    }
    consolidated_risk {
        uuid id PK
        uuid decision_id FK
        uuid application_id FK
        text ref
        text canonical_title
        text canonical_category
        text technical_severity
        text priority
        text false_positive_likelihood
        numeric confidence
        text summary
        text impact
        text recommendation
        text reasoning
        text ai_action
        text model_name
        bigint github_issue_number
        text github_issue_url
        timestamptz created_at
        timestamptz updated_at
    }
    consolidated_risk_candidate {
        uuid risk_id PK, FK
        uuid cluster_id PK, FK
        timestamptz created_at
    }
    consolidated_risk_finding {
        uuid risk_id PK, FK
        uuid finding_id PK, FK
        timestamptz created_at
    }
    applications {
        uuid id PK
        text repository_full_name
    }
    finding_cluster {
        uuid id PK
    }
    finding {
        uuid id PK
    }

    applications ||--o{ finding : "application_id"
    applications ||--o{ finding_cluster : "application_id"
    applications ||--o{ semantic_clustering_decision : "application_id"
    applications ||--o{ consolidated_risk : "application_id"
    finding ||--o{ consolidated_risk_finding : "finding_id"
    finding_cluster ||--o{ consolidated_risk_candidate : "cluster_id"
    semantic_clustering_decision ||--o{ consolidated_risk : "decision_id"
    consolidated_risk ||--o{ consolidated_risk_candidate : "risk_id"
    consolidated_risk ||--o{ consolidated_risk_finding : "risk_id"
```

## Relacionamentos entre tabelas (FKs)

Tabela de referência com toda foreign key do schema: tabela de origem, coluna, tabela/coluna referenciada, cardinalidade e comportamento de delete.

| Tabela de origem | Coluna FK | Referencia | Cardinalidade | ON DELETE | Observação |
|---|---|---|---|---|---|
| `finding` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `finding_ai_analysis` | `finding_id` | `finding.id` | 1:1 | CASCADE | `finding_id` é UNIQUE |
| `finding_cluster` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `finding_cluster_ai_analysis` | `cluster_id` | `finding_cluster.id` | 1:1 | CASCADE | `cluster_id` é UNIQUE |
| `finding_cluster_member` | `cluster_id` | `finding_cluster.id` | N:1 | CASCADE | |
| `finding_cluster_member` | `finding_id` | `finding.id` | 1:1 | CASCADE | `finding_id` é UNIQUE (finding pertence a no máx. 1 cluster) |
| `scans` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `scans` | `quality_gate_run_id` | `quality_gate_runs.id` | N:1 (opcional) | SET NULL | nullable; preenchido por `scanner.completed` |
| `scan_artifacts` | `scan_id` | `scans.id` | N:1 | CASCADE | |
| `finding_occurrences` | `finding_id` | `finding.id` | N:1 | CASCADE | |
| `finding_occurrences` | `scan_id` | `scans.id` | N:1 | CASCADE | par `(finding_id, scan_id)` é UNIQUE |
| `finding_identifiers` | `finding_id` | `finding.id` | N:1 | CASCADE | |
| `alerts` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `alerts` | `finding_id` | `finding.id` | N:1 (opcional) | SET NULL | nullable |
| `alerts` | `cluster_id` | `finding_cluster.id` | N:1 (opcional) | SET NULL | nullable |
| `alerts` | `scan_id` | `scans.id` | N:1 (opcional) | SET NULL | nullable |
| `risk_exceptions` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `risk_exceptions` | `finding_id` | `finding.id` | N:1 (xor) | CASCADE | exatamente um entre `finding_id`/`cluster_id` |
| `risk_exceptions` | `cluster_id` | `finding_cluster.id` | N:1 (xor) | CASCADE | exatamente um entre `finding_id`/`cluster_id` |
| `security_gate_policies` | `application_id` | `applications.id` | N:1 (opcional) | CASCADE | nullable (policy global se NULL) |
| `quality_gate_runs` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `quality_gate_runs` | `policy_id` | `security_gate_policies.id` | N:1 (opcional) | RESTRICT | nullable |
| `security_gate_items` | `quality_gate_run_id` | `quality_gate_runs.id` | N:1 | CASCADE | |
| `security_gate_items` | `finding_id` | `finding.id` | N:1 (xor/opcional) | SET NULL | no máx. um entre `finding_id`/`cluster_id`; pode ser `aggregate`/`system` (nenhum) |
| `security_gate_items` | `cluster_id` | `finding_cluster.id` | N:1 (xor/opcional) | SET NULL | idem acima |
| `security_gate_items` | `risk_exception_id` | `risk_exceptions.id` | N:1 (opcional) | SET NULL | nullable |
| `semantic_clustering_decision` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `consolidated_risk` | `decision_id` | `semantic_clustering_decision.id` | N:1 | CASCADE | |
| `consolidated_risk` | `application_id` | `applications.id` | N:1 | RESTRICT | |
| `consolidated_risk_candidate` | `risk_id` | `consolidated_risk.id` | N:1 | CASCADE | PK composta `(risk_id, cluster_id)` |
| `consolidated_risk_candidate` | `cluster_id` | `finding_cluster.id` | N:1 | CASCADE | PK composta `(risk_id, cluster_id)` |
| `consolidated_risk_finding` | `risk_id` | `consolidated_risk.id` | N:1 | CASCADE | PK composta `(risk_id, finding_id)` |
| `consolidated_risk_finding` | `finding_id` | `finding.id` | N:1 | CASCADE | PK composta `(risk_id, finding_id)` |

### Por tabela "pai" (quem referencia quem)

| Tabela | Referenciada por |
|---|---|
| `applications` | `finding`, `finding_cluster`, `scans`, `alerts`, `risk_exceptions`, `security_gate_policies`, `quality_gate_runs`, `semantic_clustering_decision`, `consolidated_risk` |
| `scans` | `scan_artifacts`, `finding_occurrences`, `alerts` |
| `finding` | `finding_ai_analysis`, `finding_occurrences`, `finding_identifiers`, `finding_cluster_member`, `alerts`, `risk_exceptions`, `security_gate_items`, `consolidated_risk_finding` |
| `finding_cluster` | `finding_cluster_member`, `finding_cluster_ai_analysis`, `alerts`, `risk_exceptions`, `security_gate_items`, `consolidated_risk_candidate` |
| `risk_exceptions` | `security_gate_items` |
| `security_gate_policies` | `quality_gate_runs` |
| `quality_gate_runs` | `scans`, `security_gate_items` |
| `semantic_clustering_decision` | `consolidated_risk` |
| `consolidated_risk` | `consolidated_risk_candidate`, `consolidated_risk_finding` |

> `finding` e `finding_cluster` nunca são referenciados juntos pela mesma linha em `risk_exceptions`/`security_gate_items` (constraint de exclusividade — "xor" na tabela acima).

## Vulnerabilidades canônicas e correlação

### `finding`
Vulnerabilidade normalizada (contrato [Finding v1](finding-v1.md)), deduplicada por `(fingerprint, application_id)`. É o registro canônico de uma ocorrência de scanner após ingestão.

Colunas principais: `fingerprint`, `scanner`, `scanner_class`, `rule_id`, `severity`, `ref`, `location_type`/`location` (jsonb; arquivo, linha, endpoint ou pacote vivem só aqui), `evidence`/`properties` (jsonb, dados brutos do scanner), `status` (`open`/...), `application_id` (NOT NULL). `repo` e `repo_id` não são colunas: as respostas da API os derivam de `applications` por JOIN.

!!! warning "`sarif_raw` não é mais coluna de `finding`"
    A coluna foi removida do schema. O JSON completo do result SARIF só é preservado em `finding_occurrences.raw_payload` (uma linha por ocorrência/scan). O endpoint legado `GET /findings/{id}` continua devolvendo um campo `sarif_raw` — mas ele é **recomposto em tempo de leitura** por uma subquery que busca `raw_payload` da ocorrência mais recente (`ORDER BY observed_at DESC, created_at DESC LIMIT 1`), não um valor persistido em `finding`.

### `finding_ai_analysis`
Análise de IA 1:1 por finding individual (`finding_id` UNIQUE). Colunas: `recommendation`, `priority`, `confidence`, `model_name`.

### `finding_cluster`
Agrupamento técnico determinístico pré-IA, criado por `clusterize_candidate_findings()` a partir de `correlation_key` (ver `candidate_clustering_controller.py`). Não é ainda um risco decidido.

Colunas: `application_id`, `ref`, `title`, `category`, `correlation_key` (UNIQUE por `application_id`+`ref`+`correlation_key`), `primary_location_type`/`primary_location` (jsonb), `severity`, `confidence`.

### `finding_cluster_ai_analysis`
Análise de IA 1:1 por cluster (`cluster_id` UNIQUE) — usada quando o cluster ainda não foi promovido a `consolidated_risk`, ou como registro auxiliar do fluxo de decisão. Colunas: `summary`, `impact`, `recommendation`, `priority`, `false_positive_likelihood`, `confidence`, `reasoning_short`, `model_name`.

### `finding_cluster_member`
Relação N:1 entre `finding` e `finding_cluster` (cada finding pertence a no máximo um cluster: `finding_id` UNIQUE). Colunas: `cluster_id`, `finding_id`, `scanner`, `rule_id`, `match_score`.

## Inventário e execuções

### `applications`
Repositório/aplicação registrada no ecossistema (via GitHub App). Colunas: `repository_provider`/`repository_external_id`/`repository_full_name`, `name`, `default_branch`, `language`, `business_criticality`, `exposure`, `owner_name`/`team_name`, `github_installation_id`, `is_active`.

> **Não existem tabelas dedicadas `repositories` ou `organizations`.** As telas "Repositórios" e "Organizações" do heimdall-dashboard são visões derivadas de `applications`: cada linha de `applications` já É um repositório registrado, e "Organização" é simplesmente o agrupamento de `applications` pelo campo `owner_name` (conta/organização GitHub), feito em runtime por `list_organizations_on_connection()` (`pequod/diplomat/db/rest_query_repo.py`) — não há persistência própria para organização.

### `scans`
Execução de um scanner sobre uma aplicação. Colunas: `application_id`, `scanner` (nome do scanner, texto), `scanner_class`, `scan_status`, `source_type`, `external_run_id` (UNIQUE por `application_id`+`external_run_id`), `ref_type`/`ref`/`commit_sha`, `tool_version`, `started_at`/`finished_at`.

Um scan também representa a execução de um scanner dentro de um Quality Gate: `quality_gate_run_id` (FK, nullable), `job_id`, `error_code`/`error_message`. `scanner.completed` e `findings.raw` chegam por tópicos independentes: se `scanner.completed` chega antes, nasce uma linha "casca" (`source_type` diferente de `findings.raw`, sem findings) que a ingestão completa depois, pela mesma chave `(application_id, external_run_id)`. Um scanner esperado que expira sem job vira um scan com `external_run_id` `timeout:{workflow_id}:{scanner}`.

`scanner` é o nome usado pelo workflow quando o scan está vinculado a um run (é a chave que casa com `expected_scanners`); só em scans sem vínculo ele traz o nome do SARIF.

### `scan_artifacts`
Artefato bruto produzido por um scan (ex: SARIF original, log). Colunas: `scan_id`, `artifact_type`, `artifact_key`, `storage_uri` ou `inline_content` (jsonb), `content_hash`, `size_bytes`, `mime_type`.

## Occurrences e identificadores

### `finding_occurrences`
Ocorrência de um `finding` em um `scan` específico (permite rastrear reincidência do mesmo finding em múltiplos scans). Colunas: `finding_id`, `scan_id` (UNIQUE juntos), `location_type`/`location`, `evidence`/`properties`/`raw_payload`, `severity`, `message`, `observed_at`.

### `finding_identifiers`
Identificadores externos associados a um finding (ex: CVE, CWE). Colunas: `finding_id`, `identifier_type`, `identifier_value`, `source`, `reference_url`.

## Governança operacional

### `alerts`
Notificação (ex: Slack/webhook) gerada para um finding/cluster/scan. Colunas: `application_id`, `finding_id`/`cluster_id`/`scan_id` (nullable), `alert_type`, `severity`, `title`/`message`, `deduplication_key`, `payload` (jsonb — payload específico do canal de entrega), `resolved_at`.

!!! warning "Não existe coluna `status` em `alerts`"
    Um alerta é considerado **aberto** enquanto `resolved_at IS NULL`, e **resolvido** quando `resolved_at` é preenchido — não há enum `status` (`pending`/`sent`/`failed`/...), nem colunas de canal de entrega/retry (`delivery_channel`, `destination`, `attempts`, `max_attempts`, `next_retry_at`). O filtro `GET /api/v1/alerts?resolved=` da API mapeia para `(resolved_at IS NULL) = NOT resolved`.

## Governança de risco e Quality Gate

### `risk_exceptions`
Exceção de risco aceita/suprimida para um finding OU cluster (nunca ambos). Colunas: `application_id`, `finding_id` xor `cluster_id`, `exception_type` (`false_positive`/`accepted_risk`/`suppressed`), `status` (`active`/`expired`/`revoked`), `reason`/`justification`, `requested_by`/`approved_by`, `starts_at`/`expires_at`/`revoked_at`.

### `security_gate_policies`
Política de bloqueio configurável (global ou por `application_id`). Colunas: `name`, `version`, `is_active`, `policy_mode` (`blocking`/`monitoring`), `rules` (jsonb).

### `security_gate_items`
Item individual avaliado dentro de um `quality_gate_runs` — aponta para um `finding` OU `cluster` (nunca ambos), ou é `aggregate`/`system`. Colunas: `quality_gate_run_id`, `finding_id` xor `cluster_id`, `risk_exception_id`, `item_type` (`finding`/`cluster`/`aggregate`/`system`), `decision` (`passed`/`failed`/`warning`/`ignored`/`error`), `reason`.

> Nota: `item_type`/campos `cluster_*` aqui referenciam o `finding_cluster` (agrupamento pré-IA), não o `consolidated_risk` — nomenclatura pendente de alinhamento (ver item de backlog sobre renomear `finding_cluster`/`candidate_cluster` no backend).

### `quality_gate_runs`
Execução do Quality Gate para um Pull Request (`kind='pr'`, exige `pull_request_number`) **ou** para uma branch fora do contexto de PR (`kind='baseline'`, Security Baseline, sem `pull_request_number`). A chave é UNIQUE por `(repository_id, kind, head_repo, branch_name)`: há 1 run vigente por branch e kind, e um commit novo na mesma branch substitui o run anterior (reset), sem histórico. `head_repo` evita que um PR de fork com head `main` colida com o baseline da branch padrão. A decisão do gate fica no próprio run (`decision`, `summary`, `policy_*`); não existe tabela de avaliação separada.

Colunas: `application_id`, `workflow_id` (UNIQUE), `delivery_id`, `source` (default `github`), `repository_id`/`repository_full_name`, `installation_id`, `kind` (`pr`/`baseline`), `branch_name`, `head_repo`, `pull_request_number`, `base_ref`, `head_sha`, `expected_scanners` (jsonb array), `status` (`pending`→`running`→`evaluating`→`completed`/`failed`/`cancelled`/`timed_out`), `decision` (`passed`/`warning`/`failed`/`error`), `summary` (jsonb), `policy_id`/`policy_name`/`policy_version`/`policy_mode`, `started_at`/`expires_at`/`completed_at`.

Os scanners do run são as linhas de `scans` com `quality_gate_run_id` preenchido; não há tabela `quality_gate_scanner_runs`.

## Consolidação semântica de risco

### `semantic_clustering_decision`
Registro da decisão da IA (`propose_semantic_clustering`) sobre um conjunto de `finding_cluster`. Colunas: `proposal_id` (UNIQUE), `application_id`, `ref`, `model_name`, `contract_version`, `status` (`applied`/`rejected`), `proposal` (jsonb, payload completo retornado pela IA).

### `consolidated_risk`
**O risco consolidado exibido ao usuário final** — resultado de uma decisão de IA (`merge`/`keep`/`split`) ou de auto-attach determinístico. É essa tabela que o heimdall-dashboard renderiza como "Riscos consolidados" (via `ConsolidatedRiskApiItem` → `RiskAnalysis` no front).

Colunas: `decision_id` (FK para `semantic_clustering_decision`), `application_id`, `ref`, `canonical_title`/`canonical_category`, `technical_severity`, `priority`, `false_positive_likelihood`, `confidence`, `summary`/`impact`/`recommendation`/`reasoning`, `ai_action` (`merge`/`keep`/`split`), `model_name`, `github_issue_number`/`github_issue_url` (preenchidos quando uma issue do GitHub é criada a partir do risco consolidado).

### `consolidated_risk_candidate`
Relação N:N entre `consolidated_risk` e `finding_cluster` — quais clusters técnicos foram consolidados em qual risco. PK composta `(risk_id, cluster_id)`.

### `consolidated_risk_finding`
Relação N:N entre `consolidated_risk` e `finding` — todos os findings individuais cobertos por um risco consolidado (via os clusters candidatos). PK composta `(risk_id, finding_id)`.

## Fluxo de dados (visão geral)

```
Quality Gate (N scanners) → findings.raw (Kafka) → finding (ingestão)
                                                        │
                                                        ▼
                                     clusterize_candidate_findings()
                                     (agrupa por correlation_key)
                                                        │
                                                        ▼
                                              finding_cluster
                                       (+ finding_cluster_member)
                                                        │
                              ┌──────────────────────────────────┐
                              ▼                                                     ▼
                 auto-attach determinístico                          IA: propose_semantic_clustering
              (find_risk_by_target_on_connection)                      (merge / keep / split)
                              │                                                     │
                              └──────────────────────────────────┐
                                                        ▼
                                            semantic_clustering_decision
                                                        │
                                                        ▼
                                              consolidated_risk
                                    (+ consolidated_risk_candidate/_finding)
                                                        │
                                                        ▼
                                    heimdall-dashboard ("Riscos consolidados")
```

Ver também [Finding v1](finding-v1.md) e [ADRs](../overview/decisions.md) para o histórico de decisões que moldaram esse fluxo (ex: por que `correlation_key` não usa mais bucket de linha para `kind=="code"`).
