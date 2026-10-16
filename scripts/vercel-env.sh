#!/usr/bin/env bash
# Push every var in .env to Vercel production, then redeploy. Run after editing .env.
# usage: VERCEL_TOKEN=... bash scripts/vercel-env.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERCEL_TOKEN:?set VERCEL_TOKEN}"
SCOPE=${VERCEL_SCOPE:-chroma-way}
while IFS='=' read -r k v; do
  [[ -z "$k" || "$k" == \#* ]] && continue
  printf '%s' "$v" | vercel env add "$k" production --force --token "$VERCEL_TOKEN" --scope "$SCOPE" >/dev/null
  echo "set $k"
done < .env
vercel deploy --prod --yes --token "$VERCEL_TOKEN" --scope "$SCOPE"
