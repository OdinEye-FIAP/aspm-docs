# ASPM-AI

Plataforma **Application Security Posture Management** com IA em construção pela OdinEye-FIAP.

## O que entrega

Quando um PR é aberto/atualizado num repo onboardado, a plataforma:

1. Recebe o webhook do GitHub
2. Despacha um scanner em container isolado
3. Roda análise (atualmente SonarQube; mais scanners e enriquecimento por IA virão)
4. Extrai findings, normaliza em SARIF v2.1.0 e persiste no `pequod`
5. Reporta o resultado como **check_run** no PR
6. Bloqueia ou libera merge conforme Quality Gate

```mermaid
flowchart LR
    Dev[Desenvolvedor]
    GH[GitHub PR]
    CH[captain-hook]
    K[(Kafka)]
    MD[moby-dick<br/>orquestra Docker]
    SR[scanner container<br/>self-contained:<br/>scan + emite SARIF]
    SQ[SonarQube]
    PQ[pequod<br/>storage canônico]
    PG[(postgres)]

    Dev -->|push| GH
    GH -->|webhook| CH
    CH -->|jobs.orchestration| K
    K -->|consume| MD
    MD -->|spawn| SR
    SR -->|sonar-scanner| SQ
    SQ -->|QG + issues| SR
    SR -->|SARIF em /tmp/scan.sarif.json| MD
    MD -->|findings.raw SARIF| K
    K -->|consume| PQ
    PQ -->|upsert| PG
    MD -->|check_run| GH
    GH -->|status| Dev
```

## Onde começar

=== "Quero entender o projeto"

    Vá pra [Visão geral](overview/what-is-aspm.md). Cobre o que é ASPM, arquitetura, decisões.

=== "Quero rodar localmente / contribuir"

    Vá pra [Desenvolvedor → Começando](developer/getting-started.md).

=== "Quero integrar meu repo"

    Vá pra [Integração → Onboarding](integration/onboarding-repo.md).

=== "Quero a referência técnica"

    Vá pra [Referência → JobDescriptor v1](reference/job-descriptor.md).

## Stack atual

| Camada | Tecnologia |
|---|---|
| Ingest | FastAPI (`captain-hook`) |
| Transport | Redpanda (Kafka-compatible) |
| Orchestration | FastAPI (`moby-dick`) + Docker SDK |
| Scanner | SonarQube Community Build (image wrapper `aspm-sonar-runner`) |
| Auth GitHub | GitHub App + installation token |
| Normalização SARIF | adapter em `moby-dick` (Sonar API → SARIF v2.1.0) |
| Persistência scanner | postgres (`sonar-db`) |
| Persistência findings normalizados | FastAPI (`pequod`) + postgres + asyncpg |
| Deploy | docker-compose + systemd na VPS |

## Estado

| Componente | Status |
|---|---|
| Pipeline GitHub → check_run | ✅ funcionando end-to-end |
| Scanner SonarQube | ✅ funcionando |
| Extração SARIF cross-scanner | 🚧 hoje em `moby-dick/adapter/sonar`; migrando para dentro da scanner image ([§11](overview/decisions.md#11-extração-de-findings-dentro-da-scanner-image-target-arquitetural)) |
| Storage central de findings | ✅ `pequod` consume `findings.raw`, normaliza e dedupa por fingerprint |
| REST de findings (UI/IA) | ✅ `GET/PATCH /findings` em `pequod` |
| Pequod como source-of-truth (substitui papel do `sonar-db`) | 🎯 intenção declarada ([§14](overview/decisions.md#14-pequod-como-source-of-truth-de-findings-substitui-sonar-db-a-longo-prazo)) |
| Correlação cross-scanner | ⏳ adiado (precisa 2º scanner) |
| Enriquecimento IA | ⏳ adiado |

Estamos na **fase 1** do roadmap: pipeline E2E vivo, findings persistidos. Próximos passos: (i) migrar extração SARIF pra dentro do scanner image, (ii) adicionar 2º scanner, (iii) camada de IA sobre `pequod`.

## Projetos documentados

- [Pequod](pequod.md) — camada de persistência de findings
- [Moby-dick](moby-dick.md) — orquestrador Docker
- [TARS AI](tars-ai.md) — serviço de IA para triagem/enriquecimento
- [Heimdall Dashboard](heimdall-dashboard.md) — frontend de visualização
- [Captain-hook](captain-hook.md) — ingest de webhooks GitHub

Última atualização: 2026-08-17T23:32:31.855Z
