# Troubleshooting

Erros reais que enfrentamos durante implementação, ordenados por componente. Cada um inclui causa, diagnóstico e fix.

## captain-hook

### `aiokafka.errors.OutOfOrderSequenceNumber`

**Sintoma:**
```
File ".../kafka_producer.py", line 44, in publish
    await self._producer.send_and_wait(topic, value=value, key=key)
aiokafka.errors.OutOfOrderSequenceNumber: [Error 45] OutOfOrderSequenceNumber
```

**Causa:** Redpanda foi reiniciado/recriado e perdeu estado de Producer ID. Producer aiokafka mantém PID + sequence em memória; broker novo não reconhece.

**Fix imediato:**
```bash
sudo systemctl restart captain-hook
```

**Fix permanente:** garantir volume persistente do Redpanda no `docker-compose.yml`:
```yaml
redpanda:
  volumes:
    - redpanda-data:/var/lib/redpanda/data

volumes:
  redpanda-data:
```

### `500 Internal Server Error` no webhook

**Diagnóstico:**
```bash
sudo journalctl -u captain-hook --since "5 min ago" -p err
```

Causas comuns:
- HMAC inválido (`401`) → secret do `.env` diferente do configurado no GitHub App
- Kafka inacessível → conferir `KAFKA_BOOTSTRAP_SERVERS` aponta pra `localhost:9092` (ou hostname certo)
- Pydantic validation error → payload do webhook quebrou alguma assumption (raro)

## moby-dick

### `pull access denied for aspm-sonar-runner`

**Sintoma:**
```
pull access denied for aspm-sonar-runner, repository does not exist or may require 'docker login'
```

**Causa:** `docker_runner` tentava `client.images.pull()` antes de rodar, mas a imagem é local (sem registry).

**Fix (já mergeado):** o runner agora checa `client.images.get(image)` primeiro e só faz pull se ausente.

Se o erro voltar, rebuild a imagem:
```bash
docker build -t aspm-sonar-runner:latest deploy/sonar-runner/
```

### check_run fica `in_progress` pra sempre

**Causa:** moby-dick crashou DURANTE o `docker run`, antes de chegar no `update_check_run`.

**Diagnóstico:**
```bash
sudo journalctl -u moby-dick --since "10 min ago" | grep -i error
```

`docker_runner` tem try/except amplo — se chegou no `update_check_run` e crashou na chamada HTTP, dá pra ver no log.

**Mitigação:** restart do moby-dick + reprocessamento da mensagem (commit do offset não rolou).

## Scanner container

### `java.net.UnknownHostException: aspm-sonarqube`

**Sintoma:**
```
Caused by: java.net.UnknownHostException: aspm-sonarqube: Try again
```

**Causa:** container do scanner não está na rede `aspm-net` — DNS interno do Docker não resolve nomes de outros containers.

**Diagnóstico:**
```bash
docker ps -a --filter "name=moby-job-" --format "{{.Names}}\t{{.Networks}}" | head -3
```

Se mostrar `bridge` em vez de `aspm-net`, moby-dick está spawnando na rede errada.

**Fix:** garantir `DOCKER_NETWORK=aspm-net` no `.env` do moby-dick + restart.

### `Developer Edition or above is required`

**Sintoma:**
```
Validation of project failed:
  o To use the property "sonar.pullrequest.key" ... Developer Edition or above is required.
```

**Causa:** SonarQube **Community Build** não suporta `sonar.pullrequest.*` (feature paga).

**Fix:** entrypoint do scanner já remove flags PR por padrão. Se quiser ativar quando migrar pra Developer Edition, setar `SONAR_PR_MODE=enabled` no env do moby-dick.

### `Unsupported Node.JS version detected 18.20.1`

**Sintoma:** plugin JS/TS do Sonar reclama de Node 18.

**Causa:** versão do scanner-cli antiga não tinha Node 20+.

**Fix:** `Dockerfile` do sonar-runner usa `sonar-scanner-cli:11`. Se o erro persistir:
```bash
docker build --no-cache --pull -t aspm-sonar-runner:latest deploy/sonar-runner/
docker run --rm --entrypoint node aspm-sonar-runner:latest --version
# esperado: v20+
```

`--pull` força refresh da tag base no Docker Hub. `--no-cache` ignora layers cacheados.

### `apk: command not found` no build

**Sintoma:** ao buildar `aspm-sonar-runner`:
```
/bin/sh: line 1: apk: command not found
```

**Causa:** scanner-cli:11 mudou de Alpine pra Amazon Linux 2023 (`dnf`, sem `apk`).

**Fix:** Dockerfile atual detecta package manager dinamicamente. Se a base mudar de novo, o `if command -v X` pega.

### `Nenhum package manager encontrado`

**Causa:** scanner-cli atual já vem com git e bash. Não precisa instalar nada.

**Fix:** Dockerfile atual primeiro testa `if command -v git && command -v bash` e pula install se ambos existirem.

## SonarQube

### `Project not found` no scan

**Causa:** Sonar Community Build não auto-cria projeto na primeira execução (depende da config).

**Fix:** criar manualmente:

=== "Via UI"
    Projects → Create Project → Manually → Key = `<owner>_<repo>`

=== "Via API"
    ```bash
    curl -u admin:<senha> -X POST http://localhost:9000/api/projects/create \
      -d "name=clint-eastwood&project=OdinEye-FIAP_clint-eastwood"
    ```

A `project key` precisa bater **exatamente** com `SONAR_PROJECT_KEY` enviado pelo captain-hook (`<owner>_<repo>`).

