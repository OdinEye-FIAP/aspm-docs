# ASPM-AI

Plataforma **Application Security Posture Management** com IA em construção pela OdinEye-FIAP.

## O que entrega

Quando um PR é aberto/atualizado num repo onboardado, a plataforma:

1. Recebe o webhook do GitHub
2. Despacha um scanner em container isolado
3. Roda análise (atualmente SonarQube; mais scanners e enriquecimento por IA virão)
4. Reporta o resultado como **check_run** no PR
5. Bloqueia ou libera merge conforme Quality Gate

```mermaid
flowchart LR
    Dev[Desenvolvedor]
    GH[GitHub PR]
    CH[captain-hook]
    K[(Kafka)]
    MD[moby-dick]
    SR[scanner container]
    SQ[SonarQube]

    Dev -->|push| GH
    GH -->|webhook| CH
    CH -->|publish job| K
    K -->|consume| MD
    MD -->|spawn| SR
    SR -->|scan| SQ
    SQ -->|QG result| SR
    SR -->|exit code| MD
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
| Persistência scanner | postgres (`sonar-db`) |
| Deploy | docker-compose + systemd na VPS |

## Estado

| Componente | Status |
|---|---|
| Pipeline GitHub → check_run | ✅ funcionando end-to-end |
| Scanner SonarQube | ✅ funcionando |
| Storage central de findings | ⏳ adiado (ver [Decisões](overview/decisions.md)) |
| Correlação cross-scanner | ⏳ adiado |
| Enriquecimento IA | ⏳ adiado |

Estamos na **fase 0 → 1** do roadmap. Foco em validar pipeline antes de escalar features.
