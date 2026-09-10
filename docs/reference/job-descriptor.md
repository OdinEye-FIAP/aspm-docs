# JobDescriptor v1

Contrato de mensagem entre captain-hook e moby-dick. Schema versionado, source-of-truth em `wire/schemas/job_v1.py` (copiado entre os repos por enquanto — mesma convenção do `quality_gate_v1.py`).

`schema_version` continua `"1"`: os campos novos (`context.scope`, `context.branch_name`, `context.application_id`, `JobDescriptor.quality_gate`) são **aditivos e opcionais**, para preservar compatibilidade com producers antigos que não os populam (nesse caso, `scope` assume `"pr"` implicitamente).

## Schema completo

```python
# wire/schemas/job_v1.py
from typing import Literal
from pydantic import BaseModel, Field
from wire.schemas.quality_gate_v1 import QualityGateJobContext

JobScope = Literal["pr", "branch"]


class JobCallback(BaseModel):
    type: str                      # "github_check_run"
    owner: str                     # GitHub owner
    repo: str                      # GitHub repo
    head_sha: str                  # SHA pro check_run
    name: str                      # display name do check individual (ex: "SonarQube Scan")


class JobContext(BaseModel):
    source: str                    # "github" (no futuro: "gitlab", "bitbucket")
    repo: str                      # "owner/repo"
    ref: str                       # HEAD SHA
    trigger: str                   # "pull_request.synchronize", "push.baseline" etc
    callback: JobCallback
    scope: JobScope = "pr"         # "pr" (default) ou "branch" (Security Baseline)
    branch_name: str | None = None # só populado quando scope="branch"
    application_id: str | None = None  # aditivo — reservado para o pequod


class JobMetadata(BaseModel):
    created_at: str                # ISO 8601 UTC
    delivery_id: str               # X-GitHub-Delivery do webhook


class JobDescriptor(BaseModel):
    schema_version: str = "1"
    job_id: str                    # UUID5 estável (workflow_id + scanner)
    kind: str                      # "sonar_scan" | "semgrep_scan" | "trivy_scan" | "zap_scan"
    image: str                     # Docker image full reference
    command: list[str]             # override do CMD do container (geralmente vazio)
    env: dict[str, str] = Field(default_factory=dict)  # variáveis injetadas no container
    context: JobContext            # contexto agnóstico de source
    metadata: JobMetadata          # rastreabilidade
    quality_gate: "QualityGateJobContext | None" = None  # correlação ao Quality Gate (ver abaixo)
```

`QualityGateJobContext` é definido em `wire/schemas/quality_gate_v1.py` (contrato compartilhado entre captain-hook, moby-dick **e** pequod):

```python
class QualityGateJobContext(BaseModel):
    workflow_id: str                       # UUID do ciclo de Quality Gate/Baseline
    scanner: str                           # nome canônico normalizado ("sonar", "semgrep", "trivy", "zap")
    scope: Literal["pr", "branch"] = "pr"
    application_id: str | None = None      # UUID, se conhecido
    branch_name: str | None = None         # obrigatório quando scope="branch"
```

`job.quality_gate` é o que permite ao `moby-dick` correlacionar o job ao workflow e disparar a avaliação síncrona no pequod (`workflow_id` + `scanner`) — sem vazar nenhum termo de GitHub para dentro do contexto do Quality Gate.

## Exemplo real — scope `pr` (SonarQube)

```json
{
  "schema_version": "1",
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "kind": "sonar_scan",
  "image": "aspm-sonar-runner:latest",
  "command": [],
  "env": {
    "SONAR_HOST_URL": "http://aspm-sonarqube:9000",
    "SONAR_TOKEN": "********",
    "SONAR_PROJECT_KEY": "gh_847291",
    "SONAR_PROJECT_NAME": "OdinEye-FIAP/clint-eastwood",
    "SONAR_PULLREQUEST_KEY": "5",
    "SONAR_PULLREQUEST_BRANCH": "demo/sonarqube-findings-full",
    "SONAR_PULLREQUEST_BASE": "main",
    "REPO_FULL_NAME": "OdinEye-FIAP/clint-eastwood",
    "REPO_ID": "847291",
    "HEAD_SHA": "4b743b61fd35f90deb04a673ed03ac0133ec441f"
  },
  "context": {
    "source": "github",
    "repo": "OdinEye-FIAP/clint-eastwood",
    "ref": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
    "trigger": "pull_request.synchronize",
    "scope": "pr",
    "branch_name": null,
    "application_id": null,
    "callback": {
      "type": "github_check_run",
      "owner": "OdinEye-FIAP",
      "repo": "clint-eastwood",
      "head_sha": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
      "name": "SonarQube Scan"
    }
  },
  "metadata": {
    "created_at": "2026-06-17T15:42:18.123456+00:00",
    "delivery_id": "12345678-90ab-cdef-1234-567890abcdef"
  },
  "quality_gate": {
    "workflow_id": "6f1c9a4e-2b3d-4a5e-9c1a-0f8e7d6c5b4a",
    "scanner": "sonar",
    "scope": "pr",
    "application_id": null,
    "branch_name": null
  }
}
```

