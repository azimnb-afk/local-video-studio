#!/bin/bash
# Continuity image-strength calibration for Auto Movie.
#
# Isolates the effect of image strength on a SINGLE shot transition: one source
# frame, one prompt, one seed, one set of render settings — only
# --image-strength changes between candidates.
#
# Backend semantics (verified in mlx_video/conditioning/latent.py):
#   denoise_mask = 1.0 - strength
#   output       = denoised * mask + clean_image_latent * (1 - mask)
# so strength 1.0 pins the first frame to the source image exactly, and lower
# values give the model freedom to recompose.
#
# Usage: ./scripts/continuity_strength_calibration.sh [source.png] [outdir] [strengths...]
set -euo pipefail

SOURCE="${1:-/tmp/ltx_automovie_e2e/shot1-end.png}"
OUTDIR="${2:-/tmp/ltx_strength_calib}"
shift 2 2>/dev/null || true
STRENGTHS=("$@")
[ ${#STRENGTHS[@]} -eq 0 ] && STRENGTHS=(1.0 0.8 0.6 0.4)

PYTHON="${LTX_PYTHON:-$HOME/ltx-venv/bin/python3}"
MODEL_REPO="${LTX_MODEL_REPO:-notapalindrome/ltx23-mlx-av-q4}"
ENCODER_REPO="${LTX_ENCODER_REPO:-mlx-community/gemma-3-12b-it-4bit}"
W=512; H=320; FRAMES=25; STEPS=15; FPS=24; CFG=3.0; SEED=42

PROMPT="The same woman continues toward the entrance of the same old stone library. The camera moves closer into a medium shot. She reaches the doorway and raises her hand toward the door handle."

mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"
: > "$SUMMARY"
log() { echo "$@" | tee -a "$SUMMARY"; }

[ -f "$SOURCE" ] || { log "FAIL: source frame missing: $SOURCE"; exit 1; }

log "=== Continuity strength calibration ($(date)) ==="
log "source frame: $SOURCE"
log "prompt: $PROMPT"
log "fixed: ${W}x${H}, ${FRAMES}f @ ${FPS}fps, ${STEPS} steps, cfg ${CFG}, seed ${SEED}, audio off"
log "variable: --image-strength only"
log ""

for s in "${STRENGTHS[@]}"; do
  label="strength_${s}"
  out="$OUTDIR/${label}.mp4"
  logf="$OUTDIR/${label}.log"
  start=$(date +%s)
  if HF_HUB_OFFLINE=1 "$PYTHON" -m mlx_video.generate_av \
      --prompt "$PROMPT" --height "$H" --width "$W" --num-frames "$FRAMES" \
      --seed "$SEED" --fps "$FPS" --steps "$STEPS" --cfg-scale "$CFG" \
      --output-path "$out" --model-repo "$MODEL_REPO" \
      --text-encoder-repo "$ENCODER_REPO" --tiling auto --no-audio \
      --image "$SOURCE" --image-strength "$s" >"$logf" 2>&1; then
    end=$(date +%s)
    log "[strength $s] rendered in $((end-start))s"
  else
    log "[strength $s] FAILED (see $logf)"
    continue
  fi
  # first / middle / last frames for visual comparison
  ffmpeg -y -i "$out" -frames:v 1 -q:v 2 -update 1 "$OUTDIR/${label}-first.png" >/dev/null 2>&1 || true
  ffmpeg -y -ss 0.5 -i "$out" -frames:v 1 -q:v 2 -update 1 "$OUTDIR/${label}-mid.png" >/dev/null 2>&1 || true
  ffmpeg -y -ss 0.9 -i "$out" -frames:v 1 -q:v 2 -update 1 "$OUTDIR/${label}-last.png" >/dev/null 2>&1 || true
done

# Contact sheet: one row per strength (first | middle | last), source frame on top.
ROWS=(); INPUTS=(); idx=0
INPUTS+=(-i "$SOURCE"); SRC_IDX=$idx; idx=$((idx+1))
FILTER=""
ROW_LABELS=()
for s in "${STRENGTHS[@]}"; do
  label="strength_${s}"
  [ -f "$OUTDIR/${label}-first.png" ] || continue
  INPUTS+=(-i "$OUTDIR/${label}-first.png" -i "$OUTDIR/${label}-mid.png" -i "$OUTDIR/${label}-last.png")
  FILTER+="[$idx][$((idx+1))][$((idx+2))]hstack=inputs=3[row${#ROWS[@]}];"
  ROWS+=("[row${#ROWS[@]}]")
  ROW_LABELS+=("$s")
  idx=$((idx+3))
done
if [ ${#ROWS[@]} -gt 0 ]; then
  FILTER+="[$SRC_IDX]scale=${W}:${H},pad=$((W*3)):${H}:0:0:color=black[srcrow];"
  FILTER+="[srcrow]${ROWS[*]}vstack=inputs=$(( ${#ROWS[@]} + 1 ))[sheet]"
  FILTER="${FILTER//][/][}"
  ffmpeg -y "${INPUTS[@]}" -filter_complex "$FILTER" -map "[sheet]" "$OUTDIR/strength_sheet.png" >/dev/null 2>&1 \
    && log "" && log "contact sheet: $OUTDIR/strength_sheet.png (top row = source frame; then one row per strength: first | middle | last)" \
    || log "contact sheet build failed (individual PNGs are still available)"
  log "row order: source, $(IFS=,; echo "${ROW_LABELS[*]}")"
fi
log "=== done ==="
