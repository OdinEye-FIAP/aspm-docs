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

## Subir o ecossistema (ops/)

`ops/` guarda o que é necessário para subir o ASPM-AI inteiro, local ou na VPS:

| Caminho | O que é |
|---|---|
| `ops/scripts/infra-up.sh` | rede, Redpanda, SonarQube, Postgres e tópicos Kafka |
| `ops/scripts/bootstrap-env.sh` | gera segredos compartilhados e os `.env` de cada serviço |
| `ops/scripts/sonar-bootstrap.sh` | troca a senha do Sonar e gera o `SONAR_TOKEN` |
| `ops/scripts/build-scanners.sh` | builda as imagens `aspm-*-runner` |
| `ops/scripts/install-services.sh` | VPS: usuários, `/opt/<svc>`, venv e units systemd |
| `ops/scripts/build-heimdall.sh` | VPS: build do dashboard apontando para `BASE_DOMAIN` |
| `ops/scripts/smoke-test.sh` | valida infra, tópicos, imagens e `/health` |
| `ops/compose/` | overrides de compose para VPS (portas em `127.0.0.1`, restart) |
| `ops/caddy/` | Caddy (TLS + proxy) parametrizado por `BASE_DOMAIN` |
| `ops/systemd/` | unit do tars-ai (as demais vivem em cada repo) |

Roteiro completo: `docs/developer/getting-started.md` (local) e
`docs/developer/deploy-vps.md` (VPS).

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
