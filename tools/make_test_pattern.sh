#!/usr/bin/env bash
# Generates the AV-sync test pattern used by AVSyncMeter.
#
# Pattern: black screen. Every PERIOD seconds, starting at t = LEAD_IN, the whole
# frame goes white for FLASH_S seconds and a TONE_HZ sine burst plays for TONE_S
# seconds. The first sample of the tone and the first white frame are at exactly
# the same timestamp, so any difference a viewer sees/hears is the playback
# chain's A/V offset (plus sound travel time to the viewer).
#
# A dim grey caption (event counter) is shown between flashes so a human can tell
# the file is playing. It is dim on purpose so it barely moves the camera's
# luminance reading.
#
# Requires ffmpeg with libx264, aac, drawbox, drawtext, aevalsrc (stock builds have them).
#
# Usage: tools/make_test_pattern.sh [out_dir] [fps] [duration_s] [width] [height]
set -euo pipefail

OUT_DIR="${1:-AVSyncMeter/Resources}"
FPS="${2:-60}"
DURATION="${3:-120}"
W="${4:-1920}"
H="${5:-1080}"

# These constants are mirrored in AVSyncMeter/Pattern/TestPattern.swift. Keep them in sync.
PERIOD=2.0        # seconds between events
LEAD_IN=1.0       # first event time
FLASH_S=0.045     # white-frame duration (3 frames at 60 fps; the 0.045 avoids FP edge cases at 0.05)
TONE_HZ=1000
TONE_S=0.050      # tone-burst duration
TONE_AMP=0.7
RAMP_S=0.0005     # 0.5 ms linear fade in/out to avoid speaker clicks
SR=48000

mkdir -p "$OUT_DIR"
BASENAME="avsync_${H}p${FPS}"

FONT=""
for f in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
         /System/Library/Fonts/Helvetica.ttc \
         /Library/Fonts/Arial.ttf; do
  [ -f "$f" ] && FONT="$f" && break
done

# Video filter graph.
# - drawtext: dim caption + event counter (only when a font is available)
# - drawbox:  full-frame white during the flash window
EVENT_EXPR="gte(t,${LEAD_IN})*lt(mod(t-${LEAD_IN},${PERIOD}),${FLASH_S})"
VF=""
if [ -n "$FONT" ]; then
  VF="drawtext=fontfile='${FONT}':fontcolor=0x404040:fontsize=$((H/18)):x=(w-text_w)/2:y=(h-text_h)/2:text='AV SYNC TEST  %{eif\:max(0\,floor((t-${LEAD_IN})/${PERIOD})+1)\:d}',"
  VF="${VF}drawtext=fontfile='${FONT}':fontcolor=0x303030:fontsize=$((H/36)):x=(w-text_w)/2:y=(h/2+h/12):text='flash + ${TONE_HZ} Hz beep every ${PERIOD} s',"
fi
VF="${VF}drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='${EVENT_EXPR}'"

# Audio: sample-exact expression. Tone starts at exactly t = LEAD_IN + k*PERIOD.
PH="mod(t-${LEAD_IN},${PERIOD})"
AEXPR="if(gte(t,${LEAD_IN})*lt(${PH},${TONE_S}), ${TONE_AMP}*sin(2*PI*${TONE_HZ}*t)*min(1,${PH}/${RAMP_S})*min(1,(${TONE_S}-${PH})/${RAMP_S}), 0)"

common=(
  -f lavfi -i "color=c=black:s=${W}x${H}:r=${FPS}:d=${DURATION}"
  -f lavfi -i "aevalsrc='${AEXPR}':s=${SR}:c=stereo:d=${DURATION}"
  -vf "$VF"
  -c:v libx264 -preset medium -crf 16 -pix_fmt yuv420p -g "$FPS" -r "$FPS"
  -shortest
)

echo "Writing ${OUT_DIR}/${BASENAME}.mp4 (H.264 + AAC) ..."
ffmpeg -y -hide_banner -loglevel error "${common[@]}" \
  -c:a aac -b:a 192k -ar "$SR" \
  -movflags +faststart \
  "${OUT_DIR}/${BASENAME}.mp4"

echo "Writing ${OUT_DIR}/${BASENAME}_pcm.mov (H.264 + 16-bit PCM, no codec delay) ..."
ffmpeg -y -hide_banner -loglevel error "${common[@]}" \
  -c:a pcm_s16le -ar "$SR" \
  "${OUT_DIR}/${BASENAME}_pcm.mov"

ls -la "${OUT_DIR}/${BASENAME}".*
