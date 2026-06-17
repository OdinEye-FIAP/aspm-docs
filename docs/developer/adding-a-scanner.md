# Adicionar novo scanner

Como adicionar um scanner novo (Semgrep, Trivy, Bandit, etc) ao pipeline sem refatorar moby-dick ou captain-hook.

## Princípio

Scanner novo = nova **imagem Docker** + nova lógica de quando disparar. Nada mais.

```mermaid
flowchart LR
    A[captain-hook] -->|decide qual scanner| B[JobDescriptor.image=X]
    B --> C[moby-dick]
    C -->|docker run X| D[Container scanner]
    D -->|exit code| E[check_run]
```

## Passo a passo

### 1. Decidir a imagem base

Padrão = wrapper sobre image oficial do scanner + git + entrypoint custom.

Exemplo para Semgrep:

```dockerfile
# moby-dick/deploy/semgrep-runner/Dockerfile
FROM returntocorp/semgrep:latest

USER root
RUN command -v git >/dev/null || (apk add --no-cache git || apt-get install -y git)

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /src
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 2. Escrever entrypoint

Mesmo padrão do `sonar-runner`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${GIT_TOKEN:?GIT_TOKEN ausente}"
: "${REPO_FULL_NAME:?REPO_FULL_NAME ausente}"
: "${HEAD_SHA:?HEAD_SHA ausente}"

git clone --depth 50 \
  "https://x-access-token:${GIT_TOKEN}@github.com/${REPO_FULL_NAME}.git" /src
cd /src
git checkout "${HEAD_SHA}"

unset GIT_TOKEN

# Semgrep CI mode: exit 0 = clean, exit 1 = findings, exit 2+ = erro de execução
exec semgrep ci --config=auto
```

Exit code é o veredito. moby-dick mapeia direto pra check_run.

### 3. Buildar a imagem

```bash
docker build -t aspm-semgrep-runner:latest moby-dick/deploy/semgrep-runner/
```

### 4. Decidir como disparar

3 opções, da mais simples à mais flexível.

#### Opção A: scanner único (substituir Sonar)

Em `captain-hook/.env`:
```env
DEFAULT_JOB_IMAGE=aspm-semgrep-runner:latest
```

Pronto. Todo PR scaneia com Semgrep em vez de Sonar.

#### Opção B: roteamento por config no captain-hook

Editar `controller/webhook_controller.py`:

```python
SCANNER_BY_REPO = {
    "OdinEye-FIAP/captain-hook": "aspm-semgrep-runner:latest",
    "OdinEye-FIAP/moby-dick": "aspm-sonar-runner:latest",
    # ...
}

def _maybe_build_job(webhook):
    image = SCANNER_BY_REPO.get(repo_full_name, settings.default_job_image)
    return JobDescriptor(image=image, ...)
```

Cada repo escolhe scanner.

#### Opção C: fan-out (rodar N scanners por PR)

Mudar `process_webhook` pra publicar **N JobDescriptors** por evento (1 por scanner). Cada um vira check_run separado no PR.

```python
SCANNERS = [
    ("aspm-sonar-runner:latest", "sonar_scan", "SonarQube Scan"),
    ("aspm-semgrep-runner:latest", "semgrep_scan", "Semgrep"),
    ("aspm-trivy-runner:latest", "trivy_scan", "Trivy"),
]

for image, kind, check_name in SCANNERS:
    job = JobDescriptor(image=image, kind=kind, ...)
    job.context.callback.name = check_name
    await publisher.publish(topic, key, job.model_dump())
```

moby-dick processa todos em paralelo (capacidade do consumer group).

Esse é o **modelo ASPM real**. Adoção plena vai por aqui.

### 5. Env vars do scanner novo

Cada scanner pode precisar de envs diferentes. Adicione no captain-hook:

```python
env_by_scanner = {
    "semgrep": {
        "SEMGREP_APP_TOKEN": settings.semgrep_token,
    },
    "trivy": {
        "TRIVY_DB_REPO": "ghcr.io/aquasecurity/trivy-db",
    },
    "sonar": {
        "SONAR_HOST_URL": settings.sonar_host_url,
        "SONAR_TOKEN": settings.sonar_token,
        "SONAR_PROJECT_KEY": f"{owner}_{repo_name}",
    },
}
```

Variáveis comuns (sempre passar):

- `REPO_FULL_NAME`
- `HEAD_SHA`
- `SONAR_PULLREQUEST_*` se aplicável

`GIT_TOKEN` continua sendo injetado pelo moby-dick — nunca colocar em env_by_scanner.

### 6. Garantir que a image está disponível na VPS

```bash
# Na VPS
cd /caminho/moby-dick
git pull origin main
docker build -t aspm-semgrep-runner:latest deploy/semgrep-runner/
```

Não precisa restart do moby-dick — próximo `docker run` pega a imagem nova.

### 7. Testar

Push em PR de teste. Acompanhar:

```bash
sudo journalctl -u moby-dick -f
docker ps --filter "name=moby-job-"
docker logs $(docker ps -a --filter "name=moby-job-" --latest -q)
```

## Convenções de naming

| Tipo | Convenção |
|---|---|
| Imagem Docker | `aspm-<scanner>-runner:latest` |
| Pasta no moby-dick | `deploy/<scanner>-runner/` |
| `kind` no JobDescriptor | `<scanner>_scan` (ex: `sonar_scan`, `semgrep_scan`) |
| Check name no PR | nome oficial do scanner (ex: `SonarQube Scan`, `Semgrep`) |

## Boas práticas

- **Stateless absoluto:** sem cache, sem volume, sem state entre runs. Se precisar de cache, adiciona depois com mount opcional.
- **Exit code é o veredito:** 0 = pass, !=0 = fail. Não tentar fazer "neutral" via lógica complexa.
- **`unset GIT_TOKEN` no entrypoint** antes de chamar o scanner — evita vazamento em logs.
- **Pinning de versão:** `aspm-trivy-runner:0.50.0` em vez de `:latest` quando o scanner for sensível a versão.
- **`set -e` no entrypoint:** falha cedo, falha barulhento.
- **Timeout:** moby-dick aplica `DOCKER_RUN_TIMEOUT_SECONDS`. Scanners pesados podem precisar de override por job no futuro.

## Considerações de performance

- **Pull inicial pesado:** primeira execução de scanner novo baixa a imagem (~500MB-2GB). Pre-pull na VPS via cron se quiser evitar latência no primeiro PR.
- **Clone duplicado:** se rodar 3 scanners no mesmo PR via fan-out, 3 clones. Aceitável até virar gargalo — solução futura é volume de cache compartilhado.
- **Concorrência:** moby-dick processa jobs sequencialmente hoje (consumer group simples). Pra paralelismo real, escalar moby-dick em N réplicas no mesmo group.

## Quando o scanner novo virar 2º estável

É o momento de **revisitar** a decisão "ignorar storage central" do [decisions.md](../overview/decisions.md). Com 2+ fontes de findings, agregar passa a fazer sentido.
