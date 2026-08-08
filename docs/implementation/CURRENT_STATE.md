# CURRENT_STATE

Updated: 2026-08-08

## Current Phase
Final — all feasible phases implemented; report finalization.

## Completed
- Source acquisition: cloned `james-see/ltx-video-mac` (MIT) @ `a441dc2` → branch `director-extensions`.
- Phase 0: audit + SPM build/test harness + measured baselines (BASELINE.md, BENCHMARK_RESULTS.md).
- Phase 1: ModelRegistry + VideoGenerationAdapter boundary + backward-compatible metadata + FeatureFlags (all default OFF).
- Phase 2: CompatibilityLab (11-check gate), ManifestValidator, ModelInstaller (no auto-download), Adult Mode + policy at Service/API layers, Preferences "Models & Features" tab.
- Phase 3: MemoryMonitor/HardwareProfiler/QualityProfile ladder/AutoQualityEngine/HistoricalSuccessStore, fallback retry (max 3), MediaProbe wiring, LowRAMMLXAdapter boundary (Runtime Verification Pending), lowram_bench.sh.
- Phase 4: One Shot Director (Ollama loopback provider + template fallback, terminate-before-render), OneShotPlan, PromptCompiler, DialogueNormalizer, UI disclosure.
- Phase 5: FilmProject/Shot/Take (1–20 sequential takes), versioned atomic persistence, resume reconciliation (real MP4 = truth).
- Phase 6: ContinuityEngine (deterministic directives + validator + monotony rules), StoryboardDirector (hybrid, sequential roles), FinalAssemblyService (stream-copy/normalize+concat) — verified against real MP4s.
- Phase 7: LocalAPIServer v1 (loopback + token + asset sandbox + policy), extras/openclaw.
- Regression: same-seed re-run produces **byte-identical MP4** to Phase 0 baseline (MD5 match).

## In Progress
- FINAL_IMPLEMENTATION_REPORT.md; short queue-soak validation (3 takes).

## Build Status
- `swift build` clean (SPM harness; Xcode-only artifacts gated behind !SPM_BUILD).
- `.xcodeproj` untouched but new sources are NOT yet added to the Xcode project file — see Known Blockers.

## Test Status
- `swift run LTXTests`: **242 checks, 0 failures** (see TEST_MATRIX.md).

## Known Blockers / Remaining Human Actions
1. No Xcode.app on this machine → cannot build/sign the .app bundle here. All 26 new source files are already registered in project.pbxproj (plutil-validated); install Xcode and build the existing scheme.
2. 10Eros weights not downloaded (user authorization required, tens of GB) → lab models stay verified=false. To verify: download weights, run scripts/compat_lab_smoke.sh, record checks in Compatibility Lab.
3. No 16GB hardware → LowRAM adapter Runtime Verification Pending; run scripts/lowram_bench.sh on a 16GB Mac (a dgrauet/ltx-2-mlx checkout already exists at ~/AI/LTX-MLX/ltx-2-mlx with a Q8 model).
4. Full 20-take queue soak (scripts/queue_soak.sh 20, ≈17 min) not yet run; 3-take validation done.

## Feature Flags
modelRegistryV1, derivedModelsV1, adultModelsV1, autoQualityV1, lowRAMAdapterV1, directorV1, filmProjectV1, storyboardV1, localAPIv1 — all default OFF; all OFF = byte-identical legacy behavior (proven by MD5-identical regression render).

## Last Known Good Commit
- Baseline: `a441dc2` (upstream main). All phase checkpoints on `director-extensions` are green (build + 242 tests).

## Exact Resume Action
`cd /Users/azimnb/ltx23appdev/ltx-video-mac && git log --oneline -12 && swift run LTXTests` — then read FINAL_IMPLEMENTATION_REPORT.md → "Remaining Human Actions".