## Exemplo real — scope `branch` (Security Baseline, Trivy)

Disparado por `push` na default branch (`controller/push_controller.py` + `adapter/wire_out/scanners/trivy_scanner.py::build_baseline_job`). Sem `SONAR_PULLREQUEST_*`/`base_ref`; `HEAD_SHA` é o `after` do push.

```json
{
  "schema_version": "1",
  "job_id": "b2f6e1d0-...",
  "kind": "trivy_scan",
  "image": "aspm-trivy-runner:latest",
  "command": [],
  "env": {
    "GIT_REPO_URL": "https://github.com/OdinEye-FIAP/clint-eastwood.git",
    "GIT_REF": "9a8b7c6d5e4f...",
    "REPO_FULL_NAME": "OdinEye-FIAP/clint-eastwood",
    "REPO_ID": "847291",
    "HEAD_SHA": "9a8b7c6d5e4f...",
    "BRANCH_NAME": "main"
  },
  "context": {
    "source": "github",
    "repo": "OdinEye-FIAP/clint-eastwood",
    "ref": "9a8b7c6d5e4f...",
    "trigger": "push.baseline",
    "scope": "branch",
    "branch_name": "main",
    "application_id": null,
    "callback": {
      "type": "github_check_run",
      "owner": "OdinEye-FIAP",
      "repo": "clint-eastwood",
      "head_sha": "9a8b7c6d5e4f...",
      "name": "Trivy Baseline"
    }
  },
  "metadata": {
    "created_at": "2026-08-02T09:10:00.000000+00:00",
    "delivery_id": "aaaa1111-..."
  },
  "quality_gate": {
    "workflow_id": "c3d4e5f6-...",
    "scanner": "trivy",
    "scope": "branch",
    "application_id": null,
    "branch_name": "main"
  }
}
```

## Campos por categoria

### Identificadores

| Campo | Tipo | Origem |
|---|---|---|
| `schema_version` | str | constante `"1"` |
| `job_id` | str | UUID5 determinístico: `uuid.uuid5(UUID(workflow_id), f"scanner:{scanner}")` (`adapter/wire_in/pull_request_adapter.py::scanner_job_id`) — mesmo job_id em redeliveries |
| `metadata.delivery_id` | str | header `X-GitHub-Delivery` do webhook |
| `metadata.created_at` | str | ISO 8601 UTC |

### Execução

| Campo | Tipo | Significado |
|---|---|---|
| `kind` | str | tipo lógico do job: `sonar_scan`, `semgrep_scan`, `trivy_scan`, `zap_scan` |
| `image` | str | Docker image full reference; moby-dick passa direto pro `containers.run` |
| `command` | list[str] | override do CMD; geralmente `[]` (ENTRYPOINT da imagem cuida) |
| `env` | dict[str, str] | injetado no container; **`GIT_TOKEN` é mesclado em runtime pelo moby-dick**, nunca vem do captain-hook |

### Contexto

| Campo | Tipo | Significado |
|---|---|---|
| `context.source` | str | sistema de origem; hoje sempre `github` |
| `context.repo` | str | `owner/repo` |
| `context.ref` | str | commit SHA sendo analisado |
| `context.trigger` | str | `<event>.<action>` (ex: `pull_request.synchronize`) ou `<event>.baseline` (ex: `push.baseline`) |
| `context.scope` | `"pr"` \| `"branch"` | `"pr"` (default, compatível com producers antigos) ou `"branch"` para Security Baseline |
| `context.branch_name` | str \| None | nome da branch quando `scope="branch"`; `None` em `scope="pr"` |
| `context.application_id` | str \| None | aditivo, reservado para correlação futura com o inventário de aplicações do pequod |

### Callback

| Campo | Tipo | Significado |
|---|---|---|
| `callback.type` | str | `github_check_run` (futuro: `gitlab_pipeline_status`, etc) |
| `callback.owner` | str | GitHub owner |
| `callback.repo` | str | GitHub repo |
| `callback.head_sha` | str | SHA do commit que recebe o check individual |
| `callback.name` | str | display name do check individual no PR/commit (ex: `SonarQube Scan`, `Semgrep SAST`, `Trivy SCA`, `OWASP ZAP DAST`; variantes `*-Baseline` em `scope=branch`) |

### Quality Gate

| Campo | Tipo | Significado |
|---|---|---|
| `quality_gate.workflow_id` | str (UUID) | UUID5 estável por (repo, pr, head_sha) em `scope=pr`, ou por (repo, branch, head_sha) em `scope=branch` — redeliveries convergem para o mesmo workflow |
| `quality_gate.scanner` | str | nome canônico normalizado (`sonar`, `semgrep`, `trivy`, `zap`) |
| `quality_gate.scope` | `"pr"` \| `"branch"` | espelha `context.scope` |
| `quality_gate.application_id` | str \| None | aditivo |
| `quality_gate.branch_name` | str \| None | obrigatório quando `scope="branch"` |

