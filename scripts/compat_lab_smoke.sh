#!/bin/bash
# Compatibility Lab runtime smoke test for a derived model.
# Runs the SAME CLI the app uses (mlx_video.generate_av) against an already
# installed local snapshot. Never downloads: HF_HUB_OFFLINE=1 is enforced, so
# a cache miss fails fast instead of fetching tens of GB.
#
# Usage:
#   ./scripts/compat_lab_smoke.sh <model-repo> [t2v|i2v|audio]
# Example:
#   ./scripts/compat_lab_smoke.sh MLXBits/ltx-2.3-10eros-v1.2-mlx-q8 t2v
#
# Record outcomes in the app's Compatibility Lab (docs/implementation/MODEL_COMPATIBILITY.md
# and Application Support/LTXVideoGenerator/compat_lab.json via the app).
set -euo pipefail

REPO="${1:?model repo required}"
MODE="${2:-t2v}"
PYTHON="${LTX_PYTHON:-$HOME/ltx-venv/bin/python3}"
ENCODER_REPO="${LTX_ENCODER_REPO:-mlx-community/gemma-3-12b-it-4bit}"
OUTDIR="/tmp/ltx_compat_lab"
mkdir -p "$OUTDIR"
SAFE_REPO="${REPO//\//_}"
OUT="$OUTDIR/${SAFE_REPO}_${MODE}.mp4"
LOG="$OUTDIR/${SAFE_REPO}_${MODE}.log"

ARGS=(--prompt "A person walks through a doorway into a sunlit room, natural motion, cinematic."
  --height 320 --width 512 --num-frames 25 --seed 42 --fps 24 --steps 15 --cfg-scale 3.0
  --output-path "$OUT" --model-repo "$REPO" --text-encoder-repo "$ENCODER_REPO" --tiling auto)

case "$MODE" in
  t2v) ;;
  i2v)
    IMG="$OUTDIR/i2v_source.png"
    [ -f "$IMG" ] || ffmpeg -y -f lavfi -i testsrc=size=512x320:duration=1 -frames:v 1 "$IMG" >/dev/null 2>&1
    ARGS+=(--image "$IMG" --image-strength 1.0)
    ;;
  audio) ;; # audio is on by default; t2v mode with audio verification below
  *) echo "unknown mode: $MODE"; exit 2 ;;
esac
[ "$MODE" = "audio" ] || ARGS+=(--no-audio)

echo "=== compat lab: $REPO ($MODE) ===" | tee "$LOG"
START=$(date +%s)
if HF_HUB_OFFLINE=1 /usr/bin/time -l "$PYTHON" -m mlx_video.generate_av "${ARGS[@]}" >>"$LOG" 2>&1; then
  STATUS=passed
else
  STATUS=failed
fi
END=$(date +%s)
echo "wall_seconds: $((END-START))" | tee -a "$LOG"
grep -E "peak memory footprint" "$LOG" | tail -1 || true
if [ "$STATUS" = passed ] && [ -f "$OUT" ]; then
  ffprobe -v error -show_entries stream=codec_name,codec_type,width,height -of default=noprint_wrappers=1 "$OUT" | tee -a "$LOG"
fi
echo "check_result: $STATUS" | tee -a "$LOG"
[ "$STATUS" = passed ]
