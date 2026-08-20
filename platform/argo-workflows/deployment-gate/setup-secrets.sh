#!/usr/bin/env bash
# Create the two secrets the deployment-gate poller needs, in namespace `argo`.
# RUN THIS YOURSELF — it references the App private key; nothing else reads it.
#
#   APP_ID=4655069 PEM=/path/to/app.private-key.pem ./setup-secrets.sh
#
# The installation id is DERIVED from the App JWT (no need to find it in the UI).
# Override with INSTALLATION_ID=<id> if the App has more than one installation.
#
# For the sandbox connection test use the sandbox App (id 4655069) installed on
# nachog00/zaino-pipeline-sandbox; for production use the org App on zingolabs.
# The App must have **Deployments: Read & Write** (list deployments + post
# statuses) — add it in the App settings if missing.
set -euo pipefail

: "${APP_ID:?set APP_ID (e.g. 4655069)}"
: "${PEM:?set PEM to the path of the App private-key .pem}"
NS="${NS:-argo}"

# Mint a short-lived App JWT (RS256) and list the App's installations to get the id.
if [ -z "${INSTALLATION_ID:-}" ]; then
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  pld=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$APP_ID" | b64url)
  sig=$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$PEM" -binary | b64url)
  jwt="$hdr.$pld.$sig"
  INSTALLATION_ID=$(curl -sSf -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations" | jq -r '.[0].id')
  echo "derived INSTALLATION_ID=$INSTALLATION_ID"
fi
[ -n "$INSTALLATION_ID" ] && [ "$INSTALLATION_ID" != null ] || { echo "could not determine INSTALLATION_ID" >&2; exit 1; }

kubectl create secret generic github-app-meta -n "$NS" \
  --from-literal=appID="$APP_ID" \
  --from-literal=installationID="$INSTALLATION_ID" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic github-app -n "$NS" \
  --from-file=privateKey="$PEM" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "created github-app-meta (appID=$APP_ID, installationID=$INSTALLATION_ID) + github-app in namespace $NS"
