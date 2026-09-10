# Onboarding de um repositório

Como adicionar um repo da org pra que ele receba scan automático em todo PR.

!!! note "Security Baseline (push na default branch) — ainda não disponível"
    Uma versão anterior desta página descrevia também um "Security Baseline" disparado por `push` direto na default branch (full-branch scan). O pequod já tem suporte completo a esse fluxo (`scope=branch`), mas capt`ain-hook e moby-dick ainda não o implementam em `main` — um push hoje não dispara nenhum scan. Este onboarding cobre apenas o que funciona hoje: scan em PR. Ver [Decisão §15](../overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--nova).

## Pré-requisitos

- Repo está numa GitHub Organization onde a App `aspm-ai-pipeline` foi criada
- Você tem permissão de **Admin** ou **Maintainer** no repo (pra configurar branch protection)

## Passo 1 — Instalar a GitHub App no repo

1. Vá em **Organization → Settings → GitHub Apps → aspm-ai-pipeline → Configure**
2. Em **Repository access**, escolha:
   - **All repositories** (mais aberto) OU
   - **Only select repositories** → adicione seu repo

A partir desse momento, qualquer PR (`opened`/`synchronize`/`reopened`) dispara um webhook pro captain-hook que inicia o Quality Gate. Um `push` direto também chega como webhook, mas hoje não tem handler dedicado — é só logado e descartado (ver nota no topo).

!!! note "Instalação em massa vs. `ping` individual"
    Se você instalar a App **selecionando vários repositórios de uma vez** (ou em toda a organização), o GitHub dispara `installation`/`installation_repositories` — o captain-hook registra todos eles no pequod, mas **não** abre o PR de auto-scaffold automaticamente (evita dezenas de PRs simultâneos). Pra disparar o scaffold desses repositórios manualmente, chame `POST /repos/{owner}/{repo}/scaffold-pr` no captain-hook.

## Passo 2 — Criar projeto no SonarQube

A `project key` precisa bater **exatamente** com `gh_<repository.id>` enviada pelo captain-hook.

**Como descobrir o `repository.id` do GitHub:**

```bash
gh api /repos/<owner>/<repo> --jq '.id'
# ex: 847291
```

=== "Via UI"
    1. http://localhost:9000 → **Projects → Create Project → Manually**
    2. **Display name:** `<owner>/<repo>` (ex: `OdinEye-FIAP/meu-servico`)
    3. **Project Key:** `gh_<repository.id>` (ex: `gh_847291`)
    4. **Main branch:** `main` (ou nome real da branch principal do repo)
    5. **Set Up → Locally** — não precisa configurar CI integration

=== "Via API"
    ```bash
    OWNER='OdinEye-FIAP'
    REPO='meu-servico'
    REPO_ID=$(gh api /repos/${OWNER}/${REPO} --jq '.id')

    curl -u admin:<sua_senha> -X POST \
      http://localhost:9000/api/projects/create \
      -d "name=${OWNER}/${REPO}&project=gh_${REPO_ID}"
    ```

!!! tip "Por que `gh_<repository.id>`?"
    `repository.id` é imutável no GitHub — sobrevive a rename, transfer entre orgs, fork. Garante sanitização (sem caracteres especiais) e dedup estável no pequod via `repo_id`. Detalhes em [Decisão §13](../overview/decisions.md#13-sonar_project_key-derivado-de-githubrepositoryid).

!!! warning "Repos já onboardados com `<owner>_<repo>`"
    Se o projeto Sonar foi criado antes da decisão §13, renomear via:
    ```bash
    curl -u admin:<senha> -X POST http://localhost:9000/api/projects/update_key \
      -d "from=OdinEye-FIAP_meu-servico&to=gh_${REPO_ID}"
    ```

## Passo 3 — (Opcional) Habilitar Semgrep, Trivy e/ou ZAP

Por padrão só o SonarQube roda. Pra habilitar os outros scanners, configure no `.env` do captain-hook:

```env
ENABLE_SEMGREP_SCAN=true
ENABLE_TRIVY_SCAN=true
ENABLE_ZAP_SCAN=true
DAST_MODE=fixed_url          # ou compose_preview
ZAP_TARGET_URL=https://staging.meu-servico.exemplo   # obrigatório se DAST_MODE=fixed_url
```

Isso é configuração **global do captain-hook**, não por repositório — vale para todos os repos onboardados na mesma instância. Ver [Adicionar novo scanner](../developer/adding-a-scanner.md) para o detalhe de cada flag.

!!! warning "`DAST_MODE=compose_preview` exige `docker-compose.aspm.yml` real"
    Se optar por `compose_preview`, o arquivo scaffoldado pelo auto-scaffold (Passo 1) é um **skeleton não funcional** — precisa de ajustes (porta, build, healthcheck) antes do ZAP conseguir subir e escanear a preview do seu repo.

## Passo 4 — Validar webhook chegando

Faça um push de teste numa branch:

```bash
git checkout -b test/aspm-integration
echo "test" >> README.md
git commit -am "test: aspm integration"
git push -u origin test/aspm-integration
gh pr create --title "test" --body "validando integração ASPM" --base main
```

Na VPS:

```bash
sudo journalctl -u captain-hook -f | grep -i webhook
```

Deve aparecer:
```
INFO - Webhook aceito: pull_request
INFO - Quality Gate iniciado workflow_id=<uuid> repo=<owner>/<repo> pr=<n> scanners=sonar,...
INFO - Job publicado: job_id=<uuid> kind=sonar_scan repo=<owner>/<repo> workflow_id=<uuid>
```

## Passo 5 — Validar scan rodando

```bash
sudo journalctl -u moby-dick -f
```

Deve aparecer, por scanner habilitado:
```
INFO - Processando job_id=<uuid> kind=sonar_scan repo=<owner>/<repo> ref=<sha> workflow_id=<uuid>
INFO - Running container ... image=aspm-sonar-runner:latest
INFO - Findings publicados job_id=<uuid> scanner=sonar results=<N>
INFO - Quality Gate scanner concluído workflow_id=<uuid> job_id=<uuid> scanner=sonar status=completed findings=<N>
INFO - Job materializado job_id=<uuid> workflow_id=<uuid> exit_code=<0 ou 1> sarif_present=True operational_error=False
```

Quando o último scanner esperado terminar, o moby-dick chama o pequod e finaliza o Quality Gate:
```
INFO - Quality Gate Check finalizado workflow_id=<uuid> evaluation_id=<uuid> decision=<passed|warning|failed|error> conclusion=<success|neutral|failure> check_id=<id> scope=pr
```

## Passo 5b — Validar findings persistidos no pequod

```bash
sudo journalctl -u pequod -f
```

Deve aparecer:
```
INFO - Ingest job_id=<uuid> repo=<owner>/<repo> scanner=sonarqube
INFO - Upsert findings: inseridos=<N> atualizados=<M>
INFO - Findings ingeridos job_id=<uuid>
```

Verificar via REST:

```bash
curl 'http://localhost:7070/findings?repo=<owner>/<repo>&limit=5' | jq
```

## Passo 6 — Validar checks no PR

Aba **Checks** do PR deve mostrar o check individual de cada scanner habilitado **e** o check consolidado:

```
✓ OdinEye / Quality Gate   (verde se todos os scanners passaram / amarelo se passou com avisos)
✓ SonarQube Scan
✓ Semgrep SAST              (se habilitado)
✓ Trivy SCA                 (se habilitado)
✓ OWASP ZAP DAST              (se habilitado)
```

Click em qualquer check → abre details com Title, Summary e Text (anotações inline + logs tail). Ver [Entendendo o check_run no PR](check-run.md) para o detalhe completo dos dois níveis de check.

## Passo 7 — Security Baseline (push na default branch) — ainda não disponível

Diferente do que uma versão anterior desta página descrevia, **push direto na default branch não dispara nenhum scan hoje.** Não há passo de validação pra rodar aqui — o design existe (full-branch scan, check_run no commit, Issue agregada), mas depende de trabalho pendente em captain-hook (produzir o evento a partir do push) e moby-dick (consumir e reagir). O pequod já está pronto do lado dele. Ver [Decisão §15](../overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--nova) e o `TODO.md` da raiz do monorepo local para o plano de recuperação, se você for trabalhar nisso.

## Passo 8 — Configurar branch protection (opcional, recomendado)

Pra **bloquear merge** quando o Quality Gate falhar:

1. Repo → **Settings → Branches → Branch protection rules → Add rule**
2. **Branch name pattern:** `main` (ou padrão da org)
3. Marcar **Require status checks to pass before merging**
4. Em **Status checks**, buscar `OdinEye / Quality Gate` (precisa ter rodado pelo menos uma vez antes pra aparecer) — use esse check consolidado, não os individuais, se quiser exigir todos os scanners habilitados
5. **Save changes**

Resultado: PRs com Quality Gate reprovado (`failed`/`error`) não podem ser mergeados, mesmo por admin (se você ativar "Include administrators"). `warning` mapeia para `neutral` no check e não bloqueia merge por padrão.

## Custos / impacto

- **Cada PR push**: ~30s-3min adicional por scanner habilitado, até o resultado final do Quality Gate (depende do tamanho do código e de quantos scanners estão ativos)
- **Recursos VPS**: ~512MB de RAM por container de scanner rodando; `compose_preview` do ZAP soma o custo de subir a aplicação inteira
- **Storage**: Sonar re-escreve análise no `sonar-db` a cada scan — não cresce ilimitado (Community Build mantém só última análise da main)

## Coisas importantes pra saber

### Cada scan do Sonar sobrescreve

SonarQube Community Build mostra **só o último scan rodado** no projeto. Se você tem 3 PRs abertos e push em todos, cada novo scan substitui as métricas anteriores na Sonar UI.

Isso é limitação do Community Build. A decisão registrada em [Decisões](../overview/decisions.md#7-modo-de-scan-análise-principal-sem-pr-mode) é usar **o check_run (e, para findings, o pequod) como feedback confiável**, não a Sonar UI isolada.

### Branch principal precisa bater

Se seu repo usa `master` ou outra branch como principal, e o projeto no Sonar foi criado com `main`, vai dar mismatch.

**Fix:**
- **Sonar UI:** Project → Administration → Branches and Pull Requests → editar main branch name

### Push direto na default branch não dispara nada hoje (corrigido 2026-09-10)

Diferente do que uma versão anterior desta documentação afirmava, `push` na default branch **é ignorado** — o webhook chega no captain-hook, mas cai no branch "evento sem processamento dedicado" e é só logado. Não há Security Baseline, check_run no commit ou Issue agregada em produção hoje. Ver Passo 7 e [Decisão §15](../overview/decisions.md#15-quality-gate-com-scopepr-e-scopebranch-security-baseline--nova).

### Repos privados funcionam

GitHub App com `Contents: Read` clona repos privados via `https://x-access-token:${TOKEN}@github.com/...`. Não precisa tornar o repo público.

## Padrão de troubleshooting (no PR)

Se o check ficar vermelho mas você não entender por quê:

1. Click no check (consolidado ou individual)
2. Ler o `Summary` (sumário do erro)
3. Expandir `Text` (anotações + logs tail)
4. Se precisar mais detalhe: olhar Sonar UI no link logado pelo scanner, ou o dashboard do pequod/heimdall

Se ficar `in_progress` muito tempo (>5min):

1. Avisar quem mantém a plataforma
2. Pessoa pode ver com:
   ```bash
   sudo journalctl -u moby-dick -f
   docker ps --filter "name=moby-job-"
   ```

## Off-boarding

Pra **parar** de scanear um repo:

1. **Organization → Settings → GitHub Apps → aspm-ai-pipeline → Configure**
2. Em **Repository access**, remover o repo da lista

Webhooks (PR) param imediatamente. Scans existentes no Sonar UI ficam até serem deletados manualmente.
