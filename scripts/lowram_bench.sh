#!/bin/bash
# Low-RAM backend verification benchmark (dgrauet/ltx-2-mlx block streaming).
# Walks the Compact ladder C0 → C1 → C2 → audio, stopping at the first failure.
# Run this on the target (ideally 16GB) hardware; record results in
# documented benchmark results and only then set the
# lowRAMBackendVerified preference.
#
# Usage:
#   LTX2MLX_DIR=~/AI/LTX-MLX/ltx-2-mlx MODEL_DIR=~/AI/LTX-MLX/models/ltx-2.3-mlx-q8 \
#     ./scripts/lowram_bench.sh
set -euo pipefail

LTX2MLX_DIR="${LTX2MLX_DIR:-$HOME/AI/LTX-MLX/ltx-2-mlx}"
MODEL_DIR="${MODEL_DIR:-$HOME/AI/LTX-MLX/models/ltx-2.3-mlx-q8}"
OUTDIR="/tmp/ltx_lowram_bench"
mkdir -p "$OUTDIR"

if [ ! -d "$LTX2MLX_DIR" ]; then
  echo "ltx-2-mlx checkout not found at $LTX2MLX_DIR" >&2
  exit 2
fi

PROMPT="A small red fox walks slowly through a snowy forest clearing, soft morning light, cinematic."

run_profile() {
  local label="$1" frames="$2" audio="$3"
  local out="$OUTDIR/${label}.mp4" log="$OUTDIR/${label}.log"
  echo "=== $label (frames=$frames audio=$audio) ==="
  local args=(--prompt "$PROMPT" --width 512 --height 320 --num-frames "$frames"
              --fps 24 --seed 42 --low-ram --model-path "$MODEL_DIR" --output "$out")
  [ "$audio" = "off" ] && args+=(--no-audio)
  if (cd "$LTX2MLX_DIR" && HF_HUB_OFFLINE=1 /usr/bin/time -l uv run ltx2 "${args[@]}") >"$log" 2>&1; then
    echo "  PASS ($(grep -Eo '[0-9]+  peak memory footprint' "$log" | tail -1))"
    return 0
  else
    echo "  FAIL — see $log"
    return 1
  fi
}

run_profile C0 25 off || exit 1
run_profile C1 49 off || exit 1
run_profile C2 65 off || exit 1
run_profile C3-audio 49 on || exit 1
echo "All Compact ladder profiles passed. Record results in BENCHMARK_RESULTS.md."
