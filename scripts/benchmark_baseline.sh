#!/bin/bash
# Phase 0 baseline benchmark harness.
# Reproduces the exact CLI GenerationService/LTXBridge builds for the official
# fast path and records wall time, peak RSS, swap, and ffprobe of the real MP4.
#
# Usage:
#   ./scripts/benchmark_baseline.sh <label> [--no-audio] [--image <path>]
# Example:
#   ./scripts/benchmark_baseline.sh T2V-A-ON
#   ./scripts/benchmark_baseline.sh T2V-A-OFF --no-audio
set -euo pipefail

LABEL="${1:?label required}"; shift || true
PYTHON="${LTX_PYTHON:-$HOME/ltx-venv/bin/python3}"
MODEL_REPO="${LTX_MODEL_REPO:-notapalindrome/ltx23-mlx-av-q4}"
ENCODER_REPO="${LTX_ENCODER_REPO:-mlx-community/gemma-3-12b-it-4bit}"
OUTDIR="${LTX_BENCH_OUTDIR:-/tmp/ltx_baseline}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/${LABEL}.mp4"
LOG="$OUTDIR/${LABEL}.log"

PROMPT="A small red fox walks slowly through a snowy forest clearing, soft morning light, gentle camera pan, cinematic."
WIDTH=512; HEIGHT=320; FRAMES=25; STEPS=15; FPS=24; SEED=42; CFG=3.0

CMD=("$PYTHON" -m mlx_video.generate_av
  --prompt "$PROMPT"
  --height "$HEIGHT" --width "$WIDTH"
  --num-frames "$FRAMES" --seed "$SEED" --fps "$FPS"
  --steps "$STEPS" --cfg-scale "$CFG"
  --output-path "$OUT"
  --model-repo "$MODEL_REPO"
  --text-encoder-repo "$ENCODER_REPO"
  --tiling auto)
CMD+=("$@")

echo "=== $LABEL ===" | tee "$LOG"
echo "swap before: $(sysctl -n vm.swapusage)" | tee -a "$LOG"
START=$(date +%s)
# HF_HUB_OFFLINE=1: render must not hit the network (models already cached).
if HF_HUB_OFFLINE=1 /usr/bin/time -l "${CMD[@]}" >>"$LOG" 2>&1; then
  STATUS=ok
else
  STATUS=fail
fi
END=$(date +%s)
echo "wall_seconds: $((END-START))" | tee -a "$LOG"
echo "swap after: $(sysctl -n vm.swapusage)" | tee -a "$LOG"
echo "peak RSS (from time -l):" | tee -a "$LOG"
grep -E "maximum resident set size" "$LOG" | tail -1 || true
if [ "$STATUS" = ok ] && [ -f "$OUT" ]; then
  echo "--- ffprobe ---" | tee -a "$LOG"
  ffprobe -v error -show_entries stream=codec_name,codec_type,width,height,r_frame_rate,sample_rate,channels \
    -show_entries format=duration,bit_rate -of default=noprint_wrappers=1 "$OUT" | tee -a "$LOG"
fi
echo "status: $STATUS" | tee -a "$LOG"
