# Começando

Guia pra rodar o pipeline ASPM-AI em ambiente local ou na VPS.

## Pré-requisitos

| Ferramenta | Versão |
|---|---|
| Docker + Docker Compose | 20.10+ / v2 |
| Python | 3.11+ |
| Git | 2.30+ |
| GitHub App configurado | ver [GitHub App](github-app-setup.md) |
| Acesso aos repos OdinEye-FIAP | clonar privados |

## Clone dos repos

```bash
mkdir -p ~/dev/aspm-ai && cd ~/dev/aspm-ai
git clone git@github.com:OdinEye-FIAP/captain-hook.git
git clone git@github.com:OdinEye-FIAP/moby-dick.git
git clone git@github.com:OdinEye-FIAP/pequod.git
git clone git@github.com:OdinEye-FIAP/aspm-docs.git   # opcional, esta doc
```

## 1. Subir infraestrutura (compose)

```bash
cd captain-hook
docker compose up -d
```

Vai subir:

- **`aspm-redpanda`** (broker Kafka) na porta 9092
- **`aspm-redpanda-console`** (UI Kafka) na 8088
- **`aspm-sonarqube`** na 9000
- **`aspm-sonar-db`** (postgres)
- **rede `aspm-net`** compartilhada

Aguardar Sonar ficar saudável:

```bash
until curl -sf http://localhost:9000/api/system/status | grep -q '"status":"UP"'; do
  echo "aguardando..."; sleep 3
done
```

## 2. Bootstrap do SonarQube

### Via UI

http://localhost:9000 → admin/admin → trocar senha → avatar → **My Account → Security** → gerar **Global Analysis Token**.

### Via API (servidor sem GUI)

```bash
NEW_PASS='SenhaForte!'

# trocar senha admin
curl -u admin:admin -X POST http://localhost:9000/api/users/change_password \
  -d "login=admin&previousPassword=admin&password=${NEW_PASS}"

# gerar token
curl -u admin:${NEW_PASS} -X POST http://localhost:9000/api/user_tokens/generate \
  -d "name=aspm-pipeline&type=GLOBAL_ANALYSIS_TOKEN" | jq -r '.token'
```

Copie o token retornado.

## 3. Configurar `.env` do captain-hook

```bash
cd captain-hook
cp .env.example .env
```

Edite:

```env
GITHUB_WEBHOOK_SECRET=<segredo do webhook>
APP_HOST=0.0.0.0
APP_PORT=8080
APP_ENV=local
LOG_LEVEL=INFO
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
SONAR_HOST_URL=http://aspm-sonarqube:9000
SONAR_TOKEN=<token gerado no passo 2>
DEFAULT_JOB_IMAGE=aspm-sonar-runner:latest
```

## 4. Configurar `.env` do moby-dick

```bash
cd ../moby-dick
cp .env.example .env
```

Edite:

```env
APP_HOST=0.0.0.0
APP_PORT=9090
APP_ENV=local
LOG_LEVEL=INFO
GITHUB_APP_ID=<seu app id>
GITHUB_APP_PRIVATE_KEY_PATH=./config/github-app-private-key.pem
GITHUB_INSTALLATION_ID=<seu installation id>
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_CONSUMER_GROUP=moby-dick
TOPIC_JOBS_ORCHESTRATION=jobs.orchestration
TOPIC_FINDINGS_RAW=findings.raw
SONAR_HOST_URL=http://aspm-sonarqube:9000
SONAR_TOKEN=<token gerado no passo 2>
SONAR_API_TIMEOUT_SECONDS=30
DOCKER_RUN_TIMEOUT_SECONDS=600
DOCKER_NETWORK=aspm-net
```

Coloque a private key da GitHub App em `./config/github-app-private-key.pem`.

## 4b. Subir o postgres do pequod + configurar `.env`

```bash
cd ../pequod
docker compose up -d            # sobe aspm-pequod-db na rede aspm-net
cp .env.example .env
```

Edite:

