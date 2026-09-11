# Proposta: registro de repositório via REST + Security Baseline em `ping`/`installation`

> **Status:** proposta, não implementada. Este documento é a especificação
> de implementação — foi escrito para que uma sessão/chat diferente do que
> o discutiu possa implementar sem precisar do histórico da discussão.
> Discussão original: `decisions.md` → seção "Open questions", item
> "Confiabilidade do producer em `installation`/`installation_repositories`"
> (levantado 2026-09-10/11).

## Contexto (estado atual, confirmado no código em 2026-09-11)

Hoje `ping` e `installation`/`installation_repositories` (captain-hook)
fazem **só uma coisa**: registrar/desregistrar o repositório no inventário
do pequod, via Kafka (`repository.registered.v1`/`repository.unregistered.v1`,
produtor captain-hook, consumidor pequod — confirmado como único par
producer/consumer desses tópicos, sem terceiros dependendo deles).

Isso tem três lacunas: confiabilidade, escopo e consistência do padrão de
resposta ao GitHub.

1. **Confiabilidade:** `ping` propaga falha de publish Kafka pra resposta
   HTTP do webhook (GitHub reentrega). Mas `installation`/`installation_repositories`
   roda em `background_tasks` — depois do `200 OK` já devolvido ao GitHub —
   e `_publish_registrations_sequentially`/`_publish_unregistrations_sequentially`
   (`captain-hook/controller/installation_controller.py`) capturam a exceção
   por repositório, logam e seguem. Se o Kafka cair nesse momento, o lote
   inteiro nunca é publicado: sem DLQ possível (mensagem nunca saiu do
   captain-hook), sem retry, e o GitHub não reentrega (do lado dele, o
   webhook já teve sucesso).
2. **Escopo:** quando a App é instalada num repo/org, ou quando `ping`
   dispara, hoje **nada roda scanner nenhum** no `main` do repositório —
   só o registro no inventário (+ auto-scaffold, só no `ping` individual).
   O primeiro Security Baseline (scope=`branch`) só acontece no próximo
   `push` na default branch, o que pode nunca acontecer logo após o
   onboarding.
3. **Consistência de resposta ao GitHub (levantado 2026-09-11):** `installation`
   já responde `200 OK` **antes** de processar (tudo em `background_tasks`);
   `ping` responde `200 OK` só **depois** de processar tudo de forma síncrona
   no request handler (só o auto-scaffold roda em background hoje). Isso já
   era uma inconsistência menor, mas com a Fase A/B abaixo o caminho síncrono
   do `ping` cresce (REST pro pequod + `GET` no GitHub pro HEAD sha + 2
   publishes Kafka) antes de responder — risco real de aproximar do timeout
   de webhook do GitHub (~10s) num pequod ou GitHub API mais lentos.

## Objetivo desta mudança

- **Fase A:** eliminar a Kafka do caminho captain-hook→pequod pra
  registro/desregistro de repositório, substituindo por REST síncrono
  (mesmo padrão do Quality Gate — ver `decisions.md` §16). Resolve a
  lacuna de confiabilidade (1).
- **Fase B:** captain-hook passa a disparar um Security Baseline
  (scope=`branch`) imediatamente no `ping` e no `installation`/
  `installation_repositories` (ações de registro), reaproveitando 100% da
  máquina que já existe pro `push` (`quality-gate.workflow.started.v1` +
  `jobs.orchestration`, consumida pelo moby-dick exatamente como hoje).
  Resolve a lacuna de escopo (2).
- **Fase A/B, ajuste de consistência:** `ping` passa a responder `200 OK`
  **antes** de processar, igual `installation` — todo o trabalho (REST
  registro, GET do HEAD sha, publishes Kafka, scaffold) roda em
  `background_tasks`. Resolve a lacuna (3).

## Não-objetivo

