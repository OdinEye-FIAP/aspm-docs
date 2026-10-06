# Começando

Guia para subir o ecossistema ASPM-AI do zero em ambiente **local**. Para
subir na VPS, siga este guia só até entender as peças e continue em
[Deploy na VPS](deploy-vps.md).

Tudo que é repetitivo está automatizado em [`ops/scripts/`](https://github.com/OdinEye-FIAP/aspm-docs/tree/main/ops/scripts)
deste repositório. Os passos manuais abaixo explicam o que cada script faz, para
você conseguir depurar quando algo sair do roteiro.

## O que compõe o ecossistema

| Componente | Tipo | Porta | Papel |
|---|---|---|---|
| `redpanda` (+ `redpanda-console`) | container | 9092 (Kafka), 8088 (UI) | Broker Kafka |
| `sonarqube` (+ `sonar-db`) | container | 9000 | Scanner SAST |
| `pequod-db` | container | 5433 | Postgres compartilhado por pequod e tars-ai |
| `captain-hook` | serviço Python | 8080 | Recebe webhooks do GitHub, publica jobs |
| `moby-dick` | serviço Python | 9090 | Consome jobs, roda scanners em containers Docker |
| `pequod` | serviço Python | 7070 | Persiste findings, Quality Gate, API de domínio |
| `tars-ai` | serviço Python | 6060 | Análise de findings por IA |
| `heimdall-dashboard` | SPA (Vite) | 5173 (dev) | Frontend |
| `aspm-*-runner` | imagens Docker | — | Scanners efêmeros executados pelo moby-dick |

## Pré-requisitos

| Ferramenta | Versão |
|---|---|
| Docker + Docker Compose | 20.10+ / v2 (v2.24.4+ na VPS) |
| Python | 3.11+ |
| Node.js + npm | 20+ (só para o dashboard) |
| Git | 2.30+ |
| GitHub App configurado | ver [GitHub App](github-app-setup.md) |
| Acesso aos repos OdinEye-FIAP | clonar privados |

!!! note "Windows"
    Os scripts são `bash`. No Windows use **WSL2** com a integração do Docker
    Desktop habilitada, e mantenha os repos dentro do filesystem do WSL
    (`~/dev/aspm-ai`), não em `/mnt/c`.

## Clone dos repos

```bash
mkdir -p ~/dev/aspm-ai && cd ~/dev/aspm-ai
for r in captain-hook moby-dick pequod tars-ai heimdall-dashboard aspm-docs; do
  git clone git@github.com:OdinEye-FIAP/$r.git
done
export ASPM_HOME=~/dev/aspm-ai
```

Todos os scripts usam `ASPM_HOME` para achar os repos. Os exemplos abaixo
assumem `cd $ASPM_HOME/aspm-docs/ops/scripts`.

## Caminho rápido

```bash
cd $ASPM_HOME/aspm-docs/ops/scripts

./infra-up.sh                                   # 1. rede + Redpanda + Sonar + Postgres + tópicos
./bootstrap-env.sh                              # 2. segredos compartilhados + .env de cada serviço
SONAR_ADMIN_PASSWORD='SenhaForte!123' \
  ./sonar-bootstrap.sh --write-to $ASPM_HOME/captain-hook/.env   # 3. token do Sonar
./build-scanners.sh                             # 4. imagens dos scanners
```

Depois: preencher os itens manuais (GitHub App e IA), subir os serviços
([passo 7](#7-subir-os-servicos)) e validar com `./smoke-test.sh`.

## 1. Infraestrutura (compose)

```bash
./infra-up.sh
```

O script, em ordem:

1. cria a rede `aspm-net` (o compose do captain-hook a declara; o do pequod a
   consome como `external`, então **ela precisa existir antes**);
2. sobe Redpanda, Redpanda Console, SonarQube e `sonar-db` (compose do
   `captain-hook`) e espera os healthchecks;
3. sobe o Postgres do pequod (compose do `pequod`); o `deploy/schema.sql` é
   aplicado automaticamente **somente no primeiro boot do volume**;
4. cria os [tópicos Kafka](../reference/kafka-topics.md) e DLQs
   (`create-topics.sh`, idempotente);
5. aguarda o SonarQube responder `UP`.

!!! warning "Linux: `vm.max_map_count`"
    O SonarQube (Elasticsearch embutido) exige `vm.max_map_count >= 262144`.
    O script ajusta e persiste o valor em `/etc/sysctl.d/` (pede `sudo`).

??? note "Equivalente manual"
    ```bash
    docker network create aspm-net
    (cd captain-hook && docker compose up -d)
    (cd pequod && docker compose up -d)
    for t in jobs.orchestration jobs.orchestration.dlq findings.raw findings.raw.dlq \
             quality-gate.workflow.started.v1 quality-gate.scanner.completed.v1 \
             quality-gate.evaluated.v1 quality-gate.moby-dick.dlq quality-gate.pequod.dlq; do
      docker exec aspm-redpanda rpk topic create "$t" -p 3 -r 1
    done
    ```

## 2. Configuração dos serviços (`.env`)

```bash
./bootstrap-env.sh
```

Cria `.env` em cada repo a partir do `.env.example` e **gera os segredos que
precisam ser idênticos entre serviços** (`KAFKA_MESSAGE_SECRET` e os tokens
`X-Service-Token`). Os valores ficam em `$ASPM_HOME/.aspm-secrets.env`
(`chmod 600`); rodar de novo não troca nada. A tabela completa de quem precisa
combinar com quem está em [Configuração compartilhada](shared-config.md).

Itens que o script **não** preenche:

| Onde | Variável | Origem |
|---|---|---|
| captain-hook, moby-dick | `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID` | página da GitHub App |
| captain-hook, moby-dick | `GITHUB_APP_PRIVATE_KEY_PATH` | caminho da `.pem` da App (nunca commitar) |
| GitHub App (Settings) | Webhook secret | valor de `GITHUB_WEBHOOK_SECRET` em `.aspm-secrets.env` |
| tars-ai | `AI_PROVIDER` e chave (`GROQ_API_KEY`, `GEMINI_API_KEY`, `HUGGINGFACE_API_KEY`) | padrão é `mock` |

## 3. Token do SonarQube

```bash
SONAR_ADMIN_PASSWORD='SenhaForte!123' \
  ./sonar-bootstrap.sh --write-to $ASPM_HOME/captain-hook/.env
```

Troca a senha `admin/admin`, gera um *Global Analysis Token* (`aspm-pipeline`) e
grava em `SONAR_TOKEN` do captain-hook. Sem `--write-to` ele apenas imprime o
token. Rodar novamente revoga o token anterior e gera outro.

!!! info "Só o captain-hook tem `SONAR_*`"
    O `.env.example` do moby-dick não tem variáveis `SONAR_*`: host e token são
    configurados no captain-hook.

## 4. Imagens dos scanners

```bash
./build-scanners.sh              # sonar semgrep trivy zap
./build-scanners.sh sonar        # só um
```

Gera `aspm-sonar-runner`, `aspm-semgrep-runner`, `aspm-trivy-runner` e
`aspm-zap-runner` a partir de `moby-dick/deploy/*-runner/`.

!!! warning "Imagens locais"
    Elas **não estão em registry**: precisam ser buildadas na máquina onde o
    moby-dick roda. Semgrep, Trivy e ZAP só são usados se
    `ENABLE_SEMGREP_SCAN`, `ENABLE_TRIVY_SCAN` e `ENABLE_ZAP_SCAN` estiverem
    `true` no `.env` do captain-hook (o Sonar é sempre ativo).

## 5. Dependências Python

```bash
for s in captain-hook moby-dick pequod tars-ai; do
  (cd $ASPM_HOME/$s && python -m venv .venv && .venv/bin/pip install -r requirements.txt)
done
```

## 6. Dashboard

```bash
cd $ASPM_HOME/heimdall-dashboard
cp .env.example .env     # VITE_*_API_URL já apontam para localhost
npm ci
```

## 7. Subir os serviços

Um terminal por serviço (cada um lê seu `.env` da raiz do repo):

```bash
cd $ASPM_HOME/pequod        && .venv/bin/uvicorn main:app --port 7070 --reload
cd $ASPM_HOME/tars-ai       && .venv/bin/uvicorn main:app --port 6060 --reload
cd $ASPM_HOME/captain-hook  && .venv/bin/uvicorn main:app --port 8080 --reload
cd $ASPM_HOME/moby-dick     && .venv/bin/uvicorn main:app --port 9090 --reload
cd $ASPM_HOME/heimdall-dashboard && npm run dev     # http://localhost:5173
```

Prefira subir o **pequod primeiro**: captain-hook e moby-dick o chamam por HTTP
(registro de repositório e avaliação do Quality Gate).

Em servidor, use systemd — veja [Deploy na VPS](deploy-vps.md).

## 8. Expor o captain-hook ao GitHub

O GitHub precisa alcançar `POST /webhook`.

=== "Local (ngrok)"

    ```bash
    ngrok http 8080
    ```

    Em **GitHub App → Webhook URL**, use `https://<id>.ngrok-free.app/webhook`.

=== "VPS (domínio + Caddy)"

    `https://hook.<BASE_DOMAIN>/webhook` — veja [Deploy na VPS](deploy-vps.md).

O *Webhook secret* da App deve ser o mesmo `GITHUB_WEBHOOK_SECRET` do captain-hook.

## 9. Validar

```bash
./smoke-test.sh
```

Verifica rede, containers, tópicos, imagens de scanner e o `/health` de cada
serviço. Com tudo verde, dispare o primeiro scan:

1. Abra um PR em um repo com a GitHub App instalada (ex.: `aspm-vuln-lab`).
2. Acompanhe o fluxo nos logs: captain-hook recebe o webhook → publica em
   `jobs.orchestration` → moby-dick sobe o container (`docker ps --filter "name=moby-job-"`)
   → pequod ingere `findings.raw` → o *check run* aparece na aba **Checks** do PR.
3. Veja a análise no SonarQube (http://localhost:9000) e os findings:
   ```bash
   curl 'http://localhost:7070/findings?repo=OdinEye-FIAP/clint-eastwood&limit=5' | jq
   ```
4. Abra o dashboard em http://localhost:5173.

## Layout final

```
~/dev/aspm-ai/
├── .aspm-secrets.env       # segredos gerados (chmod 600, fora do git)
├── captain-hook/           # FastAPI + Kafka producer + webhook
├── moby-dick/              # FastAPI + Kafka consumer + Docker + SARIF publisher
├── pequod/                 # FastAPI + Kafka consumer + Postgres + REST
├── tars-ai/                # FastAPI + análise de IA
├── heimdall-dashboard/     # React + Vite
├── aspm-docs/              # esta doc + ops/ (scripts, Caddy, systemd)
└── (containers)
    ├── aspm-redpanda, aspm-redpanda-console
    ├── aspm-sonarqube, aspm-sonar-db
    ├── aspm-pequod-db
    └── moby-job-*          # efêmeros
```

## Próximos

- [Deploy na VPS](deploy-vps.md)
- [Configuração compartilhada](shared-config.md)
- [Adicionar novo scanner](adding-a-scanner.md)
- [Troubleshooting](troubleshooting.md)
