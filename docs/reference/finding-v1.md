# Finding v1

Contrato de finding normalizado, agnóstico ao scanner que o originou. Source-of-truth em `pequod/wire/schemas/finding_v1.py` (contrato de fio) e `pequod/model/finding.py` (entidade de domínio, com a lógica de fingerprint e normalização de localização).

Pequod consome SARIF v2.1.0 do tópico `findings.raw` (publicado pelo moby-dick) e converte para `Finding v1` antes de persistir, via `adapter/sarif/sarif_to_finding.py`.

## Schema

```python
class Finding(BaseModel):
    schema_version: str = "1"
    fingerprint: str
    scanner: str
    scanner_class: str = "unknown"      # sast, dast, sca, iac, secret, container, unknown
    rule_id: str
    severity: str                       # "critical", "major", "minor", "info" (também "low")
    repo: str                           # "owner/repo" — label legível
    repo_id: str = ""                   # identidade estável (ex: "gh_847291") — usada no dedup
    ref: str

    location_type: str = "none"         # "code", "web", "dependency", "configuration", "asset", "none"
    location: dict[str, Any] = {}       # estrutura varia por location_type
    evidence: dict[str, Any] = {}       # dados brutos do scanner (request/response, snippet, etc.)
    properties: dict[str, Any] = {}     # propriedades específicas do scanner/regra

    # Campos legados, mantidos temporariamente para compatibilidade.
    file_path: str = ""
    line_start: int | None = None
    line_end: int | None = None

    message: str | None = None
    sarif_raw: dict[str, Any] | None = None   # result SARIF original — não persistido em `finding`, só em `finding_occurrences.raw_payload`
```

!!! note "`location` é polimórfico"
    A estrutura de `location` depende de `location_type`:

    | `location_type` | Campos principais |
    |---|---|
    | `code` | `file_path`, `line_start`, `line_end`, `column_start`, `column_end`, `snippet` |
    | `web` | `observed_url`, `endpoint`, `method`, `parameter`, `parameter_location` |
    | `dependency` | `ecosystem`, `package`, `version`, `manifest_path`, `purl`, `purl_without_version` |
    | `configuration` | `file_path`, `line_start`/`line_end`, `resource`, `configuration_key` |
    | `asset` | `host`, `port`, `protocol`, `service` |

    Os campos legados `file_path`/`line_start`/`line_end` continuam preenchidos por compatibilidade quando `location_type` é `code` ou `configuration` (ver `Finding.__post_init__` em `model/finding.py`).

## Exemplo

```json
{
  "schema_version": "1",
  "fingerprint": "9c8b1f...8a3d",
  "scanner": "sonarqube",
  "scanner_class": "sast",
  "rule_id": "javascript:S2068",
  "severity": "critical",
  "repo": "OdinEye-FIAP/clint-eastwood",
  "repo_id": "gh_847291",
  "ref": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
  "location_type": "code",
  "location": {
    "file_path": "security-issues.js",
    "line_start": 12,
    "line_end": 12,
    "snippet": "const password = \"hardcoded123\";"
  },
  "evidence": {},
  "properties": {},
  "message": "Credentials should not be hard-coded"
}
```

## Fingerprint determinístico

A chave de dedup é `fingerprint` (SHA-256 hex), calculada por `Finding.compute_fingerprint()` (`model/finding.py`):

1. Extrai uma **identidade estável**, que depende de `location_type` (ex.: para `code`, prioriza um `stable_id` do scanner — `partialFingerprints`/`fingerprints` do SARIF — senão usa `file_path`+`snippet` normalizado; para `web`, usa `endpoint`+`method`+`parameter`; para `dependency`, usa `purl_without_version`; etc.).
2. Monta um payload `{scanner (normalizado), rule_id (normalizado), repo_id (normalizado), location_type, identity}`.
3. Serializa em JSON com chaves ordenadas e aplica SHA-256.

!!! warning "O fingerprint usa `repo_id`, não `repo`"
    Diferente do que uma versão anterior deste documento descrevia, o fingerprint **não** é `sha256(scanner|rule_id|repo|file_path|line_start|snippet)`. Ele usa `repo_id` (identidade estável do repositório, sobrevive a rename/transfer no GitHub) e a identidade estruturada de `location` — não uma tupla fixa de campos. O constraint de unicidade no banco é `UNIQUE (fingerprint, repo_id)` (`deploy/schema.sql`), não `UNIQUE (fingerprint, repo)`.

!!! tip "Dedup cross-scan"
    Re-rodar o mesmo scan no mesmo commit gera o mesmo fingerprint → upsert `ON CONFLICT (fingerprint, repo_id)` atualiza `last_seen_at` (e demais campos "vivos") sem duplicar.

## Severity normalizada

SARIF `level` → `Finding.severity` (`adapter/sarif/sarif_to_finding.py`, `_SEVERITY_MAP`):

