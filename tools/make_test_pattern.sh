#!/usr/bin/env bash
# Generates the AV-sync test pattern(s) used by AVSyncMeter.
#
# Pattern: black screen. Starting at frame F0 (= 1 s), every P frames (= 2 s) the whole frame
# goes white for FLASH_FRAMES frames while a 1 kHz sine burst plays for TONE_S seconds.
# Events are defined on FRAME boundaries at the chosen frame rate, and the tone starts at
# exactly that frame's timestamp, so the file itself carries no sub-frame A/V offset at any
# frame rate (including 23.976 and 29.97, where 1.0 s is not a frame boundary).
#
# A dim grey caption (frame rate + event counter) is drawn between flashes so a person can tell
# the file is playing. It is dim on purpose so it barely moves the camera's luminance reading.
#
# Usage:
#   tools/make_test_pattern.sh [-o out_dir] [-d seconds] [-s WxH] [-m] [fps ...]
#     -o  output directory              (default AVSyncMeter/Resources)
#     -d  duration in seconds           (default 60; use 600-1800 for drift tests)
#     -s  frame size                    (default 1920x1080)
#     -m  also write DNxHR LB / 24-bit PCM MXF (OP1a) for Avid Media Composer link/import
#     fps one or more of 23.976 24 25 29.97 30 50 59.94 60, or "all" (default)
#
# Requires ffmpeg with libx264, aac, dnxhd, drawbox, drawtext, aevalsrc (stock builds have them).
set -euo pipefail

OUT_DIR="AVSyncMeter/Resources"
DURATION=60
SIZE="1920x1080"
WRITE_MXF=0
while getopts "o:d:s:m" opt; do
  case $opt in
    o) OUT_DIR="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    s) SIZE="$OPTARG" ;;
    m) WRITE_MXF=1 ;;
    *) echo "bad option" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
RATES=("$@")
[ ${#RATES[@]} -eq 0 ] && RATES=(all)
[ "${RATES[0]}" = "all" ] && RATES=(23.976 24 25 29.97 30 50 59.94 60)

W="${SIZE%x*}"
H="${SIZE#*x}"

# Constants mirrored in AVSyncMeter/Pattern/TestPattern.swift. Keep them in sync.
PERIOD_S=2          # nominal seconds between events (rounded to whole frames)
LEAD_IN_S=1         # nominal time of the first event (rounded to whole frames)
TONE_HZ=1000
TONE_S=0.050
TONE_AMP=0.7
RAMP_S=0.0005       # 0.5 ms linear fade in/out to avoid speaker clicks
SR=48000

FONT=""
for f in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
         /System/Library/Fonts/Helvetica.ttc \
         /Library/Fonts/Arial.ttf; do
  [ -f "$f" ] && FONT="$f" && break
done

mkdir -p "$OUT_DIR"

for RATE in "${RATES[@]}"; do
  case "$RATE" in
    23.976|23.98|2398) NUM=24000; DEN=1001; LABEL=2398 ;;
    24)                NUM=24;    DEN=1;    LABEL=24 ;;
    25)                NUM=25;    DEN=1;    LABEL=25 ;;
    29.97|2997)        NUM=30000; DEN=1001; LABEL=2997 ;;
    30)                NUM=30;    DEN=1;    LABEL=30 ;;
    50)                NUM=50;    DEN=1;    LABEL=50 ;;
    59.94|5994)        NUM=60000; DEN=1001; LABEL=5994 ;;
    60)                NUM=60;    DEN=1;    LABEL=60 ;;
    *) echo "unsupported frame rate: $RATE" >&2; exit 2 ;;
  esac
  FPS_RATIONAL="${NUM}/${DEN}"
  FPS_DEC=$(python3 -c "print(round($NUM/$DEN, 3))")
  # Whole-frame event grid.
  F0=$(python3 -c "print(round($LEAD_IN_S*$NUM/$DEN))")
  P=$(python3 -c "print(round($PERIOD_S*$NUM/$DEN))")
  # 2 white frames at <= 30 fps (67-83 ms), 3 at >= 50 fps (50-60 ms).
  FLASH_FRAMES=$(python3 -c "print(2 if $NUM/$DEN <= 31 else 3)")
  BASENAME="avsync_${H}p${LABEL}"

  # Video: frame-number based timeline so the flash lands on exact frames.
  EVENT_EXPR="gte(n,${F0})*lt(mod(n-${F0},${P}),${FLASH_FRAMES})"
  VF=""
  if [ -n "$FONT" ]; then
    VF="drawtext=fontfile='${FONT}':fontcolor=0x404040:fontsize=$((H/18)):x=(w-text_w)/2:y=(h-text_h)/2:text='AV SYNC TEST ${FPS_DEC}  %{eif\:max(0\,floor((n-${F0})/${P})+1)\:d}',"
    VF="${VF}drawtext=fontfile='${FONT}':fontcolor=0x303030:fontsize=$((H/36)):x=(w-text_w)/2:y=(h/2+h/12):text='flash + ${TONE_HZ} Hz beep every ${P} frames',"
  fi
  VF="${VF}drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='${EVENT_EXPR}'"

  # Audio: position in frames pf = t*fps - F0; seconds since the current event ph.
  PF="(t*${NUM}/${DEN}-${F0})"
  PH="(mod(${PF},${P})*${DEN}/${NUM})"
  AEXPR="if(gte(${PF},0)*lt(${PH},${TONE_S}), ${TONE_AMP}*sin(2*PI*${TONE_HZ}*t)*min(1,${PH}/${RAMP_S})*min(1,(${TONE_S}-${PH})/${RAMP_S}), 0)"

  common=(
    -f lavfi -i "color=c=black:s=${W}x${H}:r=${FPS_RATIONAL}:d=${DURATION}"
    -f lavfi -i "aevalsrc='${AEXPR}':s=${SR}:c=stereo:d=${DURATION}"
    -vf "$VF"
    -shortest
  )

  echo "[$RATE fps] F0=${F0} frames, period=${P} frames, flash=${FLASH_FRAMES} frames -> ${OUT_DIR}/${BASENAME}.mp4"
  ffmpeg -y -hide_banner -loglevel error "${common[@]}" \
    -c:v libx264 -preset medium -crf 16 -pix_fmt yuv420p -g "$P" -r "$FPS_RATIONAL" \
    -c:a aac -b:a 192k -ar "$SR" \
    -movflags +faststart \
    "${OUT_DIR}/${BASENAME}.mp4"

  if [ "$WRITE_MXF" = "1" ]; then
    echo "[$RATE fps] DNxHR LB + 24-bit PCM -> ${OUT_DIR}/${BASENAME}_dnxhr.mxf"
    ffmpeg -y -hide_banner -loglevel error "${common[@]}" \
      -c:v dnxhd -profile:v dnxhr_lb -pix_fmt yuv422p -r "$FPS_RATIONAL" \
      -c:a pcm_s24le -ar "$SR" \
      -f mxf "${OUT_DIR}/${BASENAME}_dnxhr.mxf"
  fi
done

ls -la "$OUT_DIR"
