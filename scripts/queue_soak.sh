#!/bin/bash
# Queue soak test: N sequential generations (default 20) with per-run peak
# memory, comparing run 1 vs run N for monotonic growth. Sequentiality is
# inherent: runs execute one after another, exactly like the app's
# single-flight queue (concurrent LTX processes <= 1 by construction).
#
# Usage: ./scripts/queue_soak.sh [count]     # full run ≈ count × ~50s
set -euo pipefail

COUNT="${1:-20}"
PYTHON="${LTX_PYTHON:-$HOME/ltx-venv/bin/python3}"
MODEL_REPO="${LTX_MODEL_REPO:-notapalindrome/ltx23-mlx-av-q4}"
ENCODER_REPO="${LTX_ENCODER_REPO:-mlx-community/gemma-3-12b-it-4bit}"
OUTDIR="/tmp/ltx_queue_soak"
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.tsv"
echo -e "take\tseed\twall_s\tpeak_bytes\tstatus" > "$SUMMARY"

for i in $(seq 1 "$COUNT"); do
  SEED=$((1000 + i))
  OUT="$OUTDIR/take_${i}.mp4"
  LOG="$OUTDIR/take_${i}.log"
  START=$(date +%s)
  if HF_HUB_OFFLINE=1 /usr/bin/time -l "$PYTHON" -m mlx_video.generate_av \
      --prompt "A small red fox walks slowly through a snowy forest clearing, cinematic." \
      --height 320 --width 512 --num-frames 25 --seed "$SEED" --fps 24 \
      --steps 15 --cfg-scale 3.0 --output-path "$OUT" \
      --model-repo "$MODEL_REPO" --text-encoder-repo "$ENCODER_REPO" \
      --tiling auto --no-audio >"$LOG" 2>&1; then
    STATUS=ok
  else
    STATUS=fail
  fi
  END=$(date +%s)
  PEAK=$(grep -Eo '[0-9]+  peak memory footprint' "$LOG" | awk '{print $1}' | tail -1)
  echo -e "${i}\t${SEED}\t$((END-START))\t${PEAK:-0}\t${STATUS}" | tee -a "$SUMMARY"
  rm -f "$OUT"   # keep disk usage flat during the soak
done

echo ""
echo "=== Soak summary ==="
column -t "$SUMMARY"
FIRST=$(awk 'NR==2 {print $4}' "$SUMMARY")
LAST=$(awk 'END {print $4}' "$SUMMARY")
echo ""
echo "peak run1=${FIRST} runN=${LAST}"
awk -v f="$FIRST" -v l="$LAST" 'BEGIN {
  if (f > 0 && l > f * 1.10) { print "WARN: peak memory grew >10% across the soak"; exit 1 }
  else { print "OK: no significant peak-memory growth (each run is its own subprocess)" }
}'
