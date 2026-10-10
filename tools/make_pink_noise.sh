#!/usr/bin/env bash
# Pink-noise speaker-level sequence as a multichannel 24-bit WAV (CLI twin of the Mac app's
# Pink noise tab; same channel order as the iOS Levels tab).
#
# Each channel in turn plays pink noise at LEVEL dBFS RMS for SEGMENT seconds, with GAP seconds
# of silence between channels, after a LEAD_IN of silence. LFE is low-passed at 120 Hz.
#
# Usage: tools/make_pink_noise.sh [-o out_dir] [-s segment_s] [-g gap_s] [-l level_dbfs] [-r repeats] [-a] layout
#   layout: stereo | 3.1 | 5.1 | 7.1       -a adds a final all-channels segment
set -euo pipefail

OUT_DIR="."; SEGMENT=10; GAP=1; LEVEL=-20; REPEATS=1; ALL=0; LEAD_IN=2; SR=48000
while getopts "o:s:g:l:r:a" opt; do
  case $opt in
    o) OUT_DIR="$OPTARG" ;; s) SEGMENT="$OPTARG" ;; g) GAP="$OPTARG" ;; l) LEVEL="$OPTARG" ;;
    r) REPEATS="$OPTARG" ;; a) ALL=1 ;; *) echo "bad option" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
LAYOUT="${1:-5.1}"

# Channel order (ours) -> ffmpeg channel names and layout string.
case "$LAYOUT" in
  stereo) NAMES=(L R);                    FF=(FL FR);                        FFLAYOUT="stereo";   TAG=stereo ;;
  3.1)    NAMES=(L R C LFE);              FF=(FL FR FC LFE);                 FFLAYOUT="3.1";      TAG=3_1 ;;
  5.1)    NAMES=(L R C LFE Ls Rs);        FF=(FL FR FC LFE BL BR);           FFLAYOUT="5.1";      TAG=5_1 ;;
  7.1)    NAMES=(L R C LFE Ls Rs Lrs Rrs); FF=(FL FR FC LFE SL SR BL BR);    FFLAYOUT="7.1";      TAG=7_1 ;;
  *) echo "unknown layout $LAYOUT" >&2; exit 2 ;;
esac
N=${#NAMES[@]}
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/pink_${TAG}_$(( -LEVEL ))db_${SEGMENT}s.wav"

# Measure ffmpeg's pink RMS once (a=1), so we can hit LEVEL dBFS RMS exactly.
RMS_DB=$(ffmpeg -hide_banner -f lavfi -i "anoisesrc=color=pink:r=${SR}:a=1:seed=1:d=5" -af astats=measure_overall=RMS_level:measure_perchannel=none -f null - 2>&1 | sed -n 's/.*RMS level dB: \([-0-9.]*\).*/\1/p' | tail -n 1)
LFE_RMS_DB=$(ffmpeg -hide_banner -f lavfi -i "anoisesrc=color=pink:r=${SR}:a=1:seed=1:d=5" -af "lowpass=f=120:p=2,astats=measure_overall=RMS_level:measure_perchannel=none" -f null - 2>&1 | sed -n 's/.*RMS level dB: \([-0-9.]*\).*/\1/p' | tail -n 1)
GAIN_DB=$(python3 -c "print(${LEVEL} - (${RMS_DB}))")
LFE_GAIN_DB=$(python3 -c "print(${LEVEL} - (${LFE_RMS_DB}))")

# Build the on/off schedule per channel.
TOTAL=$(python3 -c "print(${LEAD_IN} + ${REPEATS}*${N}*(${SEGMENT}+${GAP}) + (${SEGMENT}+${GAP} if ${ALL} else 0))")
INPUTS=(); FILTERS=""; MAPS=""
for ((i=0; i<N; i++)); do
  INPUTS+=(-f lavfi -i "anoisesrc=color=pink:r=${SR}:a=1:seed=$((i+1)):d=${TOTAL}")
  ON=""
  for ((rep=0; rep<REPEATS; rep++)); do
    START=$(python3 -c "print(${LEAD_IN} + (${rep}*${N}+${i})*(${SEGMENT}+${GAP}))")
    END=$(python3 -c "print(${START}+${SEGMENT})")
    ON="${ON}+between(t,${START},${END})"
  done
  if [ "$ALL" = "1" ]; then
    START=$(python3 -c "print(${LEAD_IN} + ${REPEATS}*${N}*(${SEGMENT}+${GAP}))")
    END=$(python3 -c "print(${START}+${SEGMENT})")
    ON="${ON}+between(t,${START},${END})"
  fi
  ON="${ON#+}"
  G="$GAIN_DB"; EXTRA=""
  if [ "${NAMES[$i]}" = "LFE" ]; then G="$LFE_GAIN_DB"; EXTRA="lowpass=f=120:p=2,"; fi
  FILTERS="${FILTERS}[${i}:a]${EXTRA}volume=${G}dB,volume=volume=0:enable='not(${ON})'[c${i}];"
  MAPS="${MAPS}${i}.0-${FF[$i]}|"
done
FILTERS="${FILTERS}$(for ((i=0; i<N; i++)); do printf '[c%d]' $i; done)join=inputs=${N}:channel_layout=${FFLAYOUT}:map=${MAPS%|}[out]"

echo "Writing $OUT (${LAYOUT}, ${N} channels, ${TOTAL%.*} s, ${LEVEL} dBFS RMS per channel)"
ffmpeg -y -hide_banner -loglevel error "${INPUTS[@]}" -filter_complex "$FILTERS" -map "[out]" -c:a pcm_s24le -ar "$SR" "$OUT"
ffprobe -v error -show_entries stream=channels,channel_layout,sample_rate,bits_per_raw_sample,duration -of compact "$OUT"
