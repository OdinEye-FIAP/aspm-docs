#!/usr/bin/env bash
# Gera os segredos compartilhados e cria o .env de cada serviço a partir do
# .env.example. Idempotente: segredos ficam em $ASPM_HOME/.aspm-secrets.env
# e arquivos .env existentes não são sobrescritos (use --force).
#
# Uso:
#   ASPM_HOME=~/dev/aspm-ai ./bootstrap-env.sh                     # local
#   ASPM_HOME=~/aspm-ai BASE_DOMAIN=aspm.exemplo.com sudo -E ./bootstrap-env.sh --vps
#
# Não preenche (manual, ver docs): GITHUB_APP_ID, GITHUB_INSTALLATION_ID,
# GITHUB_APP_PRIVATE_KEY_PATH, SONAR_TOKEN (use sonar-bootstrap.sh) e chaves de IA.
set -euo pipefail

ASPM_HOME="${ASPM_HOME:?defina ASPM_HOME com o diretório que contém os repos}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
MODE=local; FORCE=0
for a in "$@"; do
  case "$a" in
    --vps) MODE=vps ;;
    --force) FORCE=1 ;;
    *) echo "argumento desconhecido: $a" >&2; exit 2 ;;
  esac
done

SERVICES=(captain-hook moby-dick pequod tars-ai)
SECRETS_FILE="$ASPM_HOME/.aspm-secrets.env"

gen() { python3 -c 'import secrets; print(secrets.token_urlsafe(32))'; }

# --- segredos compartilhados (gerados uma vez) -------------------------------
touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
# shellcheck disable=SC1090
source "$SECRETS_FILE"
ensure() { # ensure VAR
  if [ -z "${!1:-}" ]; then
    printf -v "$1" '%s' "$(gen)"
    echo "$1=${!1}" >> "$SECRETS_FILE"
  fi
}
for v in KAFKA_MESSAGE_SECRET GITHUB_WEBHOOK_SECRET \
         CAPTAIN_HOOK_TOKEN MOBY_DICK_TOKEN TARS_TO_PEQUOD_TOKEN MOBY_TO_TARS_TOKEN; do
  ensure "$v"
done

