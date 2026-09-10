# O que é o ASPM-AI

## ASPM em uma frase

> **Application Security Posture Management** = unificar a visão de segurança de aplicações: descobrir, correlacionar, priorizar e remediar vulnerabilidades através de todo o SDLC.

## O problema

Times de engenharia hoje têm uma sopa de scanners:

- SAST (Sonar, Semgrep, CodeQL) para defeitos de código
- SCA (Snyk, Trivy, Grype) para vulnerabilidades em dependências
- DAST (ZAP, Burp) para falhas em runtime
- Secret scanners (Gitleaks, TruffleHog)
- Container scanners, IaC scanners, etc

Cada um tem sua UI, seu dashboard, seu schema. O resultado:

- **Findings duplicados** entre ferramentas que olham coisas parecidas
- **Falsos positivos** não triagem nunca somem
- **Sem priorização cross-fonte** — uma CVE crítica numa lib sem reachability fica do lado de um code smell trivial
- **Sem contexto de negócio** — "qual serviço é PCI scope?" → ninguém sabe
- **Triagem manual** virou trabalho fulltime

Plataformas ASPM resolvem isso: 1 schema unificado, 1 lugar pra triagem, 1 fonte pro time de segurança e pro time de produto.

## O que IA adiciona (e o que já está em produção)

- ✅ **Triagem automática** — `tars-ai` classifica findings/clusters com recomendação, prioridade e confiança (Gemini `gemini-2.5-flash`, com Groq/HuggingFace como alternativa via factory)
- ✅ **Correlação semântica** — clustering semântico via IA decide `merge`/`keep`/`split` entre candidatos correlacionados, gravado como risco consolidado no pequod
- ⏳ **Reachability**: ainda não existe — agente que leria o código pra decidir se a vuln é alcançável
- ⏳ **Fix suggestions**: ainda não existe — PR comment com diff sugerido
- ⏳ **Risk scoring** combinando severity + reachability + criticidade de negócio: parcial — hoje prioridade vem da triagem de IA, sem reachability nem criticidade de negócio no cálculo

## O que **este** projeto é

O ASPM-AI da OdinEye-FIAP construiu essa plataforma do zero, com foco em:

1. **Pipeline event-driven** (Kafka como espinha dorsal do ingest/scan) + **quality gate síncrono** onde latência importa (moby-dick ↔ pequod)
2. **Modularidade extrema** — scanners stateless, schemas versionados, serviços trocáveis. Confirmado na prática: 3 scanners novos (semgrep/trivy/zap) chegaram sem tocar em moby-dick nem pequod
3. **Containers isolados por scan** — cada finding nasce de um container efêmero, um por scanner
4. **Stack moderna** — Python (FastAPI), Pydantic, aiokafka, Docker SDK, React/Vite no frontend
5. **PR feedback + Security Baseline + dashboard de governança**, as três pernas já existem e estão em produção de ponta a ponta desde 31/ago/2026 — ver [Decisão §15](decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10)

## O que **não** é

- ❌ Não é apenas um wrapper de SonarQube — hoje são 4 scanners (Sonar, Semgrep, Trivy, ZAP)
- ❌ Não é um agregador passivo de relatórios — tem governança de risco (security gate, risk exceptions) e triagem ativa por IA
- ❌ Não é "rode SAST no CI e tá bom"
- ❌ Não é pra ser bonito antes de ser correto

## Estado atual (atualizado 2026-09-10)

| Fase | Status |
|---|---|
| Fase 0 — Pipeline GitHub → Kafka → Sonar | ✅ concluída |
| Fase 1 — Schema unificado + storage central de findings | ✅ concluída (pequod) |
| Fase 2 — Multi-scanner (Semgrep/Trivy/ZAP) | ✅ concluída |
| Fase 2.5 — Quality Gate com Security Baseline (`scope=pr`/`branch`) | ✅ concluída — ponta a ponta em `main` nos três repositórios desde 31/ago/2026 |
| Fase 3 — Triagem automática por IA (LLM) | ✅ concluída (tars-ai + Gemini) |
| Fase 3.5 — Clustering semântico + risco consolidado | ✅ concluída |
| Fase 3.75 — Dashboard de governança (heimdall-dashboard) | ✅ concluída |
| Fase 4 — Reachability analysis | ⏳ não iniciada |
| Fase 4 — Fix suggestions automáticos | ⏳ não iniciada |
| Fase 5 — Risk scoring com criticidade de negócio + SLA | ⏳ não iniciada |

!!! note "Sobre a Fase 2.5"
    Esta página teve, por algumas horas nesta mesma revisão (2026-09-10), uma versão que rebaixava a Fase 2.5 para "parcial", concluindo que Security Baseline não estava em `main`. Essa conclusão veio de uma verificação com refs git locais desatualizadas (sem acesso de rede pra `git fetch`) — checando direto pela API do GitHub, a feature está em `main` nos três repositórios desde 31/ago/2026. Ver [Decisão §15](decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--ponta-a-ponta-em-main-reconfirmado-2026-09-10) para o histórico completo.

## Princípios técnicos

- **Stateless onde possível, stateful onde necessário.** Scanners stateless; plataformas com histórico (Sonar, pequod) ficam stateful em DB próprio.
- **Schemas versionados são o contrato.** Serviços não se conhecem por código, só por mensagens Kafka tipadas ou REST tipado.
- **Decisões reversíveis primeiro.** Evitamos compromissos caros até o uso real exigir.
- **Token nunca atravessa fronteira de processo desnecessária.** `GIT_TOKEN` só existe no moby-dick e no container que precisa.
- **Cada componente substituível.** Trocar Python por Go num serviço hot path não deve quebrar o resto.

Continua em [Arquitetura](architecture.md).
