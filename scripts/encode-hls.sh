#!/bin/bash
# Encode one source clip into an adaptive HLS ladder (360p/720p/1080p) plus a poster image.
# Usage: scripts/encode-hls.sh <input.mp4> <slug>
# Output: video/out/<slug>/master.m3u8, <rendition>/index.m3u8 + segments, poster.jpg
set -euo pipefail

IN="$1"
SLUG="$2"
OUT="$(cd "$(dirname "$0")/.." && pwd)/video/out/$SLUG"
SEG=4   # seconds per segment; keyframes every 2s so every segment starts on one

probe() { ffprobe -v error -select_streams "$1" -show_entries "$2" -of csv=p=0 "$IN" | head -1; }
SRC_H=$(probe v:0 stream=height)
SRC_W=$(probe v:0 stream=width)
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN")
HAS_AUDIO=$(probe a stream=index)

# Ladder: height, width, video bitrate (kbps). Skip rungs above the source
# resolution (upscaling only adds bytes). Portrait sources are judged by width.
LADDER=("360 640 800" "720 1280 2800" "1080 1920 5000")
RUNGS=()
for r in "${LADDER[@]}"; do
  read -r h w _ <<<"$r"
  if (( SRC_W >= SRC_H ? SRC_H >= h : SRC_W >= h )); then RUNGS+=("$r"); fi
done
N=${#RUNGS[@]}

rm -rf "$OUT" && mkdir -p "$OUT"

# Every rendition is fit into a 16:9 frame (pillarboxed if the source is vertical),
# so TVs never get a sideways-stretched picture.
FILTER="[0:v]split=$N"
for i in $(seq 0 $((N - 1))); do FILTER+="[s$i]"; done
FILTER+=";"
MAPS=() ; VARMAP=""
for i in $(seq 0 $((N - 1))); do
  read -r h w kbps <<<"${RUNGS[$i]}"
  FILTER+="[s$i]scale=w=$w:h=$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2,setsar=1[v$i];"
  MAPS+=(-map "[v$i]" -map "$([[ -n $HAS_AUDIO ]] && echo 0:a:0 || echo 1:a:0)"
         -b:v:$i "${kbps}k" -maxrate:v:$i "$((kbps * 107 / 100))k" -bufsize:v:$i "$((kbps * 3 / 2))k")
  VARMAP+="v:$i,a:$i,name:${h}p "
done
FILTER="${FILTER%;}"

# Clips without audio get a silent track, so every rendition has the same tracks.
SILENCE=()
[[ -z $HAS_AUDIO ]] && SILENCE=(-f lavfi -t "$DUR" -i anullsrc=channel_layout=stereo:sample_rate=48000)

echo "[$SLUG] ${SRC_W}x${SRC_H}, ${DUR}s, audio=$([[ -n $HAS_AUDIO ]] && echo yes || echo "no, adding silence"), rungs: ${VARMAP}"

ffmpeg -nostdin -hide_banner -loglevel error -y \
  -hwaccel videotoolbox -i "$IN" ${SILENCE[@]+"${SILENCE[@]}"} \
  -filter_complex "$FILTER" "${MAPS[@]}" \
  -c:v libx264 -preset veryfast -profile:v high \
  -force_key_frames "expr:gte(t,n_forced*2)" -sc_threshold 0 \
  -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -f hls -hls_time $SEG -hls_playlist_type vod -hls_flags independent_segments \
  -hls_segment_filename "$OUT/%v/seg_%03d.ts" \
  -master_pl_name master.m3u8 -var_stream_map "${VARMAP% }" \
  "$OUT/%v/index.m3u8"

ffmpeg -nostdin -hide_banner -loglevel error -y -ss 3 -i "$IN" -frames:v 1 \
  -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2" \
  -q:v 4 "$OUT/poster.jpg"

echo "[$SLUG] done: $(du -sh "$OUT" | cut -f1)"