```env
APP_HOST=0.0.0.0
APP_PORT=7070
APP_ENV=local
LOG_LEVEL=INFO
KAFKA_BOOTSTRAP_SERVERS=localhost:9092
KAFKA_CONSUMER_GROUP=pequod
TOPIC_FINDINGS_RAW=findings.raw
DATABASE_URL=postgresql://pequod:pequod@localhost:5433/pequod
```

!!! tip "Migrations automáticas"
    O `docker-compose.yml` do pequod monta `deploy/migrations/` em `/docker-entrypoint-initdb.d` — postgres aplica `001_init.sql` no primeiro boot. Não precisa rodar manual.

## 5. Buildar a imagem do scanner

```bash
docker build -t aspm-sonar-runner:latest deploy/sonar-runner/
```

!!! warning "Imagem local"
    A image **não está em registry**. Precisa buildar onde o moby-dick vai rodar.

Validar:

```bash
docker images aspm-sonar-runner
docker run --rm --entrypoint node aspm-sonar-runner:latest --version
# esperado: v20+
```

## 6. Instalar dependências Python

```bash
# captain-hook
cd ../captain-hook
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# moby-dick
cd ../moby-dick
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# pequod
cd ../pequod
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
```

## 7. Subir os serviços

=== "Local (uvicorn manual)"

    Terminal 1:
    ```bash
    cd captain-hook && source venv/bin/activate
    uvicorn main:app --host 0.0.0.0 --port 8080 --reload
    ```

    Terminal 2:
    ```bash
    cd moby-dick && source venv/bin/activate
    uvicorn main:app --host 0.0.0.0 --port 9090 --reload
    ```

    Terminal 3:
    ```bash
    cd pequod && source venv/bin/activate
    uvicorn main:app --host 0.0.0.0 --port 7070 --reload
    ```

=== "VPS (systemd)"

    Cada repo tem `deploy/<service>.service`.

    ```bash
    sudo cp captain-hook/deploy/captain-hook.service /etc/systemd/system/
    sudo cp moby-dick/deploy/moby-dick.service /etc/systemd/system/
    sudo cp pequod/deploy/pequod.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now captain-hook moby-dick pequod
    sudo systemctl status captain-hook moby-dick pequod
    ```

## 8. Expor captain-hook ao GitHub

GitHub precisa alcançar o endpoint via internet.

=== "Local (ngrok)"

    ```bash
    ngrok http 8080
    ```

    Copie a URL HTTPS gerada.

=== "VPS (IP público / DNS)"

    Configure o domínio/IP no GitHub App settings → **Webhook URL** = `https://<seu-host>/webhook`.

    Use nginx ou Caddy pra TLS.

## 9. Disparar primeiro scan

1. Abra um PR num repo com o GitHub App instalado
2. Veja captain-hook receber:
   ```bash
   sudo journalctl -u captain-hook -f
   ```
3. Veja moby-dick processar:
   ```bash
   sudo journalctl -u moby-dick -f
   ```
4. Veja container subir:
   ```bash
   docker ps --filter "name=moby-job-"
   ```
5. Veja pequod ingerir o finding:
   ```bash
   sudo journalctl -u pequod -f
   ```
6. Veja check_run no PR (aba **Checks** do PR)
7. Veja análise no Sonar UI: http://localhost:9000
8. Veja findings persistidos:
   ```bash
   curl 'http://localhost:7070/findings?repo=OdinEye-FIAP/clint-eastwood&limit=5' | jq
   ```

## Layout final

```
~/dev/aspm-ai/
├── captain-hook/          # FastAPI + Kafka producer
├── moby-dick/             # FastAPI + Kafka consumer + Docker + SARIF publisher
├── pequod/                # FastAPI + Kafka consumer + asyncpg + REST findings
├── aspm-docs/             # esta doc
└── (containers)
    ├── aspm-redpanda
    ├── aspm-sonarqube
    ├── aspm-sonar-db
    ├── aspm-pequod-db
    └── moby-job-*         # efêmeros
```

## Próximos

- [Adicionar novo scanner](adding-a-scanner.md)
- [Troubleshooting](troubleshooting.md)
