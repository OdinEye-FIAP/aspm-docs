# Decisões de arquitetura

Registro curto das decisões tomadas e os trade-offs por trás. Formato ADR-lite. Atualizar quando algo mudar.

---

## 1. SonarQube como scanner inicial

**Decisão:** integrar SonarQube como primeiro scanner SAST disparado em PRs.

**Por quê:**
- Plataforma madura, cobre múltiplas linguagens out-of-the-box
- Quality Gate dá veredito binário (pass/fail) — encaixa no `check_run` do GitHub
- UI pronta pra inspeção manual durante validação inicial

**Alternativas descartadas agora:** Semgrep / Trivy / CodeQL — serão considerados quando precisarmos de scanners adicionais ou substituir o Sonar. Stack permite trocar/somar sem refactor (image-per-scanner).

---

## 2. SonarQube + `sonar-db` dedicado (postgres)

**Decisão:** Sonar roda com seu próprio postgres dedicado.

**Por quê:**
- Sonar Community **exige** DB externo desde 2020 (H2 embedded removido)
- Não existe "Sonar stateless" — restrição da própria ferramenta
- DB dedicado mantém o Sonar como black-box: ninguém mais escreve nele

**Futuro:** `sonar.jdbc.url` é configurável. Quando aparecer 2º serviço com necessidade de DB, podemos migrar pra postgres **central** com schemas separados.

---

## 3. Compose Sonar dentro do captain-hook (provisório)

**Decisão:** `sonarqube` + `sonar-db` + rede `aspm-net` vivem no `captain-hook/docker-compose.yml` junto com Redpanda.

**Por quê:** conveniência operacional — já tinha compose pra Redpanda.

**Trade-off:** acoplamento operacional (derrubar captain-hook derruba Sonar/Redpanda).

**Futuro:** mover pra `infra/docker-compose.yml` na raiz quando houver mais componentes.

---

## 4. Storage central de findings (revisto: agora ativo via pequod)

**Decisão original:** não construir storage central de findings; usar só `check_run` do PR como feedback.

