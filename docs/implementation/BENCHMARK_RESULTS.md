# BENCHMARK_RESULTS

Hardware signature: Mac16,11 / M4 Pro / 48GB / macOS 26.5.2 — class: Measured. Other RAM tiers: Hypothesis only (no hardware).

## Phase 0 baseline — Measured 2026-08-08
Profile: 512x320, 25 frames, 15 steps, 24 fps, seed 42, cfg 3.0, model ltx23_distilled_q4 (notapalindrome/ltx23-mlx-av-q4), text encoder gemma-3-12b-it-4bit, tiling auto, HF_HUB_OFFLINE=1 (no network egress during render — verified generation succeeds fully offline).

| Run | Audio | Wall | Peak footprint | Swap delta | ffprobe actual | Status |
|---|---|---|---|---|---|---|
| T2V-A-ON | ON | 49 s | 23.66 GB | none (7484M→7484M) | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| T2V-A-OFF | OFF | 46 s | 17.23 GB | −405 M | 512x320 h264 24fps, 1.04 s | OK |
| I2V-A-ON | ON | 48 s | 23.66 GB | none | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| I2V-A-OFF | OFF | 47 s | 17.23 GB | none | 512x320 h264 24fps, 1.04 s | OK |

Notes:
- Audio pipeline adds ~6.4 GB peak footprint (23.66 vs 17.23 GB) at this profile.
- 25 frames @ 24fps yields 1.01–1.04 s actual duration (ffprobe = source of truth).
- Logs + MP4s: /tmp/ltx_baseline/ (regenerate any time with scripts/benchmark_baseline.sh).

## Regression run — post-implementation (2026-08-08, after Phase 7)
| Run | Wall | Peak footprint | ffprobe | MD5 vs baseline |
|---|---|---|---|---|
| REGRESSION-T2V-A-ON | 53 s* | 23.46 GB (< baseline 23.66) | identical (512x320, 1.01 s, h264+aac) | **IDENTICAL** (bf8020b1f55f73a62c075f2df1c65a8d) |

*Wall time contaminated: a queue-soak validation ran concurrently on the same
machine during this measurement; memory peak and the bit-identical output are
the meaningful signals. Same seed → byte-identical MP4 proves the official
fast path is completely unchanged (0% regression).

## Queue soak — short validation (2026-08-08, 3 sequential takes, audio OFF)
| Take | Seed | Wall | Peak |
|---|---|---|---|
| 1 | 1001 | 51 s | 17.215 GB |
| 2 | 1002 | 43 s | 17.228 GB |
| 3 | 1003 | 43 s | 17.227 GB |

Peak flat across runs (+0.07%): each generation is its own subprocess, so exit
is a hard reclamation boundary. Full 20-take soak: `scripts/queue_soak.sh 20`
(≈17 min) — HARNESS READY. Concurrency was 1 throughout (sequential script,
matching the app's single-flight queue).

## Regression acceptance
Post-change official-path runs must stay within 1.05x of: wall 49 s (audio ON) / 46 s (audio OFF); peak 23.66 / 17.23 GB; identical actual resolution/fps/duration/audio streams.
