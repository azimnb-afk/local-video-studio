# CURRENT_STATE

Updated: 2026-08-08

## Current Phase
Phase 0 — Audit / Baseline (in progress)

## Completed
- Source acquisition: cloned `james-see/ltx-video-mac` (MIT) at `a441dc2` (main, post-2.3.65/2.3.66 changelog) into `/Users/azimnb/ltx23appdev/ltx-video-mac`. No local source existed anywhere on this machine (only the distributed DMG `LTXVideoGenerator-2.3.66.dmg`).
- Working branch: `director-extensions` (repo-local git identity azimnb / azimnb@gmail.com).
- Baseline = upstream `main` @ `a441dc2` — this is the Last Known Good Baseline commit.
- Phase 0 code audit (see BASELINE.md).

## In Progress
- SPM build harness (no full Xcode on this machine — CLT only).
- Baseline generation measurement.

## Next
- Phase 1: Official Model Registry + VideoGenerationAdapter + metadata migration.

## Build Status
- `xcodebuild` unavailable (Command Line Tools only, no Xcode.app). Swift 6.3.3 + macOS 26.5 SDK + swift-build available.
- Strategy: `Package.swift` SPM harness compiles app sources + unit tests. `.xcodeproj` untouched for Xcode users.

## Test Status
- Not yet run.

## Known Blockers
- Full Xcode not installed → cannot produce signed .app bundle here. SPM compile+test used instead. (Remaining Human Action: install Xcode for .app packaging.)

## Feature Flags
- None yet (Phase 1 adds FeatureFlags).

## Last Known Good Commit
- `a441dc2` (upstream main) = baseline.

## Environment (verified 2026-08-08)
- Mac16,11 / Apple M4 Pro / 48 GB unified memory / macOS 26.5.2
- ffmpeg + ffprobe: /opt/homebrew/bin
- Python: ~/ltx-venv/bin/python3 (3.14.5), mlx 0.32.0, mlx-video-with-audio 0.1.36, mlx-vlm 0.6.10, mlx-audio 0.4.7
- HF cache: notapalindrome/ltx23-mlx-av-q4 (20GB, default model) + gemma-3-12b-it-4bit (7.5GB, selected encoder) + gemma 12b bf16 / 4b bf16 cached
- App prefs (com.jamescampbell.ltxvideogenerator): pythonPath set, selectedTextEncoderID=gemma3_12b_4bit, useLocalMlxVideoRepo=1 (but ~/projects/mlx-video-with-audio does NOT exist → pip package is used)

## Exact Resume Action
Read this file, then `git log --oneline -10` in /Users/azimnb/ltx23appdev/ltx-video-mac, then continue with the phase listed under "Next".
