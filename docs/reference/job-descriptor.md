# JobDescriptor v1

Contrato de mensagem entre captain-hook e moby-dick. Schema versionado, source-of-truth em `wire/schemas/job_v1.py` (copiado entre os 2 repos por enquanto).

## Schema completo

```python
class JobDescriptor(BaseModel):
    schema_version: str = "1"
    job_id: str                    # UUID4
    kind: str                      # "sonar_scan", futuramente outros
    image: str                     # Docker image full reference
    command: List[str]             # override do CMD do container (geralmente vazio)
    env: Dict[str, str]            # variáveis injetadas no container
    context: JobContext            # contexto agnóstico de source
    metadata: JobMetadata          # rastreabilidade


class JobContext(BaseModel):
    source: str                    # "github" (no futuro: "gitlab", "bitbucket")
    repo: str                      # "owner/repo"
    ref: str                       # HEAD SHA
    trigger: str                   # "pull_request.synchronize" etc
    callback: JobCallback


class JobCallback(BaseModel):
    type: str                      # "github_check_run"
    owner: str                     # GitHub owner
    repo: str                      # GitHub repo
    head_sha: str                  # SHA pro check_run
    name: str                      # display name do check ("SonarQube Scan")


class JobMetadata(BaseModel):
    created_at: str                # ISO 8601 UTC
    delivery_id: str               # X-GitHub-Delivery do webhook
```

## Exemplo real

```json
{
  "schema_version": "1",
  "job_id": "550e8400-e29b-41d4-a716-446655440000",
  "kind": "sonar_scan",
  "image": "aspm-sonar-runner:latest",
  "command": [],
  "env": {
    "SONAR_HOST_URL": "http://aspm-sonarqube:9000",
    "SONAR_TOKEN": "sqa_xxxxxxxxxxxxxx",
    "SONAR_PROJECT_KEY": "OdinEye-FIAP_clint-eastwood",
    "SONAR_PULLREQUEST_KEY": "5",
    "SONAR_PULLREQUEST_BRANCH": "demo/sonarqube-findings-full",
    "SONAR_PULLREQUEST_BASE": "main",
    "REPO_FULL_NAME": "OdinEye-FIAP/clint-eastwood",
    "HEAD_SHA": "4b743b61fd35f90deb04a673ed03ac0133ec441f"
  },
  "context": {
    "source": "github",
    "repo": "OdinEye-FIAP/clint-eastwood",
    "ref": "4b743b61fd35f90deb04a673ed03ac0133ec441f",
    "trigger": "pull_request.synchronize",
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
  }
}
```

## Campos por categoria

### Identificadores

| Campo | Tipo | Origem |
|---|---|---|
| `schema_version` | str | constante `"1"` |
| `job_id` | str | `uuid.uuid4()` gerado em captain-hook |
| `metadata.delivery_id` | str | header `X-GitHub-Delivery` do webhook |
| `metadata.created_at` | str | `datetime.utcnow().isoformat()` |

### Execução

| Campo | Tipo | Significado |
|---|---|---|
| `kind` | str | tipo lógico do job (`sonar_scan`, futuro `semgrep_scan` etc) |
| `image` | str | Docker image full reference; moby-dick passa direto pro `containers.run` |
| `command` | List[str] | override do CMD; geralmente `[]` (ENTRYPOINT da imagem cuida) |
| `env` | Dict[str, str] | injetado no container; **GIT_TOKEN é mesclado em runtime pelo moby-dick** |

### Contexto

| Campo | Tipo | Significado |
|---|---|---|
| `context.source` | str | sistema de origem; hoje sempre `github` |
| `context.repo` | str | `owner/repo` |
| `context.ref` | str | commit SHA sendo analisado |
| `context.trigger` | str | `<event>.<action>` (ex: `pull_request.synchronize`) |

### Callback

| Campo | Tipo | Significado |
|---|---|---|
| `callback.type` | str | `github_check_run` (futuro: `gitlab_pipeline_status`, etc) |
| `callback.owner` | str | GitHub owner |
| `callback.repo` | str | GitHub repo |
| `callback.head_sha` | str | SHA do commit que recebe o check |
| `callback.name` | str | display name no PR (ex: `SonarQube Scan`) |

## Particionamento Kafka

Mensagem publicada em `jobs.orchestration` com:

- **Key:** `context.repo` (= `owner/repo`)
- **Value:** JSON serializado do JobDescriptor

Razão: garantir ordem por repositório. Jobs do mesmo repo não correm em paralelo (importante quando Sonar Community sobrescreve análise main).

## Versionamento

| Versão | Status | Mudanças |
|---|---|---|
| **v1** | atual | Versão inicial |
| v2 | futuro hipotético | possível adicionar `priority`, `timeout_override`, `secrets_ref` |

Quando v2 for necessário, captain-hook publica nas duas versões em paralelo durante migração. Consumers leem schema_version e despacham.

## Validação

Tanto captain-hook quanto moby-dick usam Pydantic. Mensagem inválida:

- captain-hook publica: Pydantic já validou no momento da construção
- moby-dick consome: `JobDescriptor(**parsed_json)` valida na deserialização. Mensagem malformada → exception, mensagem **não é commitada** no consumer group, voltará a ser entregue (retry implícito).

## Coisas que NÃO estão no JobDescriptor

- ❌ `GIT_TOKEN` — injetado pelo moby-dick em runtime
- ❌ webhook payload completo — publicado separado em `github.events.raw`
- ❌ resultado do scan — feedback vai via `check_run`, não Kafka (hoje)

## Considerações pra V2

Decisões em aberto:

- **Priority field:** scans urgentes (release) vs rotina (PRs internos)
- **Timeout override:** alguns scanners (DAST) demoram mais; hoje todos compartilham `DOCKER_RUN_TIMEOUT_SECONDS`
- **Secret ref:** evitar tokens em texto claro no JSON publicado; referenciar nome de Secret em vault
- **Multiple callbacks:** 1 job poderia reportar pra múltiplos lugares (GitHub check + Slack notify + findings.raw)
- **Retry policy:** controle granular por job em vez de só por consumer