### Sonar não sobe (`docker logs aspm-sonarqube`)

Erros comuns:

- **`max virtual memory areas vm.max_map_count [65530] is too low`**:
  ```bash
  sudo sysctl -w vm.max_map_count=262144
  echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
  ```

- **`Connection refused (sonar-db)`** — postgres não saudável ainda. `depends_on.condition: service_healthy` já cobre, mas pode demorar.

### Mudança no Sonar UI não persiste após restart

**Causa:** volume não montado. Conferir compose:
```yaml
sonarqube:
  volumes:
    - sonar-data:/opt/sonarqube/data
    - sonar-extensions:/opt/sonarqube/extensions
    - sonar-logs:/opt/sonarqube/logs
```

## Docker

### `permission denied` ao acessar `/var/run/docker.sock`

**Causa:** user do moby-dick não está no group `docker`.

**Fix:**
```bash
sudo usermod -aG docker $(whoami)
# logout/login pra aplicar
```

### Container fica zombie / `docker ps -a` cresce sem parar

**Causa:** `docker_runner` chama `container.remove(force=True)` no happy path mas pode pular em exceção.

**Fix manual:**
```bash
docker rm $(docker ps -a --filter "status=exited" -q)
```

**Fix permanente:** rodar containers com `--rm` ou usar `remove=True` no `containers.run`. Atualmente o runner usa `remove=False` pra coletar logs depois — pode mudar pra `True` se a coleta de logs vier antes.

## Sistema

### Network `aspm-net` não existe

```bash
docker network ls | grep aspm-net
```

Se vazio:
```bash
cd captain-hook
docker compose up -d
```

Compose define a network. Sem `compose up`, network não nasce.

### Tópicos Kafka sumiram após reinício

```bash
docker exec aspm-redpanda rpk topic list
# se github.events.raw / jobs.orchestration ausentes:
docker exec aspm-redpanda rpk topic create github.events.raw jobs.orchestration
```

Auto-create do Redpanda recria no próximo publish, mas vale conferir.

### Consumer group atrasado / lag alto

```bash
docker exec aspm-redpanda rpk group describe moby-dick
```

Se lag enorme = moby-dick caiu durante processamento e mensagens acumularam. Restart + processar.

Pular mensagens antigas (acelerar recovery):
```bash
docker exec aspm-redpanda rpk group seek moby-dick --to end
```

## Logs úteis

```bash
# captain-hook
sudo journalctl -u captain-hook -f

# moby-dick
sudo journalctl -u moby-dick -f

# Sonar
docker logs aspm-sonarqube -f

# Redpanda
docker logs aspm-redpanda -f

# Último scan
docker logs $(docker ps -a --filter "name=moby-job-" --latest -q) 2>&1 | tail -100

# Todos jobs do moby-dick últimas N horas
docker ps -a --filter "name=moby-job-" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
```

## Console Kafka (Redpanda Console)

http://localhost:8088 → ver tópicos, mensagens, consumer groups. Útil pra:

- Conferir se captain-hook publicou
- Ver payload do JobDescriptor
- Ver lag por consumer group

## Subida e VPS

### `network aspm-net declared as external, but could not be found`

**Causa:** o compose do pequod usa `aspm-net` como rede `external`; ela só é
criada pelo compose do captain-hook (ou à mão).

**Fix:** `docker network create aspm-net` ou rode `ops/scripts/infra-up.sh`, que
cria a rede antes de tudo.

### SonarQube reinicia em loop (`max virtual memory areas vm.max_map_count ... too low`)

**Causa:** o Elasticsearch embutido exige `vm.max_map_count >= 262144`.

**Fix:** `sudo sysctl -w vm.max_map_count=262144` e persistir em
`/etc/sysctl.d/99-sonarqube.conf` (o `infra-up.sh` faz isso).

### Serviço sobe mas ignora mensagens / `401` entre serviços

**Causa provável:** `KAFKA_MESSAGE_SECRET` ou algum par de `X-Service-Token`
diferente entre os serviços.

**Diagnóstico:** compare com a tabela de
[Configuração compartilhada](shared-config.md). Regenerar tudo de forma
consistente: `bootstrap-env.sh --force` (os segredos já gerados são reaproveitados
de `.aspm-secrets.env`).

### SonarQube / Postgres / Kafka acessíveis da internet mesmo com `ufw`

**Causa:** o Docker publica portas via iptables, ignorando o `ufw`.

**Fix:** subir a infra com os overrides de VPS (`infra-up.sh --vps`), que publicam
só em `127.0.0.1`. Confira com `ss -tlnp | grep -E '9000|9092|5433'`.

### Dashboard na VPS: erro de CORS ao chamar o tars-ai

**Causa:** a lista de origens do tars-ai está fixa em `localhost` no código.

**Fix:** servir o dashboard e as APIs pelo mesmo host (Caddyfile em `ops/caddy/`) e
buildar o dashboard com `build-heimdall.sh`, que aponta `VITE_*_API_URL` para
`https://heimdall.<BASE_DOMAIN>/api/...`. Lembre que as variáveis `VITE_*` são
embutidas **no build**: mudar o `.env` sem rebuildar não tem efeito.

### Webhook do GitHub retorna erro de TLS / timeout

**Diagnóstico:** `curl -v https://hook.<BASE_DOMAIN>/health` de fora da VPS;
`docker logs aspm-caddy`. As causas usuais são DNS ainda não propagado, portas
80/443 fechadas no firewall (inclusive no painel do provedor) ou `BASE_DOMAIN`
diferente do usado na URL do webhook.
