#!/usr/bin/env bash
# Build the web UI for Firebase Hosting: same files as public/, plus a config.js made from
# gcp/hosting-config.json (AWS API URL, likes function URL, Firebase web config; all public
# identifiers, no secrets). Output: gcp/hosting-dist (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=gcp/hosting-dist

npm run build:css
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R public/. "$OUT"/
node -e 'const c = require("./gcp/hosting-config.json"); console.log(`window.STATION_STREAM = ${JSON.stringify(c, null, 2)};`)' > "$OUT/config.js"

echo "Built $OUT"
cat "$OUT/config.js"
