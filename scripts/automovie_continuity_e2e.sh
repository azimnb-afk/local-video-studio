#!/bin/bash
# Real end-to-end Auto Movie continuity smoke test.
#
# Mirrors the production pipeline without the GUI:
#   shot 1 (text-to-video)
#     -> last usable frame extracted exactly as ContinuityFrameExtractor does
#   shot 2 (image-to-video, starting from that frame)
#     -> last frame again
#   shot 3 (image-to-video)
#     -> FinalAssemblyService-equivalent concat into one movie
#
# Generation goes through the same `mlx_video.generate_av` CLI the app's
# LTXBridge invokes, with HF_HUB_OFFLINE=1 so nothing is downloaded.
#
# Usage: ./scripts/automovie_continuity_e2e.sh [outdir]
set -euo pipefail

OUTDIR="${1:-/tmp/ltx_automovie_e2e}"
# Calibrated continuity strength (AutoMovieRunCoordinator.continuityImageStrength).
CONT_STRENGTH="${LTX_CONTINUITY_STRENGTH:-0.8}"
PYTHON="${LTX_PYTHON:-$HOME/ltx-venv/bin/python3}"
MODEL_REPO="${LTX_MODEL_REPO:-notapalindrome/ltx23-mlx-av-q4}"
ENCODER_REPO="${LTX_ENCODER_REPO:-mlx-community/gemma-3-12b-it-4bit}"
W=512; H=320; FRAMES=25; STEPS=15; FPS=24; CFG=3.0
mkdir -p "$OUTDIR"
SUMMARY="$OUTDIR/summary.txt"
: > "$SUMMARY"

log() { echo "$@" | tee -a "$SUMMARY"; }

# Same three-strategy tail seek as ContinuityFrameExtractor.
extract_last_frame() {
  local video="$1" out="$2"
  local duration tail_offset abs_seek
  duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$video")
  tail_offset=$(python3 -c "d=$duration; print(f'{min(0.2, max(d/4, 0.04)):.3f}')")
  abs_seek=$(python3 -c "d=$duration; t=min(0.2, max(d/4,0.04)); print(f'{max(0,d-t):.3f}')")
  rm -f "$out"
  ffmpeg -y -sseof "-$tail_offset" -i "$video" -frames:v 1 -q:v 2 -update 1 "$out" >/dev/null 2>&1 || true
  if [ ! -s "$out" ]; then
    ffmpeg -y -ss "$abs_seek" -i "$video" -frames:v 1 -q:v 2 -update 1 "$out" >/dev/null 2>&1 || true
  fi
  [ -s "$out" ]
}

generate() {
  local label="$1" prompt="$2" image="${3:-}"
  local out="$OUTDIR/${label}.mp4" logf="$OUTDIR/${label}.log"
  local args=(--prompt "$prompt" --height "$H" --width "$W" --num-frames "$FRAMES"
              --seed 42 --fps "$FPS" --steps "$STEPS" --cfg-scale "$CFG"
              --output-path "$out" --model-repo "$MODEL_REPO"
              --text-encoder-repo "$ENCODER_REPO" --tiling auto --no-audio)
  if [ -n "$image" ]; then
    args+=(--image "$image" --image-strength "$CONT_STRENGTH")
    log "[$label] image-to-video, starting frame: $(basename "$image") (continuity strength $CONT_STRENGTH)"
  else
    log "[$label] text-to-video (no starting frame)"
  fi
  local start end
  start=$(date +%s)
  HF_HUB_OFFLINE=1 "$PYTHON" -m mlx_video.generate_av "${args[@]}" >"$logf" 2>&1
  end=$(date +%s)
  log "[$label] rendered in $((end-start))s -> $(basename "$out")"
}

log "=== Auto Movie continuity E2E ($(date)) ==="
log "profile: ${W}x${H}, ${FRAMES}f @ ${FPS}fps, ${STEPS} steps, audio off"

# Shot 1: establishing, no inherited frame (always a cut).
generate shot1 "A young woman in a dark coat walks toward an old stone library, soft overcast daylight, cinematic, steady camera."

# Shot 2: CONTINUE from shot 1's final frame.
extract_last_frame "$OUTDIR/shot1.mp4" "$OUTDIR/shot1-end.png" \
  || { log "FAIL: could not extract shot 1 final frame"; exit 1; }
log "[continuity] shot1 -> shot2 frame extracted ($(stat -f%z "$OUTDIR/shot1-end.png") bytes)"
generate shot2 "The same woman reaches the library entrance and slows down in front of the heavy wooden door, cinematic, steady camera." \
  "$OUTDIR/shot1-end.png"

# Shot 3: CONTINUE from shot 2's final frame.
extract_last_frame "$OUTDIR/shot2.mp4" "$OUTDIR/shot2-end.png" \
  || { log "FAIL: could not extract shot 2 final frame"; exit 1; }
log "[continuity] shot2 -> shot3 frame extracted ($(stat -f%z "$OUTDIR/shot2-end.png") bytes)"
generate shot3 "She pulls the wooden door open and steps inside the library, cinematic, steady camera." \
  "$OUTDIR/shot2-end.png"

# Final assembly: stream copy when compatible, exactly like FinalAssemblyService.
LIST="$OUTDIR/concat.txt"
: > "$LIST"
for s in shot1 shot2 shot3; do echo "file '$OUTDIR/$s.mp4'" >> "$LIST"; done
FINAL="$OUTDIR/auto_movie_final.mp4"
ffmpeg -y -f concat -safe 0 -i "$LIST" -c copy "$FINAL" >"$OUTDIR/assemble.log" 2>&1
log "[assembly] concatenated 3 shots -> $(basename "$FINAL")"

log ""
log "=== Results ==="
for s in shot1 shot2 shot3; do
  log "$s: $(ffprobe -v error -show_entries stream=width,height -show_entries format=duration -of csv=p=0 "$OUTDIR/$s.mp4" | tr '\n' ' ')"
done
log "final: $(ffprobe -v error -show_entries stream=width,height,codec_name -show_entries format=duration -of csv=p=0 "$FINAL" | tr '\n' ' ')"
log "final playable: $([ -s "$FINAL" ] && echo yes || echo no)"
log "=== done ==="