- Não muda nada em `pull_request`/`push` (scope=`pr` continua igual).
- Não muda o moby-dick. Ele continua scanner-agnóstico e não sabe (nem
  precisa saber) se um `jobs.orchestration` veio de um `push` real ou de
  um `ping`/`installation` — pra ele é o mesmo `JobDescriptor` com
  `scope=branch`.
- Não implementa "listar PRs" nem o redesenho do `/live-info` — são ideias
  registradas separadamente em `decisions.md` (Open questions).
- Não implementa tópicos Kafka por scanner — ideia registrada
  separadamente em `decisions.md` (Open questions), sem decisão tomada.

## Decisões já fechadas (não reabrir sem motivo novo)

| Decisão | Escolha | Por quê |
|---|---|---|
| Estratégia de corte | **Cutover direto** | Volume baixo, sem terceiros consumindo os tópicos hoje. Sem dual-write/feature-flag temporário. |
| Auth do novo endpoint no pequod | **Dependency genérica de service token** | Substitui o padrão duplicado (`require_moby_dick_service_token`, e equivalente do tars-ai) por uma única `require_service_token(*allowed)` reutilizável — inclusive pro futuro BFF (ver `decisions.md`, item "BFF"). |
| `ping`/`installation` ainda precisam de Kafka? | **Sim, pra moby-dick** (Fase B) | Só a comunicação captain-hook↔pequod perde Kafka. Captain-hook↔moby-dick continua Kafka — moby-dick nunca consumiu os tópicos de registro, então não há nada a preservar aí; o que muda é que captain-hook passa a *também* publicar `jobs.orchestration`/`workflow.started` a partir desses dois eventos, não só do `push`. |
| Registro deveria passar por um tópico Kafka consumido pelo moby-dick, em vez de REST direto ao pequod? | **Não** | Discutido explicitamente (2026-09-11). Trocar o destino do publish de "pequod" pra "moby-dick" **não resolve** a lacuna de confiabilidade (1) — o produtor (`captain-hook`) continua sendo o mesmo `publisher.publish()` dentro do mesmo loop de `background_tasks` que hoje engole falha silenciosamente; o problema nunca foi o consumidor. REST com retry embutido no `PequodClient` resolve porque tenta de novo *antes* de desistir, sem depender do broker estar de pé. Além disso, pequod já é chamado diretamente por 3 serviços hoje (moby-dick `/evaluate`, tars-ai `/integrations/tars/*`, heimdall-dashboard `/api/v1/*`), captain-hook virar o 4º não quebra padrão nenhum, é exatamente o cenário que motivou a auth genérica (linha acima). O que o rascunho de "tópico + moby-dick consome N repos" descreve **já existe** para o disparo de scan: é o `jobs.orchestration` da Fase B, que já é consumido por um único `JobConsumer` no moby-dick, unificado entre push/PR/ping/install, sem necessidade de tópico novo. |
| Sonar (e demais scanners) reutilizável entre push/PR/ping/install | **Já é hoje** | `build_job`/`build_baseline_job` de cada scanner (`adapter/wire_out/scanners/*.py`) já são agnósticos à origem do trigger — não precisam mudar. |
| `ping` deve responder o GitHub antes ou depois de processar (registro + baseline)? | **Antes — `background_tasks`, igual `installation`** (levantado 2026-09-11) | Fase A/B tornam o caminho síncrono do `ping` mais pesado (1 REST pro pequod + 1 GET no GitHub + 2 publishes Kafka antes do `200`), o que aproxima do timeout de webhook do GitHub. `installation` já usa esse padrão hoje. Trade-off aceito: falha deixa de propagar pro GitHub (sem reentrega automática) — mitigado pelo retry já embutido no `PequodClient` (Fase A) e pelo log de erro; é o mesmo trade-off que `installation` já opera com hoje, só que agora com retry, que não existia antes. |

## Fluxo proposto

