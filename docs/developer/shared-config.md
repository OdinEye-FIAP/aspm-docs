# Configuração compartilhada

Boa parte das falhas ao subir o ecossistema vem de **um valor que precisa ser
igual em dois serviços e não é**. Esta página lista cada par. O script
[`bootstrap-env.sh`](https://github.com/OdinEye-FIAP/aspm-docs/blob/main/ops/scripts/bootstrap-env.sh)
já gera e distribui todos os valores abaixo.

## Segredos que precisam ser idênticos

| Valor | Onde configurar | Observação |
|---|---|---|
| Assinatura das mensagens Kafka | `KAFKA_MESSAGE_SECRET` em **captain-hook**, **moby-dick** e **pequod** | Com `KAFKA_REQUIRE_SIGNATURE=true` o consumidor descarta mensagens sem assinatura válida |
| Webhook do GitHub | `GITHUB_WEBHOOK_SECRET` no **captain-hook** = *Webhook secret* da GitHub App | HMAC inválido responde `401` |
| captain-hook → pequod | `PEQUOD_SERVICE_TOKEN` no **captain-hook** = `CAPTAIN_HOOK_SERVICE_TOKEN` no **pequod** | Header `X-Service-Token` |
| moby-dick → pequod | `PEQUOD_SERVICE_TOKEN` no **moby-dick** = `MOBY_DICK_SERVICE_TOKEN` no **pequod** | Header `X-Service-Token` |
| tars-ai → pequod | `PEQUOD_SERVICE_TOKEN` no **tars-ai** = `TARS_SERVICE_TOKEN` no **pequod** | Header `X-Service-Token` |
| moby-dick → tars-ai | `TARS_SERVICE_TOKEN` no **moby-dick** = `TARS_SERVICE_TOKEN` no **tars-ai** | `POST /ai/suggest-fix`; sem token no tars-ai a rota responde `503` |

!!! tip "Como o pequod valida o header"
    Cada endpoint interno do pequod aceita o token de um ou mais serviços
    chamadores (`moby-dick`, `tars-ai`, `captain-hook`), cada um lido de uma
    variável própria. Por isso o `TARS_SERVICE_TOKEN` do **pequod** é o token que
    o **tars-ai envia**, e não o que o tars-ai exige de quem o chama (são dois
    valores distintos, gerados separadamente por `bootstrap-env.sh`).

!!! danger "Token vazio = endpoint aberto"
    Se nenhum token relevante estiver configurado no pequod, o endpoint **não
    exige autenticação** (comportamento pensado para dev local). Em produção,
    os três tokens (`CAPTAIN_HOOK_`, `MOBY_DICK_` e `TARS_SERVICE_TOKEN`)
    devem estar preenchidos.

## URLs entre serviços

| Quem | Variável | Aponta para |
|---|---|---|
| captain-hook, moby-dick, tars-ai | `PEQUOD_BASE_URL` | pequod (`http://localhost:7070`) |
| moby-dick | `TARS_BASE_URL` | tars-ai (`http://localhost:6060`) |
| moby-dick | `HEIMDALL_BASE_URL` | dashboard (link no *check run*) |
| todos os Python | `KAFKA_BOOTSTRAP_SERVERS` | `localhost:9092` (serviços no host) |
| captain-hook | `SONAR_HOST_URL` | `http://sonarqube:9000` (visto de dentro da `aspm-net`) |
| moby-dick | `DOCKER_NETWORK` | `aspm-net` (rede onde os jobs enxergam o Sonar) |
| pequod, tars-ai | `DATABASE_URL` | Postgres do pequod (`localhost:5433`); o tars-ai usa o mesmo banco |
| dashboard | `VITE_PEQUOD_API_URL`, `VITE_TARS_API_URL`, `VITE_CAPTAIN_HOOK_API_URL` | embutidas **no build** |

## CORS

| Serviço | Como libera o dashboard |
|---|---|
| captain-hook | `CORS_ALLOWED_ORIGINS` (env) |
| pequod | `CORS_ALLOWED_ORIGINS` (env) |
| tars-ai | **lista fixa no código** (`main.py`: apenas `localhost`/`127.0.0.1` nas portas 5173 e 4173) |

Como o tars-ai não aceita outra origem sem mudar código, o deploy na VPS serve o
dashboard e as três APIs **pelo mesmo host** (proxy do Caddy), o que dispensa
CORS. Se um dia o dashboard for servido de outro domínio, será preciso tornar a
lista do tars-ai configurável.

## Portas

| Porta | Serviço | Exposição na VPS |
|---|---|---|
| 80 / 443 | Caddy | pública |
| 8080 | captain-hook | via Caddy (`hook.<BASE_DOMAIN>`) |
| 7070 | pequod | via Caddy (`/api/pequod`) |
| 6060 | tars-ai | via Caddy (`/api/tars`) |
| 9090 | moby-dick | interna |
| 9092, 9644, 8088 | Redpanda, admin, Console | `127.0.0.1` |
| 9000 | SonarQube | `127.0.0.1` |
| 5433 | Postgres do pequod | `127.0.0.1` |
