# Finding v1

Contrato de finding normalizado, agnóstico ao scanner que originou. Source-of-truth em `pequod/wire/schemas/finding_v1.py`.

Pequod consome SARIF v2.1.0 do tópico `findings.raw` (publicado pelo moby-dick) e converte para `Finding v1` antes de persistir.

## Schema

```python
class Finding(BaseModel):
    schema_version: str = "1"
    fingerprint: str                  # SHA-256 determinístico
    scanner: str                      # "sonarqube", "semgrep" (futuro), etc.
    rule_id: str                      # id da regra do scanner (ex: "javascript:S2068")
    severity: str                     # "critical", "major", "minor", "info"
    repo: str                         # "owner/repo"
    ref: str                          # commit SHA do scan
    file_path: str                    # caminho relativo no repo
    line_start: Optional[int]
    line_end: Optional[int]
    message: Optional[str]
    sarif_raw: Optional[Dict[str, Any]]  # SARIF result original (auditoria)
```

## Exemplo

```json
{
  "schema_version": "1",
  "fingerprint": "9c8b1f...8a3d",
  "scanner": "sonarqube",
  "rule_id": "javascript:S2068",
  "severity": "critical",
  "repo": "OdinEye-FIAP/clint-eastwood",
  "ref": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
  "file_path": "security-issues.js",
  "line_start": 12,
  "line_end": 12,
  "message": "Credentials should not be hard-coded",
  "sarif_raw": {
    "ruleId": "javascript:S2068",
    "level": "error",
    "message": { "text": "Credentials should not be hard-coded" },
    "locations": [ { "physicalLocation": { "...": "..." } } ]
  }
}
```

## Fingerprint determinístico

A chave de dedup é `fingerprint` (SHA-256 hex), calculada por:

```python
parts = [scanner, rule_id, repo, file_path, str(line_start or ""), snippet]
fingerprint = sha256("|".join(parts)).hexdigest()
```

| Componente | Por quê |
|---|---|
| `scanner` | mesma regra em scanners diferentes vira finding distinto |
| `rule_id` | granularidade por regra |
| `repo` | isolamento entre repos |
| `file_path` | mesma regra em arquivos diferentes ≠ mesmo finding |
| `line_start` | mesma regra em linhas diferentes ≠ mesmo finding |
| `snippet` | quando linha muda mas código não (refactor), ajuda a manter identidade |

!!! tip "Dedup cross-scan"
    Re-rodar o mesmo scan no mesmo commit gera o mesmo fingerprint → upsert `ON CONFLICT (fingerprint, repo)` atualiza `last_seen_at` sem duplicar.

## Severity normalizada

SARIF `level` → `Finding.severity`:

| SARIF level | Finding severity |
|---|---|
| `error` | `critical` |
| `warning` | `major` |
| `note` | `minor` |
| `none` | `info` |

Adapter SARIF do pequod (`adapter/sarif/sarif_to_finding.py`) também respeita `rule.defaultConfiguration.level` quando o result não traz `level` explícito.

## Status (lifecycle)

| Status | Significado |
|---|---|
| `open` | finding ativo, default na primeira ingestão |
| `triaged` | dev viu, ainda não decidiu |
| `false_positive` | classificado manualmente como falso positivo |
| `resolved` | corrigido (ou removido do código) |

Status só muda via `PATCH /findings/{id}` no pequod. Re-ingestão não sobrescreve status — só atualiza `last_seen_at`, `ref`, `severity`, `line_start`, `line_end`, `message`, `sarif_raw`.

## Diferença vs FindingsRawEvent

| | `FindingsRawEvent` (Kafka) | `Finding v1` (pequod DB / REST) |
|---|---|---|
| Onde | Tópico `findings.raw` | Tabela `finding` + REST |
| Quem produz | moby-dick (após scan) | pequod (após parse SARIF) |
| Schema | `{job_id, repo, repo_id, scanner, ref, sarif}` | `Finding v1` (1 entry por result do SARIF) |
| Cardinalidade | 1 mensagem por scan (com N results) | 1 row por finding deduplicado |

## Particionamento Kafka

`findings.raw` usa key = `repo_id` (`gh_<github_repository_id>`):

- Ordem por repo garante que upserts de um mesmo arquivo em scans consecutivos não corram em paralelo
- Key estável a rename/transfer do repo no GitHub ([Decisão §13](../overview/decisions.md#13-sonar_project_key-derivado-de-githubrepositoryid))

## Versionamento

| Versão | Status | Mudanças |
|---|---|---|
| **v1** | atual | Versão inicial |
| v2 | futuro hipotético | possíveis adições: `cwe`, `cvss`, `tags`, `pr_number`, `commit_message_at_first_seen` |

Bump apenas em mudança breaking (campo removido, tipo trocado). Campos novos opcionais não exigem bump.

## Coisas que NÃO estão no Finding v1

- ❌ Enrichments de IA — virão em schemas separados (`ai.enrichments.triage`, etc), referenciam por `fingerprint`
- ❌ Métricas agregadas (count por severity) — calculadas on-demand na REST, não persistidas
- ❌ Histórico de mudanças de status — tabela `finding_history` será adicionada quando workflow de aprovação exigir
- ❌ Snippet do código — somente `sarif_raw` preserva, não há coluna dedicada

## Tabela postgres (resumo)

```sql
CREATE TABLE finding (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    fingerprint     text NOT NULL,
    scanner         text NOT NULL,
    rule_id         text NOT NULL,
    severity        text NOT NULL,
    repo            text NOT NULL,
    ref             text NOT NULL,
    file_path       text NOT NULL,
    line_start      int,
    line_end        int,
    message         text,
    sarif_raw       jsonb,
    status          text NOT NULL DEFAULT 'open',
    first_seen_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (fingerprint, repo)
);
```

Schema completo em `pequod/deploy/migrations/001_init.sql`.
