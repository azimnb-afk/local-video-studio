# CURRENT_STATE

Updated: 2026-08-08

## Current Phase
Preset/Quality propagation hardening complete — all production modes now resolve through one concrete settings boundary, with duration and fallback diagnostics preserved.

## Completed
- Source acquisition: cloned `james-see/ltx-video-mac` (MIT) @ `a441dc2` → branch `director-extensions`.
- Phase 0: audit + SPM build/test harness + measured baselines (BASELINE.md, BENCHMARK_RESULTS.md).
- Phase 1: ModelRegistry + VideoGenerationAdapter boundary + backward-compatible metadata + rollback-capable FeatureFlags.
- Phase 2: CompatibilityLab (11-check gate), ManifestValidator, ModelInstaller (no auto-download), Adult Mode + policy at Service/API layers, Preferences "Models & Features" tab.
- Phase 3: MemoryMonitor/HardwareProfiler/QualityProfile ladder/AutoQualityEngine/HistoricalSuccessStore, fallback retry (max 3), MediaProbe wiring, LowRAMMLXAdapter boundary (Runtime Verification Pending), lowram_bench.sh.
- Phase 4: One Shot Director (Ollama loopback provider + template fallback, terminate-before-render), OneShotPlan, PromptCompiler, DialogueNormalizer, UI disclosure.
- Phase 5: FilmProject/Shot/Take (1–20 sequential takes), versioned atomic persistence, resume reconciliation (real MP4 = truth).
- Phase 6: ContinuityEngine (deterministic directives + validator + monotony rules), StoryboardDirector (hybrid, sequential roles), FinalAssemblyService (stream-copy/normalize+concat) — verified against real MP4s.
- Phase 7: LocalAPIServer v1 (loopback + token + asset sandbox + policy), extras/openclaw.
- Regression: same-seed re-run produces **byte-identical MP4** to Phase 0 baseline (MD5 match).
- GUI completion: shared user-facing Preset (`Quick Preview / Standard / High Quality / Custom`) maps centrally to internal QualityMode (`Compact / Auto / High / Advanced`). Generate no longer exposes Quality as a primary picker; manual parameter edits select Custom.
- Storyboard Project Settings: Preset, Model, Audio plus Custom Resolution/Frames/FPS/Steps; requested/effective/actual metadata is visible and persisted per Take.
- Preview → Final workflow: changing Preset preserves project/shot/continuity state; per-shot and multi-shot regeneration append new Takes and keep previews; assembly still uses selected Takes and MediaProbe.
- Navigation: Generate / One Shot / Storyboard / Director / Hybrid are distinct production modes. Hybrid composes StoryboardDirector + continuity + FilmProject + sequential Take queue and deterministically splits template fallback into 4–6 second shots.
- Preset propagation fix: `GenerationSettingsResolver` is now the only preset/profile-to-render boundary used by Generate, One Shot, Storyboard, Hybrid, retakes, missing-take generation, REST and OpenClaw v1 requests.
- Duration precedence: profile supplies resolution/FPS/steps/audio; One Shot/Storyboard/Hybrid/API target duration recomputes 8n+1 frames at the resolved FPS; Custom preserves manual frames.
- Standard Auto policy: a lower-profile success alone no longer caps Standard. On 48 GB, Standard targets S0 while High remains H0; a real latest S0 failure can fall back to known-safe history with an explicit reason.
- Diagnostics: every render attempt logs final width/height/frames/FPS/steps/audio/target/model/seed; Result/Take/Archive preserve profile reason, source, target/requested duration and audio state.

## In Progress
- None. Safe local git checkpoint pending at the end of this task.

## Build Status
- `swift build` clean (final GUI implementation).
- **Xcode 26.6 installed (2026-08-08): `xcodebuild -scheme LTXVideoGenerator -configuration Debug` → BUILD SUCCEEDED.** Full .app bundle produced (arm64, ad-hoc signing via CLI overrides only — no project settings changed; deployment target 14.0, bundle id com.ltxvideo.generator). App launches and runs.

## Test Status
- `swift run LTXTests`: **331 checks, 0 failures** (see TEST_MATRIX.md).
- Final concrete comparison on Mac16,11/48 GB, same prompt/model/seed 4242/target 5 s/audio ON: Quick=C3 512×320/121f/24fps/15 steps; Standard=S0 768×512/121f/24fps/25 steps; High=H0 768×512/121f/24fps/30 steps.

## Known Blockers / Remaining Human Actions
1. ~~No Xcode.app~~ → RESOLVED: Xcode 26.6 installed; unsigned dev .app builds and runs. Remaining: Developer ID signing + notarization for distribution (needs credentials).
2. 10Eros weights not downloaded (user authorization required, tens of GB) → lab models stay verified=false. To verify: download weights, run scripts/compat_lab_smoke.sh, record checks in Compatibility Lab.
3. No 16GB hardware → LowRAM adapter Runtime Verification Pending; run scripts/lowram_bench.sh on a 16GB Mac (a dgrauet/ltx-2-mlx checkout already exists at ~/AI/LTX-MLX/ltx-2-mlx with a Q8 model).
4. Full 20-take queue soak (scripts/queue_soak.sh 20, ≈17 min) not yet run; 3-take validation done.
5. A fresh post-fix Quick/High render was not queued in this pass: the Debug app reported `MLX Environment Not Ready`, and the sandboxed Python probe could not access a Metal device. Mandatory final-request comparisons passed; existing real Quick/old-Standard/High outputs were inspected as the regression evidence.

## Feature Flags
GUI-first defaults (D-007): modelRegistryV1 / autoQualityV1 / directorV1 / filmProjectV1 / storyboardV1 = **ON** by default; derivedModelsV1 / adultModelsV1 / lowRAMAdapterV1 / localAPIv1 = OFF (opt-in). All OFF (Preferences → Models & Features) = byte-identical legacy behavior (proven by MD5-identical regression render). Quality defaults to "Advanced" (= manual parameters untouched).

## GUI (verified in the final running .app, 2026-08-08)
- Sidebar: Generate / One Shot / Storyboard / Director / Hybrid / Video Archive, with concise mode descriptions.
- Generate: Model + Preset picker; no primary Quality picker; non-Custom shows a preset explanation, Custom restores all legacy manual controls.
- One Shot: independent Brief / Preset / Model / Target Duration / Audio / Create & Generate screen.
- Storyboard: Project Settings, Custom resolution controls, Generate Missing, Regenerate Selected Shots, per-shot regeneration, append-only Take review/selection and Final Assembly.
- Hybrid: Brief / Preset / Model / Audio / Target Duration / Create & Generate sheet; automatic short-shot split and single-flight first-pass queue; same review/retake/assembly workspace.
- Video Archive: Requested / Effective / Actual (MP4) / Actual Length rows
- Video Archive inspection reproduced the bug before the fix: same prompt Quick C3 and Standard C3 were both 512×320/49f/15 steps (~70 s), while High H0 was 768×512/121f/30 steps (~275 s).
- One Shot now has its own persisted preset key; selecting Quick there leaves Generate on Standard. Non-Custom Generate no longer displays warnings from stale hidden manual FPS.
- Preferences → Models & Features: Adult Content Mode + all flags + Compatibility Lab status

## Last Known Good Commit
- Pre-fix checkpoint: `31a60d7`. The propagation fix is green with 331 tests, final xcodebuild and running-app GUI acceptance; the task-end local checkpoint contains this documentation.

## Exact Resume Action
`cd /Users/azimnb/ltx23appdev/ltx-video-mac && git status && swift run LTXTests && xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
