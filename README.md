# ASPM-AI Docs

Documentação central do ASPM-AI (Application Security Posture Management com IA).

Site publicado: https://odineye-fiap.github.io/aspm-docs/ (após primeiro push em `main`).

## Estrutura

```
docs/
├── index.md                 # landing
├── overview/                # stakeholder / decisão
├── developer/               # você + time dev
├── integration/             # devs de repos onboardados
└── reference/               # schemas e APIs
```

## Rodar localmente

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mkdocs serve
# acesse http://localhost:8000
```

`mkdocs serve` faz hot reload — editar `.md` recarrega o browser sozinho.

## Deploy

Push em `main` → GitHub Actions buildea e publica em GitHub Pages.

Pré-requisitos no GitHub:
1. **Settings → Pages → Source = GitHub Actions**
2. Workflow `.github/workflows/deploy-docs.yml` já configurado

## Estrutura do site

| Seção | Público | O que cobre |
|---|---|---|
| **Visão geral** | Stakeholder / apresentação | O que é ASPM, arquitetura macro, decisões registradas |
| **Desenvolvedor** | Você + time | Como rodar, contribuir, adicionar scanner, debugar |
| **Integração** | Devs de outros repos | Onboarding, como ler check_run no PR |
| **Referência** | Quem implementa contra a plataforma | JobDescriptor v1, tópicos Kafka, endpoints |

## Convenções

- **Mermaid** pra diagramas (renderiza nativo no Material)
- **Admonitions** pra notas/warnings/dicas (`!!! note`, `!!! warning`)
- **Tabs** pra mostrar variantes (ex: Python vs curl)
- Em pt-BR. Termos técnicos não traduzidos quando padrão da indústria.
