#!/usr/bin/env bash
# Build the web UI for Firebase Hosting: same files as public/, plus a config.js
# that points the page at the AWS API. Output: gcp/hosting-dist (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${API_BASE:?set API_BASE, e.g. API_BASE=https://d1436kyrcdypmk.cloudfront.net}"
OUT=gcp/hosting-dist

npm run build:css
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R public/. "$OUT"/
printf "window.STATION_STREAM = { apiBase: '%s' };\n" "${API_BASE%/}" > "$OUT/config.js"

echo "Built $OUT with apiBase=${API_BASE%/}"
ls -la "$OUT"
