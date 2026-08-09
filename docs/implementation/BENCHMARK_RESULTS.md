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

## Auto Movie continuity chain — real LTX run (2026-08-10)

Harness: `scripts/automovie_continuity_e2e.sh` (M4 Pro / 48 GB, ltx23_distilled_q4
+ gemma-3-12b-4bit, 512×320 / 25f / 15 steps / 24fps, audio off, `HF_HUB_OFFLINE=1`).
Brief: a woman approaches an old stone library, reaches the entrance, opens the
door and steps inside — shot 1 text-to-video, shots 2 and 3 continuing from the
previous shot's final frame.

| Step | Result |
|---|---|
| Shot 1 (T2V) | 45 s → 512×320, 1.04 s |
| Shot 1 → 2 frame extraction | 185,845-byte PNG |
| Shot 2 (I2V from inherited frame) | 44 s → 512×320, 1.04 s |
| Shot 2 → 3 frame extraction | 182,035-byte PNG |
| Shot 3 (I2V from inherited frame) | 44 s → 512×320, 1.04 s |
| Final assembly (stream copy) | h264 512×320, **3.125 s**, playable |

Sequential throughout; one generation at a time.

### Observed continuity (honest assessment)
- **Building / set: strongly preserved.** The same stone facade, red-brown
  doors, window rhythm and background spire persist across all three shots.
- **Lighting and colour: preserved.** Consistent overcast palette.
- **Wardrobe and general figure: preserved.** Dark coat and long light hair
  stay consistent.
- **Hand-off is real.** Each continuing shot's first frame matches the previous
  shot's final frame, confirming the inherited image reached the renderer.
- **Identity: not verifiable and not claimed.** The face is small and
  motion-blurred at this resolution. This mechanism is a visual anchor, not
  identity conditioning; the same person is never guaranteed.
- **Composition leakage is real and significant.** Camera angle and framing
  stayed essentially locked across all three shots, and the narrative beats did
  not progress: the subject kept walking along the same facade instead of
  reaching the entrance and entering. With `imageStrength = 1.0` the inherited
  frame dominates the prompt.

### Consequences
1. Chaining every shot would be wrong; this run is direct evidence for the
   `cut`-by-default rule (D-029). Scene changes and establishing shots must cut.
2. Continuous action across a chained shot needs either a lower image strength
   or fewer chained shots in a row. Exposing per-shot continuity strength is a
   sensible follow-up, deliberately **not** implemented here.
3. Continuity quality should be described as *improved visual continuity*, never
   as guaranteed identity or guaranteed scene progression.

Evidence: `/tmp/ltx_automovie_e2e/` (per-shot MP4s, extracted frames,
`continuity_sheet.png` comparing each shot's first and last frame, and
`auto_movie_final.mp4`).