Em ambos os diagramas abaixo, toda chamada captain-hook→pequod
(`POST /internal/repositories/register`/`/unregister`) é **REST
síncrono, autenticado via header `X-Service-Token`** — mecanismo único,
não repetido seta a seta.

### `ping`

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant CH as captain-hook
    participant PQ as pequod
    participant K as Kafka
    participant MD as moby-dick

    GH->>CH: POST /webhook (ping)
    CH->>CH: process_ping_event (valida payload)
    CH-->>GH: 200 OK imediato
    Note over CH: processamento em background_tasks (agora igual installation)

    alt payload utilizável (repo individual)
        CH->>PQ: POST /internal/repositories/register
        PQ-->>CH: 200 (upsert + audit log)
        CH->>GH: GET /repos/{owner}/{repo}/git/ref/heads/{default_branch}
        GH-->>CH: head_sha atual
        CH->>K: publish quality-gate.workflow.started.v1 (scope=branch)
        CH->>K: publish jobs.orchestration (1 por scanner habilitado, baseline)
        K->>MD: consome jobs.orchestration (idêntico ao fluxo de push hoje)
        CH->>CH: auto-scaffold (inalterado, já era background)
    else payload incompleto
        Note over CH: nada publicado/chamado
    end
```

### `installation` / `installation_repositories`

```mermaid
sequenceDiagram
    participant GH as GitHub
    participant CH as captain-hook
    participant PQ as pequod
    participant K as Kafka
    participant MD as moby-dick

    GH->>CH: POST /webhook (installation | installation_repositories)
    CH-->>GH: 200 OK imediato
    Note over CH: processamento em background_tasks (como hoje)

    loop por repositório (concorrência: ver "Pontos abertos")
        alt action = created | added
            CH->>PQ: POST /internal/repositories/register
            CH->>GH: GET default_branch atual + HEAD sha
            CH->>K: publish workflow.started + jobs.orchestration (baseline, scope=branch)
        else action = deleted | removed
            CH->>PQ: POST /internal/repositories/unregister
        end
    end
    K->>MD: consome jobs.orchestration (idêntico ao fluxo de push hoje)
