# Onboarding de um repositório

Como adicionar um repo da org pra que ele receba scan automático em todo PR.

## Pré-requisitos

- Repo está numa GitHub Organization onde a App `aspm-ai-pipeline` foi criada
- Você tem permissão de **Admin** ou **Maintainer** no repo (pra configurar branch protection)

## Passo 1 — Instalar a GitHub App no repo

1. Vá em **Organization → Settings → GitHub Apps → aspm-ai-pipeline → Configure**
2. Em **Repository access**, escolha:
   - **All repositories** (mais aberto) OU
   - **Only select repositories** → adicione seu repo

A partir desse momento, qualquer push em PR dispara um webhook pro captain-hook.

## Passo 2 — Criar projeto no SonarQube

A `project key` precisa bater **exatamente** com `<owner>_<repo>` enviada pelo captain-hook.

=== "Via UI"
    1. http://localhost:9000 → **Projects → Create Project → Manually**
    2. **Display name:** nome amigável (ex: `meu-servico`)
    3. **Project Key:** `<owner>_<repo>` (ex: `OdinEye-FIAP_meu-servico`)
    4. **Main branch:** `main` (ou nome real da branch principal do repo)
    5. **Set Up → Locally** — não precisa configurar CI integration

=== "Via API"
    ```bash
    OWNER='OdinEye-FIAP'
    REPO='meu-servico'

    curl -u admin:<sua_senha> -X POST \
      http://localhost:9000/api/projects/create \
      -d "name=${REPO}&project=${OWNER}_${REPO}"
    ```

!!! tip "Project key padrão"
    Atualmente o captain-hook gera `SONAR_PROJECT_KEY` como `<owner>_<repo>`. Se quiser convenção diferente (ex: incluir `-svc`), precisa mexer no `_maybe_build_job` do captain-hook.

## Passo 3 — Validar webhook chegando

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
INFO - Job publicado: <uuid>
```

## Passo 4 — Validar scan rodando

```bash
sudo journalctl -u moby-dick -f
```

Deve aparecer:
```
INFO - Processando job_id=<uuid> kind=sonar_scan
INFO - Image aspm-sonar-runner:latest já existe local — skip pull
INFO - Running container moby-job-... image=aspm-sonar-runner:latest
INFO - Container moby-job-... finalizado exit_code=<0 ou 1>
INFO - Check run atualizado: <id> - success/failure
```

## Passo 5 — Validar check_run no PR

Aba **Checks** do PR deve mostrar:

```
✓ SonarQube Scan   (verde se QG pass)
✗ SonarQube Scan   (vermelho se QG fail)
```

Click no check → abre details com:
- Title
- Summary (`Job <uuid> concluído com sucesso` ou similar)
- Text (logs tail do scanner)

## Passo 6 — Configurar branch protection (opcional, recomendado)

Pra **bloquear merge** quando o QG falhar:

1. Repo → **Settings → Branches → Branch protection rules → Add rule**
2. **Branch name pattern:** `main` (ou padrão da org)
3. Marcar **Require status checks to pass before merging**
4. Em **Status checks**, buscar `SonarQube Scan` (precisa ter rodado pelo menos uma vez antes pra aparecer)
5. **Save changes**

Resultado: PRs com QG fail não podem ser mergeados, mesmo por admin (se você ativar "Include administrators").

## Custos / impacto

- **Cada PR push**: ~30-90s adicional pra resultado final do scan (depende do tamanho do código)
- **Recursos VPS**: ~512MB de RAM picando durante scan (container scanner)
- **Storage**: scan re-escreve análise no `sonar-db` — não cresce ilimitado (Community Build mantém só última análise da main)

## Coisas importantes pra saber

### Cada scan sobrescreve

SonarQube Community Build mostra **só o último scan rodado** no projeto. Se você tem 3 PRs abertos e push em todos:
- Scan 1 roda → métricas no Sonar UI
- Scan 2 roda → métricas substituídas
- Scan 3 roda → métricas substituídas de novo

Isso é limitação do Community Build. A decisão registrada em [Decisões](../overview/decisions.md#7-modo-de-scan-análise-principal-sem-pr-mode) é usar **só o check_run como feedback útil**.

### Branch principal precisa bater

Se seu repo usa `master` ou outra branch como principal, e o projeto no Sonar foi criado com `main`, vai dar mismatch.

**Fix:**
- **Sonar UI:** Project → Administration → Branches and Pull Requests → editar main branch name

### Não scaneia commits direto na main

Atualmente só `pull_request.{opened,synchronize,reopened}` dispara scan. Push direto em main NÃO dispara nada.

Adicionar evento `push` no captain-hook é mudança simples — abra issue se precisar.

### Repos privados funcionam

GitHub App com `Contents: Read` clona repos privados via `https://x-access-token:${TOKEN}@github.com/...`. Não precisa tornar o repo público.

## Padrão de troubleshooting (no PR)

Se o check ficar vermelho mas você não entender por quê:

1. Click no check no PR
2. Ler o `Summary` (sumário do erro)
3. Expandir `Text` (logs tail)
4. Se precisar mais detalhe: olhar Sonar UI no link logado pelo scanner

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

Webhooks param imediatamente. Scans existentes no Sonar UI ficam até serem deletados manualmente.
