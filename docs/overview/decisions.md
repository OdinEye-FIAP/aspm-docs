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

## 4. Ignorar reports/storage central por enquanto

**Decisão:** não construir storage central de findings. Sonar guarda no `sonar-db` dele, ficamos satisfeitos com o `check_run` no PR.

**Por quê:**
- Valida pipeline end-to-end com custo mínimo
- Evita decisões prematuras sobre schema, dedup, banco, IA
- Quando aparecer 2º scanner, decisões serão informadas por uso real

**Adiados conscientemente:**
- `findings-ingestor` / schema `finding_v1`
- DefectDojo ou agregador equivalente
- Enriquecimento por IA
- Correlação cross-scanner

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
