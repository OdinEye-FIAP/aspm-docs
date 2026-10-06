#!/usr/bin/env bash
# Troca a senha padrão do SonarQube e gera o Global Analysis Token usado pelos
# scanners. Opcionalmente grava SONAR_TOKEN no arquivo de env do captain-hook.
#
# Uso:
#   SONAR_ADMIN_PASSWORD='SenhaForte!123' ./sonar-bootstrap.sh [--write-to /etc/captain-hook/env]
set -euo pipefail

URL="${SONAR_URL:-http://localhost:9000}"
NEW_PASS="${SONAR_ADMIN_PASSWORD:?defina SONAR_ADMIN_PASSWORD}"
TOKEN_NAME="${SONAR_TOKEN_NAME:-aspm-pipeline}"
WRITE_TO=""; [ "${1:-}" = "--write-to" ] && WRITE_TO="${2:?informe o arquivo}"

valid() { curl -sf -u "admin:$1" "$URL/api/authentication/validate" | grep -q '"valid":true'; }

if valid admin; then
  curl -sf -u admin:admin -X POST "$URL/api/users/change_password" \
    --data-urlencode "login=admin" --data-urlencode "previousPassword=admin" \
    --data-urlencode "password=$NEW_PASS" >/dev/null
  echo "✔ senha do admin alterada"
fi
valid "$NEW_PASS" || { echo "✘ SONAR_ADMIN_PASSWORD não confere com a senha atual do admin" >&2; exit 1; }

# revoga token anterior com o mesmo nome (idempotência) e gera um novo
curl -sf -u "admin:$NEW_PASS" -X POST "$URL/api/user_tokens/revoke" --data-urlencode "name=$TOKEN_NAME" >/dev/null || true
TOKEN="$(curl -sf -u "admin:$NEW_PASS" -X POST "$URL/api/user_tokens/generate" \
  --data-urlencode "name=$TOKEN_NAME" --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"
[ -n "$TOKEN" ] || { echo "✘ não foi possível gerar o token" >&2; exit 1; }

if [ -n "$WRITE_TO" ]; then
  python3 - "$WRITE_TO" "$TOKEN" <<'PY'
import sys,re
f,tok=sys.argv[1:3]
txt=open(f).read()
if re.search(r"^SONAR_TOKEN=.*$",txt,re.M):
    txt=re.sub(r"^SONAR_TOKEN=.*$",f"SONAR_TOKEN={tok}",txt,flags=re.M)
else:
    txt+=f"\nSONAR_TOKEN={tok}\n"
open(f,"w").write(txt)
PY
  echo "✔ SONAR_TOKEN gravado em $WRITE_TO (reinicie o captain-hook)"
else
  echo "SONAR_TOKEN=$TOKEN"
fi
