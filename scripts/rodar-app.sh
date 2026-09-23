#!/usr/bin/env bash
# Sobe o app Flutter no celular com a configuração do .env da raiz.
#
# Existe para não ter que digitar quatro --dart-define à mão e correr o risco de
# rodar com defaults errados — foi exatamente o que aconteceu no primeiro teste
# em aparelho, e o sintoma (audience recusada) não apontava para a causa.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$RAIZ/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗ $ENV_FILE não existe."
  echo "  Copie .env.example para .env e preencha, ou rode a skill:"
  echo "  /poc-login-credenciais"
  exit 1
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [[ "${APP_EXPECTED_AUDIENCE:-<PREENCHER>}" == *"<PREENCHER>"* ]]; then
  echo "✗ APP_EXPECTED_AUDIENCE ainda está como <PREENCHER> no .env."
  echo "  Rode a skill /poc-login-credenciais, ou preencha à mão."
  exit 1
fi

# O flutter run precisa do FVM quando não há flutter no PATH.
if command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
elif command -v fvm >/dev/null 2>&1; then
  FLUTTER=(fvm flutter)
else
  echo "✗ Nem flutter nem fvm no PATH."
  exit 1
fi

# Sem isto o celular não alcança o Vite, e a WebView mostra
# ERR_CONNECTION_REFUSED sem dizer o porquê.
if [[ "${APP_SPA_BASE_URL:-}" == *"localhost"* ]] && command -v adb >/dev/null 2>&1; then
  PORTA="$(sed -E 's|.*localhost:([0-9]+).*|\1|' <<< "$APP_SPA_BASE_URL")"
  adb reverse "tcp:$PORTA" "tcp:$PORTA" >/dev/null && \
    echo "✓ adb reverse tcp:$PORTA ativo"
fi

DEFINES=(
  "--dart-define=SPA_BASE_URL=${APP_SPA_BASE_URL:-http://localhost:5173/}"
  "--dart-define=EXPECTED_AUDIENCE=${APP_EXPECTED_AUDIENCE}"
)
[[ -n "${APP_TENANT_ID:-}" && "${APP_TENANT_ID}" != *"<PREENCHER>"* ]] && \
  DEFINES+=("--dart-define=TENANT_ID=${APP_TENANT_ID}")
[[ -n "${APP_PROBE_URL:-}" ]] && \
  DEFINES+=("--dart-define=PROBE_URL=${APP_PROBE_URL}")
[[ -n "${APP_WEBVIEW_USER_AGENT:-}" ]] && \
  DEFINES+=("--dart-define=WEBVIEW_USER_AGENT=${APP_WEBVIEW_USER_AGENT}")

echo "→ ${FLUTTER[*]} run ${DEFINES[*]}"
cd "$RAIZ/app"
exec "${FLUTTER[@]}" run "${DEFINES[@]}" "$@"