Ausência de `quality_gate` (`None`) é suportada — moby-dick apenas não chama o pequod nem publica `quality-gate.scanner.completed.v1` para esse job.

## Particionamento Kafka

Mensagem publicada em `jobs.orchestration` com:

- **Key:** `context.repo` (= `owner/repo`)
- **Value:** JSON serializado do JobDescriptor

Razão: garantir ordem por repositório. Jobs do mesmo repo não correm em paralelo (importante quando Sonar Community sobrescreve análise main).

## Versionamento

| Versão | Status | Mudanças |
|---|---|---|
| **v1** | atual | versão inicial; campos `context.scope`/`branch_name`/`application_id` e `JobDescriptor.quality_gate` foram adicionados de forma aditiva e opcional, sem bump de `schema_version` |
| v2 | futuro hipotético | possível adicionar `priority`, `timeout_override`, `secrets_ref` |

Quando v2 for necessário (mudança breaking, não aditiva), captain-hook publica nas duas versões em paralelo durante migração. Consumers leem `schema_version` e despacham.

## Validação

Tanto captain-hook quanto moby-dick usam Pydantic. Mensagem inválida:

- captain-hook publica: Pydantic já validou no momento da construção
- moby-dick consome: `JobDescriptor(**parsed_json)` valida na deserialização. Mensagem malformada → exception, mensagem **não é commitada** no consumer group, voltará a ser entregue (retry implícito).

## Convenção SONAR_PROJECT_KEY

`SONAR_PROJECT_KEY` é derivado de `github.repository.id` (inteiro estável), montado em `adapter/wire_out/scanners/sonar_scanner.py`:

| Env | Valor | Imutável? |
|---|---|---|
| `SONAR_PROJECT_KEY` | `gh_<repository.id>` (ex: `gh_847291`) | ✅ sobrevive a rename/transfer |
| `SONAR_PROJECT_NAME` | `<owner>/<repo>` (ex: `OdinEye-FIAP/clint-eastwood`) | ❌ atualiza a cada scan p/ refletir nome atual |
| `REPO_FULL_NAME` | igual a `SONAR_PROJECT_NAME` (também usado pelos demais scanners para montar `GIT_REPO_URL`) | ❌ |
| `REPO_ID` | `<repository.id>` cru (ex: `847291`) | ✅ usado como key do `findings.raw` no formato `gh_<id>` |

Ver [Decisão §13](../overview/decisions.md#13-sonar_project_key-derivado-de-githubrepositoryid).

## Env vars por scanner (fora de SonarQube)

Semgrep, Trivy e ZAP não usam `SONAR_*`; usam um conjunto comum baseado em clone git:

| Env | Presente em | Significado |
|---|---|---|
| `GIT_REPO_URL` | semgrep, trivy, zap | `https://github.com/<repo_full_name>.git` |
| `GIT_REF` | semgrep, trivy, zap | `head_sha` a ser clonado/checked out |
| `REPO_FULL_NAME` / `REPO_ID` / `HEAD_SHA` | todos | idem aos usados pelo SonarQube |
| `BRANCH_NAME` | todos, só em `scope=branch` | nome da branch do Security Baseline |
| `TARGET_URL` / `DAST_MODE` / `DAST_COMPOSE_FILE` / `DAST_SERVICE_NAME` / `DAST_TARGET_PORT` / `DAST_HEALTH_PATH` / `MOBY_MOUNT_DOCKER_SOCKET` | zap | configuração do DAST (ver [moby-dick](../moby-dick.md#scanners-suportados)) |

`GIT_TOKEN` nunca aparece nesta lista — é sempre mesclado pelo moby-dick em runtime (ver abaixo).

## Coisas que NÃO estão no JobDescriptor

- ❌ `GIT_TOKEN` — injetado pelo moby-dick em runtime (`job_controller.py`), nunca publicado no Kafka
- ❌ webhook payload completo — não é republicado; captain-hook extrai só o necessário para `JobContext`
- ❌ resultado do scan — feedback vai via `check_run` individual + consolidado no PR/commit, e `findings.raw` no Kafka (consumido pelo pequod)

## Considerações pra V2

Decisões em aberto:

- **Priority field:** scans urgentes (release) vs rotina (PRs internos)
- **Timeout override:** alguns scanners (DAST) demoram mais; hoje todos compartilham `DOCKER_RUN_TIMEOUT_SECONDS`
- **Secret ref:** evitar tokens em texto claro no JSON publicado; referenciar nome de Secret em vault
- **Multiple callbacks:** 1 job poderia reportar pra múltiplos lugares (GitHub check + Slack notify + findings.raw)
- **Retry policy:** controle granular por job em vez de só por consumer
