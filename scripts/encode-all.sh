#!/bin/bash
# Encode every source clip to HLS. Mapping: source file -> episode slug (matches data/catalog.json).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=video/source

while read -r file slug; do
  [[ -z $file || $file == \#* ]] && continue
  scripts/encode-hls.sh "$SRC/$file" "$slug" </dev/null
done <<'EOF'
14522339_3840_2160_25fps.mp4       late-night-debugging
6804647-uhd_4096_2160_25fps.mp4    ship-it
Computer_Vision_Dedupe.mp4         training-the-machines
6804114-uhd_4096_2160_25fps.mp4    inside-the-data-lab
7989833-hd_1920_1080_25fps.mp4     pair-programming
12283296-uhd_3840_2160_25fps.mp4   stand-up
8631874-uhd_3840_2160_25fps.mp4    team-huddle
12896414-uhd_2160_3840_24fps.mp4   behind-the-screens
EOF