**Revisão (2026-06-23):** com pipeline E2E validado, criamos o [`pequod`](https://github.com/OdinEye-FIAP/pequod) — consumer de `findings.raw`, normaliza SARIF em `Finding v1`, dedupa por fingerprint SHA-256, expõe REST.

**Por que mudou:**
- Pipeline end-to-end já validado (check_run funcionando)
- Validar suposições de schema unificado antes do 2º scanner chegar é mais barato do que esperar
- Triagem manual no Sonar UI não escala — `PATCH /findings/{id}` permite workflow de aprovação fora do Sonar
- Base preparada pra camada de IA (pgvector, ai_triage) sem mexer no orquestrador

**Ainda adiados conscientemente:**
- DefectDojo ou agregador equivalente (pequod já cobre)
- Enriquecimento por IA (próxima fase)
- Correlação cross-scanner (precisa 2º scanner)
- UI Web de triagem (só REST por enquanto)

---

## 5. Image wrapper `aspm-sonar-runner` com clone-in-container

**Decisão:** scanner roda numa imagem custom (`sonarsource/sonar-scanner-cli:11` + entrypoint) que clona o repo dentro do próprio container.

**Por quê:**
- Mantém moby-dick agnóstico (não sabe SAST/git/Sonar)
- Sem volume mount entre host e container (portável, K8s-friendly)
- Imagem reutilizável independente do orquestrador

**Trade-off:** re-clone a cada scan (sem cache). Aceitável enquanto repos são pequenos.

---

## 6. `GIT_TOKEN` injetado em runtime pelo moby-dick

**Decisão:** captain-hook **não** coloca token GitHub no `JobDescriptor.env`. moby-dick minta installation token via GitHub App e injeta `GIT_TOKEN` no env do container antes do `docker run`.

**Por quê:**
- Token não trafega pelo Kafka
- captain-hook não precisa de credenciais da GitHub App
- Token TTL curto (1h), cacheado em memória — rotação automática

**Trade-off:** moby-dick concentra credenciais da App. Vault/secrets manager fica pra depois.

---

## 7. Modo de scan: análise principal (sem PR mode)

**Decisão (atualizada):** scanner roda **sem** flags `sonar.pullrequest.*`. Cada scan sobrescreve a análise principal do projeto Sonar.

**Por quê:**
- SonarQube **Community Build não suporta** `sonar.pullrequest.*` nem `sonar.branch.*` — features pagas (Developer Edition+)
- Tentativa inicial com PR decoration falhou na validação ("Developer Edition required")
- Quality Gate continua funcionando: avalia código analisado, exit code reflete

**Trade-off aceito:**
- ❌ Sem isolamento entre PRs no Sonar UI (último scan ganha)
- ❌ Sem decoração visual de PR
- ✅ check_run no PR ainda funciona (sinal binário)

**Opt-in para Developer Edition:** entrypoint do scanner aceita `SONAR_PR_MODE=enabled` pra reativar flags quando/se migrarem.

**Alternativas futuras:**
- SonarCloud free (grátis pra open-source, suporta PR mode)
- Sonar Developer Edition (~$160/dev/ano)
- Trocar pra Semgrep / CodeQL (modelos diferentes, sem essa limitação)

---

## 8. Quality Gate FAIL → `conclusion=failure`

**Decisão:** quando QG falha, `check_run.conclusion=failure` (não `neutral`).

**Por quê:**
- Permite branch protection bloquear merge
- Sinal binário claro pro desenvolvedor
- `qualitygate.wait=true` no scanner faz exit code refletir QG → mapeamento direto

---

## 9. Persistência do Redpanda

**Decisão (descoberta operacional):** Redpanda **precisa** de volume persistente (`redpanda-data`).

**Por quê:**
- Sem volume, `docker compose down`/`up` recria broker
- aiokafka producer mantém PID + sequence number em memória
- Broker novo emite IDs novos → producer envia sequence desalinhado → `OutOfOrderSequenceNumber`
- Captain-hook precisava de restart toda vez que Redpanda caía

**Trade-off:** volume persistente requer backup quando subir pra prod.

---

## 10. Documentação centralizada (este site)

**Decisão:** doc do projeto vive em repo dedicado `aspm-docs` com MkDocs Material, publicado em GitHub Pages.

**Por quê:**
- 3 audiências diferentes (dev, stakeholder, integrador) num lugar só
- Versionada com git
- Busca + dark mode + tabs gratuitos via Material
- Independente dos serviços (não acopla doc a release de código)

**Trade-off:** repo a mais pra cuidar. README curto por serviço aponta pra este site.

---

## 11. Extração de findings dentro da scanner image (target arquitetural)

**Decisão atual (transitória):** moby-dick chama `GET /api/issues/search` da Sonar API após `container.wait()` do scanner, converte resposta → SARIF, publica `findings.raw`. Vive em `moby-dick/adapter/sonar/issues_to_sarif.py`.

**Decisão revista (target):** a chamada Sonar API + conversão SARIF **migra para dentro do `sonar-runner` (image do scanner)**. Scanner image fica self-contained:

1. `git clone` do código
2. `sonar-scanner` faz upload
3. `curl` em `/api/issues/search` (mesma rede `aspm-net`)
4. Converte resposta para SARIF v2.1.0
5. Escreve `/tmp/scan.sarif.json`

moby-dick passa a usar `container.get_archive("/tmp/scan.sarif.json")` para extrair o arquivo, sem nunca falar com Sonar.

**Por quê mudar:**
- **Decisão §5 efetivamente preservada** — moby-dick volta a ser Docker-only. Não conhece Sonar API, formato, nem URL.
- **Decisão §12 (SARIF) reforçada na fronteira certa** — scanner image é dona do "como gerar SARIF". moby-dick e pequod só veem SARIF puro.
- **Onboarding de novo scanner = só build de image.** Semgrep tem `--sarif` nativo: `semgrep --sarif --output /tmp/scan.sarif.json`. Zero código novo em moby-dick/pequod.
- **Resolve o problema de DNS de graça** — container já está em `aspm-net`, então `aspm-sonarqube:9000` resolve nativamente. moby-dick não precisa expor Sonar em rota acessível pelo host.

**Trade-off aceito:**
- `entrypoint.sh` do `sonar-runner` cresce (~15 linhas: curl + jq/python p/ converter)
- moby-dick `docker_runner` precisa de método `extract_file(container, path)` usando `get_archive` + parsing de tar in-memory
- `SARIF` no Kafka pode ser grande (10-100 KB); particionar `findings.raw` por `repo_id` e considerar compactação no producer (`compression_type="gzip"`) quando virar problema

**Plano de migração:**
1. `moby-dick/deploy/sonar-runner/entrypoint.sh` — adiciona steps 3-5 acima
2. `moby-dick/diplomat/runner/docker_runner.py` — `RunResult.sarif: Optional[Dict]`; método auxiliar pra extrair arquivo
3. `moby-dick/controller/job_controller.py` — `_publish_findings` lê `result.sarif` (sem chamar Sonar API)
4. **Deletar** `moby-dick/adapter/sonar/issues_to_sarif.py`

**Quando revisitar:** se SARIF cru passar de ~500 KB consistentemente (re-pensar persistência de SARIF cru em S3/MinIO).

---

## 12. SARIF como formato comum de finding no pipeline

**Decisão:** todo finding que entra em `findings.raw` é normalizado em SARIF v2.1.0 (OASIS) antes de publicar no Kafka. Pequod consome SARIF e converte pra `Finding v1`.

**Por quê:**
- Padrão de mercado — GitHub Code Scanning, Microsoft, Semgrep, CodeQL, Trivy emitem SARIF nativo.
- Scanner-agnostic — adicionar 2º/3º scanner (Semgrep, Trivy) não muda contrato de `findings.raw` nem código do pequod.
- Spec estável, JSON, bem documentado.

**Trade-off aceito:**
- SonarQube **não emite SARIF nativo** — precisa adapter (§11) que converte `/api/issues/search` → shape SARIF.

**Alternativas descartadas:**
- Shape próprio "finding_raw_v1" — perde interoperabilidade com tooling existente.
- Passar resposta Sonar crua adiante — acopla pequod ao formato Sonar; quebra com Semgrep depois.

---

## 13. `SONAR_PROJECT_KEY` derivado de `github.repository.id`

**Decisão:** captain-hook usa `f"gh_{repository.id}"` como `SONAR_PROJECT_KEY` (inteiro estável vindo do payload do webhook), não mais `f"{owner}_{repo}"`.

**Por quê:**
- `repository.id` é imutável — sobrevive a rename, transfer entre orgs.
- Sanitização garantida — `gh_<int>` sempre bate na regex `[a-zA-Z0-9:\-_.]+` que Sonar exige.
- Pequod ganha `repo_id` como chave estável de dedup.

**Trade-off aceito:**
- `gh_847291` não é legível no Sonar UI. Mitigação: `sonar.projectName="OdinEye-FIAP/clint-eastwood"` (label humano, key estável).
- Migração de repos já onboardados: precisa renomear projeto no Sonar via `/api/projects/update_key`.

---

## 14. Pequod como source-of-truth de findings (substitui sonar-db a longo prazo)

**Intenção (não migração ainda):** o `pequod` é desenhado pra eventualmente **substituir o papel do `sonar-db` como repositório autoritativo de findings da organização**. UI de triagem, integrações de IA, métricas e workflows consumirão o pequod, não o Sonar UI.

**Importante — o que isso NÃO significa:**
- ❌ Não vamos remover o `sonar-db`. SonarQube Community Build exige postgres externo (§2). Sem ele o scanner não roda.
- ❌ Não estamos competindo com o Sonar UI pra inspeção pontual de issues. Quem quiser olhar issue isolada pode continuar usando.

**O que significa:**
- ✅ O `sonar-db` vira **scratch interno** do scanner — espaço de trabalho transitório, não fonte de consulta organizacional.
- ✅ `pequod` é a base canônica: dedup por `(fingerprint, repo_id)`, histórico de status (open/triaged/false_positive/resolved), retenção controlada por nós.
- ✅ Toda integração nova (UI, ai-triage, notifier, métricas) consulta pequod. Sonar UI fica para troubleshooting do scanner.

**Por quê:**
- `sonar-db` é schema fechado do Sonar — não podemos adicionar coluna `status`, `triage_notes`, `enrichment_ai_*` sem quebrar update do Sonar.
- Multi-scanner exige store unificado (§12 SARIF). `sonar-db` por definição só sabe Sonar.
- Backup, retenção, compliance: querer manter findings por 2 anos vs configuração padrão do Sonar é luta perdida — controlar `pequod` é trivial.
- Triagem manual via `PATCH /findings/{id}` precisa de schema que aceite estados além dos que o Sonar suporta nativamente.

**Trade-off aceito:**
- Duplicação temporária de findings (vivem no `sonar-db` interno do Sonar **e** no `pequod`). Storage barato, OK no MVP.
- Sonar UI mostra dados que podem divergir do pequod após triagem manual (ex: dev marca como `false_positive` no pequod, Sonar continua acusando). Documentar bem: **fonte de verdade é o pequod**, Sonar UI é para inspecionar o scan.

**Caminhos futuros considerados:**
- Trocar Sonar por scanner stateless (Semgrep, Trivy) que não exige DB próprio → `sonar-db` desaparece.
- Manter Sonar como engine de análise mas reduzir retenção do `sonar-db` ao mínimo (último scan por projeto).
- API gateway sobre pequod servir como "Sonar UI substituto" pra consultas organizacionais.

**Quando revisitar:** ao bootstrar UI de triagem OU ao adicionar 2º scanner (revalidar a tese de pequod-as-SoT antes de assumi-la).

---

## Princípios em jogo

- **Reuso de schema sobre reuso de código:** serviços falam por contratos versionados (`wire/schemas/`).
- **Stateless onde possível, stateful onde necessário:** scanners stateless; plataformas com UI/histórico ficam stateful em DB próprio.
- **Decisões reversíveis primeiro:** evitamos compromissos caros até o uso real exigir.
- **Token nunca atravessa fronteira de processo desnecessária.**

---

## Open questions

- Onde mora a configuração por repo (`.aspm.yml`?) quando precisarmos rotear scanners diferentes
- Estratégia de retenção quando agregador entrar
- Métricas / observability formal (Prometheus? OTEL?)
- Plataforma definitiva pra prod (continuar VPS? K8s? Railway?)

Atualizar este documento quando uma dessas virar decisão.