| SARIF `level` / valor bruto | Finding severity |
|---|---|
| `error` | `critical` |
| `warning` | `major` |
| `note` | `minor` |
| `none` | `info` |
| `critical` | `critical` |
| `high` | `major` |
| `medium` | `minor` |
| `low` | `low` |
| `info` | `info` |

Além do `level` SARIF padrão, o parser aceita valores brutos já em nomenclatura "critical/high/medium/low/info" (comum em scanners SCA/IaC) e também respeita `rule.defaultConfiguration.level` quando o result não traz `level` explícito. Nota: `low` é um 5º valor de severidade possível além dos 4 originais (`critical`/`major`/`minor`/`info`).

## Status (lifecycle)

Coluna `finding.status`, sem `CHECK` constraint no schema — validado na camada de aplicação. Os valores aceitos pelo endpoint legado `PATCH /findings/{id}` (`controller/query_controller.py`, `_ALLOWED_STATUS`) são:

| Status | Significado |
|---|---|
| `open` | finding ativo, default na primeira ingestão |
| `triaged_fp` | triado manualmente como falso positivo |
| `fixed` | corrigido |
| `wontfix` | aceito/não será corrigido |

!!! warning "Não é `open`/`triaged`/`false_positive`/`resolved`"
    Uma versão anterior deste documento listava um enum diferente. O enum real e vigente é `open`/`triaged_fp`/`fixed`/`wontfix`. Re-ingestão não sobrescreve `status` — só atualiza `last_seen_at` e os demais campos "vivos" (`ref`, `severity`, `location*`, `message`, etc.).

## Diferença vs FindingsRawEvent

| | `FindingsRawEvent` (Kafka) | `Finding v1` (pequod DB / REST) |
|---|---|---|
| Onde | Tópico `findings.raw` | Tabela `finding` + REST |
| Quem produz | moby-dick (após scan) | pequod (após parse SARIF) |
| Schema | `{job_id, repo, repo_id, scanner, ref, sarif}` (`wire/inbound/findings_raw_event.py`) | `Finding v1` (1 entry por result do SARIF) |
| Cardinalidade | 1 mensagem por scan (com N results) | 1 row por finding deduplicado |

## Versionamento

| Versão | Status | Mudanças |
|---|---|---|
| **v1** | atual | Versão inicial, evoluída de forma retrocompatível (campos estruturados `location_type`/`location`/`evidence`/`properties` adicionados sem bump de versão) |

Bump apenas em mudança breaking (campo removido, tipo trocado). Campos novos opcionais não exigem bump. Identificadores externos (CVE, CWE, GHSA, OSV, PURL) já **existem hoje** como uma tabela auxiliar (`finding_identifiers`), fora do payload do `Finding v1` — não são mais apenas uma ideia de v2.

## Coisas que NÃO estão no Finding v1

- ❌ Histórico de mudanças de status — não existe tabela `finding_history`; mudanças de status não são auditadas por linha.
- ❌ Métricas agregadas (count por severity) — calculadas on-demand na REST (ex.: contadores de `security_gate_evaluations`), não persistidas.
- ✅ ~~Enrichments de IA em schemas separados~~ — **já existem**: `finding_ai_analysis` (individual, slim) e `finding_cluster_ai_analysis` (cluster, completo), referenciados por `finding_id`/`cluster_id`. Ver [Schema do banco](database-schema.md).
- ✅ ~~Snippet do código~~ — **já existe** como campo estruturado: `location.snippet` (e replicado em `evidence.snippet`) para `location_type="code"`, não depende mais só de `sarif_raw`.

## Tabela postgres (resumo)

```sql
CREATE TABLE finding (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint     text NOT NULL,
    scanner         text NOT NULL,
    scanner_class   text NOT NULL DEFAULT 'unknown',
    rule_id         text NOT NULL,
    severity        text NOT NULL,
    repo            text NOT NULL,
    repo_id         text NOT NULL DEFAULT '',
    ref             text NOT NULL,
    location_type   text NOT NULL DEFAULT 'none',
    location        jsonb NOT NULL DEFAULT '{}'::jsonb,
    evidence        jsonb NOT NULL DEFAULT '{}'::jsonb,
    properties      jsonb NOT NULL DEFAULT '{}'::jsonb,
    file_path       text,
    line_start      integer,
    line_end        integer,
    message         text,
    status          text NOT NULL DEFAULT 'open',
    application_id  uuid,
    tool_id         uuid,
    first_seen_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT finding_fingerprint_repo_id_key UNIQUE (fingerprint, repo_id)
);
```

Schema completo (todas as 23 tabelas) em `pequod/deploy/schema.sql` — não há mais `deploy/migrations/001_init.sql`; o schema consolidado substitui as migrations incrementais 001–016.