# --- helpers ------------------------------------------------------------------
setkv() { # setkv FILE KEY VALUE  (substitui a linha KEY=... ou acrescenta)
  local file="$1" key="$2" val="$3"
  if grep -qE "^${key}=" "$file"; then
    python3 - "$file" "$key" "$val" <<'PY'
import sys,re
f,k,v=sys.argv[1:4]
lines=open(f).read().split("\n")
lines=[(f"{k}={v}" if re.match(rf"^{re.escape(k)}=",l) else l) for l in lines]
open(f,"w").write("\n".join(lines))
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

target_for() { # caminho do arquivo de env do serviço
  if [ "$MODE" = vps ]; then echo "/etc/$1/env"; else echo "$ASPM_HOME/$1/.env"; fi
}

prepare() { # prepare svc -> imprime o caminho do arquivo pronto para edição
  local svc="$1" src="$ASPM_HOME/$1/.env.example" dst
  dst="$(target_for "$svc")"
  [ -f "$src" ] || { echo "faltando $src (clone o repo $svc em $ASPM_HOME)" >&2; exit 1; }
  if [ "$MODE" = vps ]; then
    mkdir -p "/etc/$svc"
  fi
  if [ -f "$dst" ] && [ "$FORCE" -eq 0 ]; then
    echo "· $dst já existe — mantido (use --force para recriar)" >&2
    echo ""   # sinaliza "não mexer"
    return
  fi
  cp "$src" "$dst"; chmod 600 "$dst"
  echo "$dst"
}

finish_perms() { # no modo vps: root:<usuário do serviço>, 640
  local svc="$1" dst="$2" user
  [ "$MODE" = vps ] || return 0
  user="$(echo "$svc" | tr -d '-')"   # captainhook, mobydick, pequod, tarsai
  if id "$user" >/dev/null 2>&1; then chown "root:$user" "$dst"; chmod 640 "$dst"; fi
}

ORIGIN=""
[ -n "$BASE_DOMAIN" ] && ORIGIN="https://heimdall.${BASE_DOMAIN}"

# --- captain-hook ------------------------------------------------------------
f="$(prepare captain-hook)"; if [ -n "$f" ]; then
  setkv "$f" APP_ENV "$([ "$MODE" = vps ] && echo production || echo local)"
  setkv "$f" GITHUB_WEBHOOK_SECRET "$GITHUB_WEBHOOK_SECRET"
  setkv "$f" KAFKA_MESSAGE_SECRET "$KAFKA_MESSAGE_SECRET"
  setkv "$f" PEQUOD_SERVICE_TOKEN "$CAPTAIN_HOOK_TOKEN"
  [ -n "$ORIGIN" ] && setkv "$f" CORS_ALLOWED_ORIGINS "$ORIGIN"
  finish_perms captain-hook "$f"; echo "✔ $f"
fi

# --- moby-dick ---------------------------------------------------------------
f="$(prepare moby-dick)"; if [ -n "$f" ]; then
  setkv "$f" APP_ENV "$([ "$MODE" = vps ] && echo production || echo local)"
  setkv "$f" KAFKA_MESSAGE_SECRET "$KAFKA_MESSAGE_SECRET"
  setkv "$f" PEQUOD_SERVICE_TOKEN "$MOBY_DICK_TOKEN"
  setkv "$f" TARS_SERVICE_TOKEN "$MOBY_TO_TARS_TOKEN"
  setkv "$f" DOCKER_NETWORK aspm-net
  [ -n "$ORIGIN" ] && setkv "$f" HEIMDALL_BASE_URL "$ORIGIN"
  [ "$MODE" = vps ] && setkv "$f" GITHUB_APP_PRIVATE_KEY_PATH /etc/moby-dick/github-app.pem
  finish_perms moby-dick "$f"; echo "✔ $f"
fi

# --- pequod ------------------------------------------------------------------
f="$(prepare pequod)"; if [ -n "$f" ]; then
  setkv "$f" APP_ENV "$([ "$MODE" = vps ] && echo production || echo local)"
  setkv "$f" KAFKA_MESSAGE_SECRET "$KAFKA_MESSAGE_SECRET"
  setkv "$f" CAPTAIN_HOOK_SERVICE_TOKEN "$CAPTAIN_HOOK_TOKEN"
  setkv "$f" MOBY_DICK_SERVICE_TOKEN "$MOBY_DICK_TOKEN"
  setkv "$f" TARS_SERVICE_TOKEN "$TARS_TO_PEQUOD_TOKEN"
  [ -n "$ORIGIN" ] && setkv "$f" CORS_ALLOWED_ORIGINS "$ORIGIN"
  finish_perms pequod "$f"; echo "✔ $f"
fi

# --- tars-ai -----------------------------------------------------------------
f="$(prepare tars-ai)"; if [ -n "$f" ]; then
  setkv "$f" PEQUOD_SERVICE_TOKEN "$TARS_TO_PEQUOD_TOKEN"
  setkv "$f" TARS_SERVICE_TOKEN "$MOBY_TO_TARS_TOKEN"
  finish_perms tars-ai "$f"; echo "✔ $f"
fi

cat <<MSG

Segredos em $SECRETS_FILE (chmod 600). Faltam, manualmente:
  1. GitHub App: cadastre GITHUB_WEBHOOK_SECRET (valor em $SECRETS_FILE) no webhook da App
  2. captain-hook e moby-dick: GITHUB_APP_ID, GITHUB_INSTALLATION_ID, GITHUB_APP_PRIVATE_KEY_PATH
  3. captain-hook: SONAR_TOKEN  ->  ops/scripts/sonar-bootstrap.sh
  4. tars-ai: AI_PROVIDER e a chave do provider (GROQ_/GEMINI_/HUGGINGFACE_API_KEY), se não usar mock
MSG
