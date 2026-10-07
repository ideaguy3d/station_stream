#!/bin/sh
# 20-second color-bar test video as HLS, a placeholder until Phase 2 adds real clips.
set -e
OUT="$(dirname "$0")/../video/out/test-pattern"
mkdir -p "$OUT"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 20 -c:v libx264 -preset veryfast -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "$OUT/seg_%03d.ts" "$OUT/master.m3u8"
echo "wrote $OUT/master.m3u8"
