# CURRENT_STATE

Updated: 2026-08-08

## Current Phase
Final GUI-first completion — Preset UX, Project Settings, four-mode navigation and Hybrid MVP implemented and verified.

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

## In Progress
- None. Safe local git checkpoint pending at the end of this task.

## Build Status
- `swift build` clean (final GUI implementation).
- **Xcode 26.6 installed (2026-08-08): `xcodebuild -scheme LTXVideoGenerator -configuration Debug` → BUILD SUCCEEDED.** Full .app bundle produced (arm64, ad-hoc signing via CLI overrides only — no project settings changed; deployment target 14.0, bundle id com.ltxvideo.generator). App launches and runs.

## Test Status
- `swift run LTXTests`: **282 checks, 0 failures** (see TEST_MATRIX.md).

## Known Blockers / Remaining Human Actions
1. ~~No Xcode.app~~ → RESOLVED: Xcode 26.6 installed; unsigned dev .app builds and runs. Remaining: Developer ID signing + notarization for distribution (needs credentials).
2. 10Eros weights not downloaded (user authorization required, tens of GB) → lab models stay verified=false. To verify: download weights, run scripts/compat_lab_smoke.sh, record checks in Compatibility Lab.
3. No 16GB hardware → LowRAM adapter Runtime Verification Pending; run scripts/lowram_bench.sh on a 16GB Mac (a dgrauet/ltx-2-mlx checkout already exists at ~/AI/LTX-MLX/ltx-2-mlx with a Q8 model).
4. Full 20-take queue soak (scripts/queue_soak.sh 20, ≈17 min) not yet run; 3-take validation done.

## Feature Flags
GUI-first defaults (D-007): modelRegistryV1 / autoQualityV1 / directorV1 / filmProjectV1 / storyboardV1 = **ON** by default; derivedModelsV1 / adultModelsV1 / lowRAMAdapterV1 / localAPIv1 = OFF (opt-in). All OFF (Preferences → Models & Features) = byte-identical legacy behavior (proven by MD5-identical regression render). Quality defaults to "Advanced" (= manual parameters untouched).

## GUI (verified in the final running .app, 2026-08-08)
- Sidebar: Generate / One Shot / Storyboard / Director / Hybrid / Video Archive, with concise mode descriptions.
- Generate: Model + Preset picker; no primary Quality picker; non-Custom shows a preset explanation, Custom restores all legacy manual controls.
- One Shot: independent Brief / Preset / Model / Target Duration / Audio / Create & Generate screen.
- Storyboard: Project Settings, Custom resolution controls, Generate Missing, Regenerate Selected Shots, per-shot regeneration, append-only Take review/selection and Final Assembly.
- Hybrid: Brief / Preset / Model / Audio / Target Duration / Create & Generate sheet; automatic short-shot split and single-flight first-pass queue; same review/retake/assembly workspace.
- Video Archive: Requested / Effective / Actual (MP4) / Actual Length rows
- Preferences → Models & Features: Adult Content Mode + all flags + Compatibility Lab status

## Last Known Good Commit
- Pre-task checkpoint: `277755b`. This GUI completion working tree is green with build + 282 tests + xcodebuild + running-app acceptance and is checkpointed with this documentation.

## Exact Resume Action
`cd /Users/azimnb/ltx23appdev/ltx-video-mac && git status && swift run LTXTests && xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