```

Note que a chamada REST (registro) e a publicação Kafka (baseline) são
**independentes** — não há ordem obrigatória entre elas, podem correr em
paralelo. A única dependência real de ordem é a de sempre: publicar
`quality-gate.workflow.started.v1` antes (ou junto) dos `jobs.orchestration`
do mesmo `workflow_id`, exatamente como `push_controller.py` já faz hoje —
e mesmo essa não é rígida, porque `pequod/controller/quality_gate_controller.py::process_quality_gate_scanner_completed`
já tolera um `scanner.completed` chegando antes do `workflow.started`
(cria um run "provisório").

Com o ajuste de consistência, `ping` e `installation` agora seguem o
**mesmo padrão de resposta**: validação mínima de payload no request
handler (síncrono, rápido) → `200 OK` imediato → todo o trabalho de
rede (REST pequod, GET GitHub, publish Kafka) em `background_tasks`.

## Changeset — Fase A (registro via REST)

### pequod

| Arquivo | Mudança |
|---|---|
| `diplomat/http_in/service_auth.py` (novo) | `require_service_token(*allowed: str)` — dependency factory genérica. Lê os tokens conhecidos (`moby_dick_service_token`, `tars_service_token`, `captain_hook_service_token`) das settings, valida `X-Service-Token` contra os serviços listados em `allowed` com `hmac.compare_digest`. Se nenhum token esperado estiver configurado (dev local), não exige auth — mesmo comportamento do `require_moby_dick_service_token` atual. |
| `diplomat/http_in/moby_dick_auth.py` | Removido — callers passam a usar `require_service_token("moby-dick")`. |
| (arquivo equivalente do tars-ai, se existir um dedicado) | Idem — migra pra `require_service_token("tars-ai")`. |
| `diplomat/http_in/repository_registration_sync_handler.py` (novo) | Dois handlers finos: `handle_register_repository(payload: dict) -> dict` e `handle_unregister_repository(payload: dict) -> dict`. Fazem `RepositoryRegisteredEvent.model_validate(payload)` / `RepositoryUnregisteredEvent.model_validate(payload)` e chamam direto `process_repository_registered`/`process_repository_unregistered` (`controller/repository_registration_controller.py` e `repository_unregistration_controller.py` — **zero mudança** nesses dois controllers, upsert idempotente + audit log na mesma transação continuam iguais). Retornam `{"status": "ok", "application_id": ...}`. |
| `diplomat/http_in/captain_hook_integration_router.py` (novo) | `APIRouter(prefix="/internal/repositories", dependencies=[Depends(require_service_token("captain-hook"))])`; rotas `POST /register` → `handle_register_repository`, `POST /unregister` → `handle_unregister_repository`. |
| `config/settings.py` | + `captain_hook_service_token: str = ""`. Remove `topic_repository_registered`, `topic_repository_unregistered`, `topic_repository_registration_dlq`, `topic_repository_unregistration_dlq`, `kafka_repository_registration_consumer_group`, `kafka_repository_unregistration_consumer_group`. |
| `diplomat/http_server.py` | Registra `captain_hook_integration_router`. Remove `RepositoryRegistrationConsumer`/`RepositoryUnregistrationConsumer` do `lifespan` (imports, criação, `start()`/`stop()`, `app.state.*`). |
| `diplomat/messaging/repository_registration_consumer.py` | Apagar. |
| `diplomat/messaging/repository_unregistration_consumer.py` | Apagar. |
| `controller/repository_registration_controller.py` | Sem mudança de lógica — só muda quem chama (`process_repository_registered` passa a ser invocado pelo handler HTTP, não pelo consumer). |
| `controller/repository_unregistration_controller.py` | Idem. |
| `diplomat/http_in/quality_gates_router.py` / `tars_integration_router.py` | Trocar `Depends(require_moby_dick_service_token)`/equivalente por `Depends(require_service_token("moby-dick"))` / `Depends(require_service_token("tars-ai"))`. |

### captain-hook

| Arquivo | Mudança |
|---|---|
| `diplomat/http_out/pequod_client.py` (novo) | Espelha `moby-dick/diplomat/http_out/pequod_client.py`: classe `PequodClient` com `register_repository(event: RepositoryRegisteredEvent) -> None` e `unregister_repository(event: RepositoryUnregisteredEvent) -> None`. `POST {pequod_base_url}/internal/repositories/register`/`/unregister`, header `X-Service-Token: {pequod_service_token}`, retry exponencial em 429/5xx/erro de conexão (`pequod_api_max_attempts`/`pequod_api_retry_base_seconds`), timeout `pequod_api_timeout_seconds`. Levanta erro (não engole) em falha definitiva — quem chama decide o que fazer. |
| `config/settings.py` | + `pequod_base_url`, `pequod_service_token`, `pequod_api_timeout_seconds: float = 10.0`, `pequod_api_max_attempts: int = 4`, `pequod_api_retry_base_seconds: float = 0.5`. Remove `topic_repository_registered`, `topic_repository_unregistered`. |
| `controller/ping_controller.py` | Reestruturado pra seguir o mesmo padrão de `installation_controller.py`: o handler HTTP faz só a validação mínima do payload (`process_ping_event`), agenda uma única função em `background_tasks` (ex. `_process_ping_registration`) e retorna `200 OK` imediatamente. Dentro do background task: `await get_pequod_client().register_repository(registration_event)` (troca do antigo `publisher.publish(topic=settings.topic_repository_registered, ...)`), seguido do fluxo de Fase B. Falha agora **não propaga mais pra resposta HTTP** — só loga (`logger.exception`), mesma filosofia que `installation` já usa. Mitigado pelo retry do `PequodClient`. |
| `controller/installation_controller.py` | `_publish_registrations_sequentially`/`_publish_unregistrations_sequentially` trocam o `publisher.publish(...)` por `get_pequod_client().register_repository(event)`/`.unregister_repository(event)`. Mantém o try/except por repositório (mesma filosofia: 1 falha não aborta o lote) — só que agora a falha só ocorre depois de esgotado o retry do `PequodClient`, não na primeira tentativa. |
| `diplomat/messaging/kafka_producer.py` | Sem mudança — continua em uso por `jobs.orchestration`/`quality-gate.workflow.started.v1`. |

## Changeset — Fase B (Security Baseline em ping/installation)

### captain-hook

| Arquivo | Mudança |
|---|---|
| `diplomat/http_out/github_read_client.py` (novo, ou método novo em `github_write_client.py` se fizer mais sentido reaproveitar o cliente existente) | Método pra buscar o HEAD sha atual de uma branch: `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` (usa o mesmo installation token que `GitHubWriteClient` já minta pra `enrich_registrations_with_repository_details`/scaffold). |
| `adapter/wire_in/install_baseline_adapter.py` (novo) | `to_baseline_context_from_registration(event: RepositoryRegisteredEvent, head_sha: str) -> BaselineContext` — monta o mesmo `BaselineContext` que `push_adapter.to_baseline_context` produz a partir de um push, só que a partir dos dados já disponíveis no evento de registro + do `head_sha` buscado via API. |
| `controller/ping_controller.py` | Dentro do mesmo background task do registro (ver Fase A acima): depois do `register_repository`, se `registration_event.default_branch` estiver preenchido, busca o HEAD sha, monta `BaselineContext`, chama a mesma `_build_baseline_jobs`/`to_baseline_workflow_started_event` que `push_controller.py` usa (extrair essas duas funções pra um módulo compartilhado, ex. `controller/baseline_jobs.py`, pra não duplicar código entre `push_controller` e `ping_controller`/`installation_controller`), publica `workflow.started` + `jobs.orchestration`. |
| `controller/installation_controller.py` | Idem, dentro do loop por repositório, só pra `action=created`/`added` (não pra `deleted`/`removed`, óbvio). |
| `controller/push_controller.py` | Refatorado só pra importar `_build_baseline_jobs` do módulo compartilhado em vez de definir localmente — comportamento idêntico. |

**Reaproveitamento confirmado:** nenhuma mudança em `adapter/wire_out/scanners/*.py` (cada builder já tem `build_baseline_job` agnóstico à origem), nenhuma mudança em moby-dick, nenhuma mudança em pequod além da Fase A.

## Testes

- pequod: unit test de `require_service_token` (aceita serviço certo, rejeita token errado, rejeita serviço não-listado em `allowed`, modo dev sem token configurado). Integration test do router novo: registro cria `application`; registro duplicado (mesmo `repository_id`) faz upsert, não duplica; unregister faz soft delete; 401 sem token.
- captain-hook: unit test de `PequodClient` (retry em 5xx, propaga em 404, propaga depois de esgotar tentativas). Unit test de `ping_controller`/`installation_controller` com `PequodClient` mockado — cobre o caso de falha isolada não abortar o lote em `installation`, **e** o caso de `ping` responder `200` mesmo quando o background task falha (comportamento novo, precisa de teste dedicado). Fase B: teste de que `BaselineContext` sintético (via ping/install) gera o mesmo formato de `JobDescriptor` que o caminho de `push` gera pro mesmo repo/branch (só o `trigger`/`delivery_id` diferem).
- Manual/staging: instalar a App num repo de teste (`aspm-vuln-lab` ou `clint-eastwood`) e confirmar: aplicação aparece no pequod imediatamente (sem esperar push), Security Baseline dispara e aparece Issue agregada no repo, `ping` de reconfiguração de webhook não duplica nada, `ping` responde `200` rapidamente mesmo com pequod/GitHub API lentos (validar com um delay artificial em staging).

## Ordem de deploy (dentro do cutover direto)

Mesmo sem dual-write, a ordem de deploy entre os dois serviços importa:

1. **pequod** primeiro: adiciona o endpoint novo, mas **mantém** os consumers Kafka de registro rodando nesse deploy (aditivo, não quebra nada ainda).
2. **captain-hook**: troca publish por REST **e** move `ping` pra `background_tasks`. A partir daqui, os tópicos `repository.registered.v1`/`.unregistered.v1` deixam de receber mensagens.
3. **pequod**, follow-up: remove os consumers Kafka + tópicos/DLQs das settings (agora sim, seguro — confirmado que não há mais producer).

Fase B pode ir no mesmo deploy do captain-hook do passo 2, ou em um deploy seguinte — não tem dependência com a Fase A além de reaproveitar o `PequodClient`/registro já migrado. O ajuste de `ping` pra `background_tasks` deve ir junto do passo 2 (é mudança no mesmo arquivo/handler).

## Pontos abertos (decidir antes ou durante a implementação)

1. **Concorrência do loop de `installation`:** hoje é sequencial (repo por repo). Trocar por HTTP síncrono deixa isso mais lento pra orgs com muitos repositórios — principalmente com a Fase B somada (cada repo agora também dispara N jobs de scanner). Manter sequencial (simples) ou paralelizar com limite de concorrência (ex. `INSTALLATION_MAX_CONCURRENCY`, no espírito do `SCANNER_MAX_CONCURRENCY` do moby-dick)? **Ainda sem decisão.**
2. **Escopo da Fase B:** todo repositório instalado recebe Security Baseline imediato, sem exceção? Numa instalação em massa numa org grande, isso pode disparar dezenas/centenas de workflows de scan de uma vez (o Kafka + `SCANNER_MAX_CONCURRENCY` do moby-dick absorve isso com backpressure natural, mas vale confirmar se é o comportamento desejado ou se deveria ter algum controle — ex. feature flag `ENABLE_BASELINE_ON_INSTALL`, no estilo do `ENABLE_REPO_SCAFFOLD_PR`). **Ainda sem decisão — recomendo um kill switch dedicado, dado o precedente do próprio `ENABLE_REPO_SCAFFOLD_PR`.**
3. **Nomes finais de settings/endpoints** listados acima são propostos, não fechados — ajustar durante a implementação se algo já existir com nome diferente.

## Documentação a atualizar depois da implementação

- `docs/captain-hook.md`: os dois diagramas sequenciais de `ping`/`installation` (adicionados no PR #19) passam a refletir REST + baseline + resposta imediata via `background_tasks`, não mais só Kafka de registro.
- `docs/reference/kafka-topics.md`: remove `repository.registered.v1`/`.unregistered.v1` e as DLQs correspondentes.
- `docs/reference/http-endpoints.md`: adiciona `/internal/repositories/register`/`unregister` no pequod; atualiza a lista de "Side effects" do `POST /webhook` do captain-hook; documenta que `ping` agora também responde antes de processar (como `installation`).
    - **Achado à parte, não relacionado a esta proposta:** esse mesmo arquivo hoje lista `github.events.raw` como side-effect "sempre" publicado pelo `/webhook` — esse tópico não existe no código (já corrigido em `architecture.md`/`kafka-topics.md`/`decisions.md`, mas este arquivo específico ficou de fora daquela correção). Vale um fix separado, pequeno, independente desta proposta.
- `docs/overview/decisions.md`: nova decisão numerada (ex. §19) documentando a mudança feita; mover o item de "Open questions" pra "Resolvido".
- `docs/overview/repos.md`: responsabilidades do captain-hook mencionam "publicar registro/baixa via Kafka" — atualizar pra REST.
