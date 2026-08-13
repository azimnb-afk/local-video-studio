#!/bin/bash
# Compatibility Lab runtime smoke test for a derived model.
# Runs the SAME CLI the app uses (mlx_video.generate_av) against an already
# installed local snapshot. Never downloads: HF_HUB_OFFLINE=1 is enforced, so
# a cache miss fails fast instead of fetching tens of GB.
#
# Usage:
#   ./scripts/compat_lab_smoke.sh <model-repo> [t2v|i2v|audio]
#
# Backend: models packaged for ltx-2-mlx (10Eros) are run through that CLI
# instead of mlx_video.generate_av. Set LTX2MLX_BIN to its executable. The
# backend is chosen by the model repo, the same way the app routes it —
# a smoke test that exercised a different runtime than production would
# verify nothing.
# Example:
#   ./scripts/compat_lab_smoke.sh MLXBits/ltx-2.3-10eros-v1.2-mlx-q8 t2v
#
# Record outcomes in the app's Compatibility Lab documentation
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

# Route by model, mirroring GenerationModelResolver.
case "$REPO" in
  *10eros*) BACKEND=ltx2mlx ;;
  *)        BACKEND=mlxvideo ;;
esac

if [ "$BACKEND" = ltx2mlx ]; then
  LTX2MLX_BIN="${LTX2MLX_BIN:?ltx-2-mlx executable required for this model (set LTX2MLX_BIN)}"
  # Resolve the local snapshot: this CLI takes a directory, and offline mode
  # means a cache miss must fail rather than pull tens of GB.
  SNAP=$(ls -d "$HOME/.cache/huggingface/hub/models--${REPO//\//--}/snapshots/"*/ 2>/dev/null | head -1)
  [ -n "$SNAP" ] || { echo "no local snapshot for $REPO" | tee -a "$LOG"; exit 1; }
  ARGS=(generate --model "$SNAP" --prompt "A person walks through a doorway into a sunlit room, natural motion, cinematic."
    --height 320 --width 512 --frames 25 --frame-rate 24 --seed 42 --distilled --output "$OUT")
  [ "$MODE" != i2v ] || ARGS+=(--image "$IMG")
fi

echo "=== compat lab: $REPO ($MODE) via $BACKEND ===" | tee "$LOG"
START=$(date +%s)
if [ "$BACKEND" = ltx2mlx ]; then
  RUNNER=("$LTX2MLX_BIN")
else
  RUNNER=("$PYTHON" -m mlx_video.generate_av)
fi
if HF_HUB_OFFLINE=1 /usr/bin/time -l "${RUNNER[@]}" "${ARGS[@]}" >>"$LOG" 2>&1; then
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
