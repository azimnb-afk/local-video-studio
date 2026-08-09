# CURRENT_STATE

Updated: 2026-08-09

## Current Phase
Phase A2 — Distribution Runtime / Packaging is packaging-complete pending Apple
Developer ID and notarization credentials. The v1 app is a thin client:
external Python/MLX, FFmpeg, and Hugging Face model/encoder caches; App Sandbox
OFF; Hardened Runtime ON with no CS exception entitlements.

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
- CharacterBible Phase 0-6: Production UX complete for Character Reference assets and Starting Image conditioning.
- **Phase A1: First Run / Dependency Onboarding**:
  - `DependencyHealthManager` singleton aggregating `SetupRequirement` statuses (`.python`, `.ffmpeg`, `.videoModel`, `.textEncoder`, `.localDirector`, `.vision`).
  - Required vs Optional dependency split: Python, FFmpeg, Video Model, and Text Encoder are Required (`isGenerationReady = true` when all 4 are `.ready`); Ollama / Vision are Optional and do not block Generation.
  - Python validation accepts Python 3.11+ and probes the production
    `mlx_video.generate_av` plus LTX text-encoder imports. The exercised
    combination is Python 3.14.5 with `mlx-video-with-audio` 0.1.36; torch and
    diffusers are not generation gates. Invalid saved paths trigger
    non-mutating `autoDetectPython()` recovery.
  - Non-blocking UI: App browsing, Archive, Projects, CharacterBible, and Settings remain fully accessible even if required dependencies are missing.
  - Unified Generation Gating: Every generation trigger (Generate, Add to Queue, Batch, One Shot, Storyboard Take, Generate Missing Takes, Regenerate Selected Shots, Hybrid auto generation, Retake, History) checks `isGenerationReady` and routes to `SetupWizardView` when dependencies are lacking.
  - Safety & Privacy: No silent `pip install`, `brew install`, `sudo`, system Python mutation, or auto-downloads. No API keys or credentials exported in `copyDiagnostics()`.

## Build & Verification Status
- `swift build`: PASS
- `swift run LTXTests`: **659 passed, 0 failed**
- `xcodebuild -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**
- `xcodebuild -scheme LTXVideoGenerator -configuration Release CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**
- `git diff --check`: PASS

## Phase A2 Packaging Status
- `scripts/build-release.sh local-test` produces an ad-hoc signed, clearly
  named Release DMG and does not notarize or claim distribution readiness.
- `scripts/build-release.sh distribution` has explicit credential preflight;
  no valid Developer ID identity or notary profile is present on this Mac, so
  it safely stops before replacing existing artifacts.
- Archive contains the universal app and dSYM. Bundle inventory contains no
  embedded Python runtime, FFmpeg executable, model weights, or encoder
  weights.
- See `DISTRIBUTION_ARCHITECTURE.md` and `RELEASE_PROCESS.md` for the exact
  delivery path and human credential hand-off.

## 2026-08-09 Preset effective-settings regression closure

The Phase A2 local-test app exposed a real preflight/UI regression, not a
packaging failure: Quick Preview could retain old Custom fields in the UI
(512×768 / 121 frames / 30 steps) while `GenerationService` correctly resolved
the renderer request to Quick's compact profile. `GenerationSettingsResolver`
is now also the common preflight/queue boundary. Generate's effective-settings
summary and high-memory warning use that same resolved request; all queue
producers (Generate, One Shot, Storyboard, Hybrid, History) receive the same
preflight normalization; final execution still resolves again immediately
before rendering.

Quick Preview is C3 (512×320 / 49 frames / 15 steps) with audio, or C2
(512×320 / 65 frames / 15 steps) with audio off. Standard and High Quality
remain adaptive S0 and H0 respectively, and Custom remains manual. Storyboard
creation no longer overwrites a non-Custom preset's dimensions with stale
sheet state. Canonical Debug GUI acceptance verified Quick → C3, Standard →
S0, High → H0, Custom manual controls, and Quick persistence through restart;
no new render or download was started.

## 2026-08-09 Generate / One Shot responsibility split

Generate remains the direct production surface for T2V, existing one-image I2V,
presets, audio, queue, and batch work. Its embedded One Shot Director disclosure
and planning state were removed; the existing `Image to Video` source-image
workflow and `generationSource = generate` request path are unchanged.

One Shot now owns directed single-scene planning and an independent optional
`Starting Image`. The image is a first-frame visual anchor, persists under a
One Shot-specific preference key, and travels through the existing
`GenerationRequest.sourceImagePath` / MLX I2V bridge. A missing or unreadable
selection is rejected both before planning and immediately before queueing, with
explicit choose-again/clear recovery; it never silently becomes text-only.
Clearing the image deliberately restores text-only One Shot.

Canonical Debug GUI acceptance used the full DerivedData app path resolved from
`xcodebuild -showBuildSettings`. HEAD before the local Phase X checkpoint was
`9f2a355`; executable mtime was `2026-08-09 22:04:52 +0900`; the accepted
process was PID `87843`, started at `22:10:12`, from that exact executable.
Generate showed direct `Image to Video` and no One Shot Director UI. One Shot
showed image selection, thumbnail/status, clear, and deterministic missing-file
recovery. No render, model download, cloud call, or backend change was made.
