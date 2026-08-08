# BENCHMARK_RESULTS

Hardware signature: Mac16,11 / M4 Pro / 48GB / macOS 26.5.2 — class: Measured. Other RAM tiers: Hypothesis only (no hardware).

## Phase 0 baseline — Measured 2026-08-08
Profile: 512x320, 25 frames, 15 steps, 24 fps, seed 42, cfg 3.0, model ltx23_distilled_q4 (notapalindrome/ltx23-mlx-av-q4), text encoder gemma-3-12b-it-4bit, tiling auto, HF_HUB_OFFLINE=1 (no network egress during render — verified generation succeeds fully offline).

| Run | Audio | Wall | Peak footprint | Swap delta | ffprobe actual | Status |
|---|---|---|---|---|---|---|
| T2V-A-ON | ON | 49 s | 23.66 GB | none (7484M→7484M) | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| T2V-A-OFF | OFF | 46 s | 17.23 GB | −405 M | 512x320 h264 24fps, 1.04 s | OK |
| I2V-A-ON | ON | 48 s | 23.66 GB | none | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| I2V-A-OFF | OFF | (see log) | (see log) | | | measured after checkpoint |

Notes:
- Audio pipeline adds ~6.4 GB peak footprint (23.66 vs 17.23 GB) at this profile.
- 25 frames @ 24fps yields 1.01–1.04 s actual duration (ffprobe = source of truth).
- Logs + MP4s: /tmp/ltx_baseline/ (regenerate any time with scripts/benchmark_baseline.sh).

## Regression acceptance
Post-change official-path runs must stay within 1.05x of: wall 49 s (audio ON) / 46 s (audio OFF); peak 23.66 / 17.23 GB; identical actual resolution/fps/duration/audio streams.
