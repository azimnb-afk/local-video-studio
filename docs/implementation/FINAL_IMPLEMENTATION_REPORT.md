# FINAL IMPLEMENTATION REPORT

Date: 2026-08-08
Repo: /Users/azimnb/ltx23appdev/ltx-video-mac (clone of MIT `james-see/ltx-video-mac`)
Branch: `director-extensions` (baseline: upstream `main` @ `a441dc2`)
Machine: Mac16,11 / Apple M4 Pro / 48 GB / macOS 26.5.2 / Xcode 26.6

---

## 1. Completed

**Precondition discovered and solved:** the app source did not exist anywhere on
this machine (docs only + installed DMG 2.3.66). The MIT upstream was cloned and
used as the Last Known Good Baseline; upstream git history is retained.

- **Phase 0 — Audit/Baseline**: full code+environment audit (BASELINE.md); all Deep-Research hypotheses re-verified against local code; SPM build/test harness for the CLT-only environment; measured baselines for T2V/I2V × audio ON/OFF with the app's exact CLI (BENCHMARK_RESULTS.md); render verified fully offline (HF_HUB_OFFLINE=1).
- **Phase 1 — Model Registry**: ModelDescriptor/ModelRegistry/ContentClassification/Policy/Runtime/License/Artifacts; `VideoGenerationAdapter` protocol; OfficialMLXAudioAdapter (thin wrapper — LTXBridge untouched); DerivedModelAdapter; AdapterRegistry; 9 rollback-capable feature flags; backward-compatible request/result metadata with decodeIfPresent migration.
- **Phase 2 — 10Eros Compatibility Lab + Adult Mode**: 11-check verification gate persisted to disk; ManifestValidator (revision pinning, license, classification evidence, repo-id injection guard, snapshot completeness); ModelInstaller (disk preflight, license acknowledgement, never auto-downloads); adult policy matrix enforced at Service and API layers; Preferences "Models & Features" tab.
- **Phase 3 — Auto Quality + Low-RAM foundation**: MemoryMonitor (vm_statistics64/vm.swapusage/task_vm_info/pressure source/thermal), HardwareProfiler with memory tiers, QualityProfile ladder seeded from measured anchors, HistoricalSuccessStore (per-hardware signature), AutoQualityEngine (hardware prior + evidence-based history cap + preflight; ≤3 attempts; memory-failure classification), fallback retry loop in GenerationService, MediaProbe (actual MP4 = source of truth) filling result metadata, LowRAMMLXAdapter boundary + lowram_bench.sh.
- **Phase 4 — One Shot Director**: OneShotPlan structured JSON with validation; provider abstraction (Ollama on 127.0.0.1 with keep_alive:0 unload; deterministic template fallback so the feature works with zero LLMs installed); bounded JSON repair (≤2); LLM ALWAYS terminated before rendering; PromptCompiler (chronological/present-tense/single-flow; I2V image = visual truth; Japanese native + optional romanization); DialogueNormalizer; UI disclosure.
- **Phase 5 — FilmProject/Shot/Take**: complete data model incl. spec's full Take field list; 1–20 takes (seed variants) strictly sequential through the single-flight queue; versioned atomic persistence (schema guard: newer files never destroyed; pre-migration backups); startup resume reconciling in-flight takes against real MP4s.
- **Phase 6 — Storyboard/Continuity/Assembly**: deterministic ContinuityEngine (directive grammar, Previous+Changes=Next, contradiction validator, monotony rules); StoryboardDirector (hybrid: one sequential local LLM for all roles, terminated before render; template fallback); FinalAssemblyService (ffprobe-driven: stream-copy when compatible, else normalize+re-encode; hard cuts) — verified by actually concatenating two baseline MP4s.
- **Phase 7 — Local REST API v1**: loopback-only bind, installation token (0600, constant-time compare), asset sandbox with UUID-indirection (no client paths ever), variations ≤20, request/asset size caps, PNG/JPEG magic check, no CORS headers, adult policy that clients cannot override; endpoints /v1/assets, /v1/jobs (+get/delete), /v1/models, /v1/system, /v1/history; extras/openclaw docs + JSON schema + skill example. Legacy APIServer untouched.
- **Xcode project**: all 26 new sources registered in project.pbxproj (plutil-validated).
- **GUI-first completion**: shared Preset architecture; Generate/One Shot/Storyboard/Hybrid use one mapping; Storyboard Project Settings with Custom resolution/frames/FPS/steps/audio; append-only Preview→High Quality regeneration; four production modes; dedicated One Shot; Hybrid target-duration shot splitting and sequential first pass.

## 2. Partially Completed
- **Queue soak**: 3-take validation ran (peak flat, +0.07%); full 20-take soak is harness-ready (`scripts/queue_soak.sh 20`, ≈17 min) but not executed.
- **REST API socket-level tests**: all logic (auth/validation/sandbox/policy/framing) unit-tested; end-to-end curl requires the running GUI app (needs Xcode build).
- **UI (updated 2026-08-08)**: complete for the requested GUI-first workflow. Generate uses Preset instead of Quality; One Shot is independent; Storyboard has persistent Project Settings and current-Preset regeneration; Hybrid creates/splits/queues the initial pass; Requested/Effective/Actual metadata is retained. Remaining optional polish: take favorite/rating/notes editing (data model complete).

## 3. Not Implemented (+ reason)
- **10Eros runtime verification**: weights are tens of GB and were never downloaded (explicit user authorization required by the spec). Lab, installer, validators, policy and smoke harness are complete; both 10Eros entries remain `verified=false` and cannot generate.
- **16GB Compact runtime verification**: no 16GB hardware. Adapter/profiles/monitoring/harness complete; `Runtime Verification Pending on 16GB hardware`.
- **Low-RAM backend runtime integration**: gated intentionally — the adapter refuses to run until verified on hardware (no fake implementation shipped).
- **Phase 8 advanced features (LoRA/keyframes/continuation/upscale/…)**: capability flags exist in CapabilitySet, all default false; none enabled because none were runtime-verified on the current backend (spec: capability-driven, no fakes).
- **Crossfade assembly**: MVP is hard cuts per spec.
- **Signed/notarized distribution .app**: Developer ID credentials are not available; local Debug `.app` builds and runs.

## 4. Files Added
Models: FeatureFlags, ModelRegistry, QualityProfile, OneShotPlan, FilmProject
Services: VideoGenerationAdapter, CompatibilityLab, ManifestValidator, ModelInstaller, MemoryMonitor, HardwareProfiler, HistoricalSuccessStore, AutoQualityEngine, MediaProbe, LowRAMMLXAdapter, DirectorProvider, PromptCompiler, LocalDirector, ContinuityEngine, StoryboardDirector, FinalAssemblyService, FilmProjectStore, TakeGenerationCoordinator, APIv1Handler, LocalAPIServer
Views: ModelsAndFeaturesPreferences
Harness: Package.swift, Tests/LTXTests/* (7 files), scripts/benchmark_baseline.sh, scripts/compat_lab_smoke.sh, scripts/lowram_bench.sh, scripts/queue_soak.sh
Docs: docs/implementation/* (9 files), extras/openclaw/* (3 files)

## 5. Files Modified
- GenerationRequest.swift / GenerationResult.swift — optional metadata + migration
- GenerationService.swift — flag-gated adapter routing, auto-quality retry, MediaProbe, take linkage (legacy path preserved verbatim when flags OFF)
- PromptInputView.swift — quality picker, director panel, 10/20 variations, qualityMode pass-through
- PreferencesView.swift — new tab hook; LTXVideoGeneratorApp.swift — flag-gated startup wiring; project.pbxproj — file registration
- 6 view files — `#Preview` gated behind `!SPM_BUILD` (Xcode unaffected)
- **NOT modified**: LTXBridge.swift generation internals (only formatting of call sites; the Python script, scheduler/VAE/conditioning logic untouched), HistoryManager.swift, AudioService.swift. Legacy APIServer request construction was updated only to carry the same preset/duration metadata into the shared resolver.

## 6. Architecture
GUI-first: SwiftUI → GenerationService (single-flight) → [flag OFF: LTXBridge directly | flag ON: ModelRegistry policy → AdapterRegistry → OfficialMLXAudioAdapter → same LTXBridge] → python subprocess → mlx_video.generate_av → MP4 → MediaProbe → History.
Local REST API v1 is a thin optional adapter over the same services. Director/Storyboard sit ABOVE generation (LLM terminated before render). Continuity is deterministic state, not LLM judgement.

## 7. Feature Flags
modelRegistryV1 · autoQualityV1 · directorV1 · filmProjectV1 · storyboardV1 default ON for GUI-first use. derivedModelsV1 · adultModelsV1 · lowRAMAdapterV1 · localAPIv1 remain OFF. All are independent; `FeatureFlags.disableAll()` restores the legacy path.

## 8. Build Results
`swift build`: clean (Swift 6.3.3 / macOS 26.5 SDK / SPM harness).
**Update 2026-08-08 (post-Xcode install)**: Xcode 26.6 — `xcodebuild -scheme LTXVideoGenerator -configuration Debug build` → **BUILD SUCCEEDED** with zero source changes needed. Full .app bundle (arm64, deployment target 14.0, bundle id com.ltxvideo.generator, ad-hoc CLI signing — no project settings modified). App launches and runs.
Automated acceptance against the running .app: API v1 socket-level security suite passed (401/401/403/400, loopback-only lsof, no CORS) and a full E2E job (POST /v1/jobs, quality=compact) ran a real generation through the GUI app's queue — Auto Quality applied C2 (512×320/65f), completed with actual ffprobe metadata (2.708 s), output re-verified on disk. Remaining distribution step: Developer ID signing + notarization (credentials required).

## 9. Test Results
`swift run LTXTests`: **331 checks, 0 failures** (breakdown: TEST_MATRIX.md). Includes exact Quick/Standard/High final-request comparison, history cap/fallback policy, duration survival for One Shot/Storyboard/Hybrid/API, Custom frame precedence, metadata migration, Preset mapping, Project Settings persistence, Preview Take retention, Hybrid orchestration, live syscall checks, real-MP4 MediaProbe, and real ffmpeg concat assembly.

## 10. Regression Results
Same seed/settings re-render after all changes produced a **byte-identical MP4** (MD5 bf8020b1f55f73a62c075f2df1c65a8d = Phase 0 baseline). Peak memory 23.46 GB ≤ baseline 23.66 GB. Official fast path: 0% regression.

## 11. Benchmark Results
Baseline (512×320/25f/15steps/24fps, Q4 + gemma-12b-4bit): T2V audio ON 49 s / 23.66 GB; audio OFF 46 s / 17.23 GB; I2V ON 48 s / OFF 47 s. Audio pipeline ≈ +6.4 GB peak. Details + soak: BENCHMARK_RESULTS.md. Other RAM tiers: Hypothesis (no hardware).

## 12. 10Eros Verification Status
`verified=false` (both lab entries). 0/11 gate checks recorded. Exact promotion workflow: MODEL_COMPATIBILITY.md. Adult classification claimed by upstream; evidence recorded, requires human license/provenance confirmation at install time.

## 13. 16GB Status
Compact ladder C0→C1→C2→audio defined (hypothesis anchored to 48GB measurements, not hard-coded guarantees); Low-RAM adapter isolated and inert; `Runtime Verification Pending on 16GB hardware`. Local ltx-2-mlx checkout exists at ~/AI/LTX-MLX for future verification.

## 14. Local-only Network Audit
- Render path verified to complete with `HF_HUB_OFFLINE=1` (no egress during generation; harness enforces it).
- No cloud video fallback anywhere; fallback ladder ends at `Unsupported`.
- Director LLM providers: 127.0.0.1 only (Ollama) or in-process template.
- API server: loopback bind + token; assets sandboxed; no CORS.
- Pre-existing external features (ElevenLabs voiceover — cloud when chosen by user) remain separate from the video generation path and are never used as fallback. Model downloads remain explicit user actions.

## 15. OpenClaw API Usage
extras/openclaw/README.md (curl examples), job.schema.json, skill-example.md. App is 100% functional without OpenClaw.

## 16. Known Risks
- QualityProfile estimates above 512×320 are Calculated, not Measured — Auto Quality corrects via HistoricalSuccessStore at runtime.
- LocalAPIServer HTTP parsing is minimal by design (loopback, tokened); it is not a hardened public-facing server and must never be bound beyond loopback.
- `useLocalMlxVideoRepo=1` user pref is stale (no local checkout) — harmless, pip package used.

## 16b. Gap Analysis / GUI Acceptance
Per-item completion audit vs the Master Implementation Prompt (incl. Phase 8
per-feature status): [GAP_ANALYSIS.md](GAP_ANALYSIS.md).
Post-Xcode human GUI acceptance checklist: [GUI_ACCEPTANCE_CHECKLIST.md](GUI_ACCEPTANCE_CHECKLIST.md).

## 17. Remaining Human Actions
1. Optionally sign/notarize for distribution (Developer ID credentials required).
2. Decide whether to download 10Eros weights (license acceptance + tens of GB) → then run the Compatibility Lab workflow in MODEL_COMPATIBILITY.md.
3. Run `scripts/queue_soak.sh 20` (~17 min) for the full soak record.
4. On a 16GB Mac: run `scripts/lowram_bench.sh` and record results before enabling lowRAMAdapterV1.
5. Optionally install Ollama + a small model to upgrade Director planning beyond the deterministic template fallback.

## 18. Exact Resume Prompt
> /Users/azimnb/ltx23appdev/ltx-video-mac の docs/implementation/CURRENT_STATE.md と FINAL_IMPLEMENTATION_REPORT.md を読んでください。branch は director-extensions、テストは `swift run LTXTests`（331 checks）です。Remaining Human Actions のうち完了したものを教えるので、対応する Runtime Verification（10Eros compat lab / 16GB lowram bench / full queue soak / post-fix real Preset comparison）を進め、結果を Compatibility Lab・BENCHMARK_RESULTS.md・TEST_MATRIX.md へ記録してください。Official fast path の regression 判定は同一 seed の MD5 比較（bf8020b1f55f73a62c075f2df1c65a8d）を基準にしてください。

## 19. Preset / Quality propagation root-cause closure

### Root cause and affected modes
Two independent defects combined:

1. Auto returned the highest successful historical profile before consulting the hardware prior. The user's real `quality_history.json` contained Compact successes, so Standard/Auto resolved to Compact even though no Standard failure existed.
2. One Shot, Storyboard, Hybrid and API correctly computed duration-derived frames, but `QualityProfile.applied` later overwrote them with its fixed profile frame count. Retake, Generate Missing and Regenerate Selected were affected because all feed `TakeGenerationCoordinator` then `GenerationService`.

Generate was affected by the Auto history bug; duration overwrite affected the duration-aware modes and REST/OpenClaw. Custom was additionally vulnerable in One Shot because planning wrote plan duration into manual frames before Auto resolution.

### Fix
- Added one `GenerationSettingsResolver`; every path and retry uses it.
- 48 GB Standard uses S0; Quick uses C3 with audio; High uses H0. Lower success does not cap Auto unless S0's latest recorded outcome failed.
- Profile resolution happens first, then target duration recomputes frames at the profile FPS. Custom preserves manual frames.
- One Shot uses an independent persisted preset key.
- Full resolved settings are logged before render and durable metadata is shown in Archive/Take rows.

### Mandatory final-request comparison
Same brief, model `ltx23_distilled_q4`, seed `4242`, target/requested duration 5 s, audio ON:

| Preset | Quality | Effective profile | Width×Height | Frames | FPS | Steps | Audio | Model | Seed |
|---|---|---:|---:|---:|---:|---:|---|---|---:|
| Quick Preview | compact | C3 | 512×320 | 121 | 24 | 15 | ON | ltx23_distilled_q4 | 4242 |
| Standard | auto | S0 | 768×512 | 121 | 24 | 25 | ON | ltx23_distilled_q4 | 4242 |
| High Quality | high | H0 | 768×512 | 121 | 24 | 30 | ON | ltx23_distilled_q4 | 4242 |

All three use 121 frames because 5 s is an explicit duration constraint; the intended quality/time separation is resolution and inference steps, not an accidental duration change.

### Existing real-generation evidence
The final app's Archive and persisted history reproduced the reported regression with the same Japanese brief:

| Preset | Effective | Actual output | Frames/Steps | Wall time |
|---|---|---|---|---:|
| Quick Preview | C3 | 512×320, 2.01 s | 49 / 15 | 70.69 s |
| old Standard | C3 | 512×320, 2.01 s | 49 / 15 | 69.17 s |
| High Quality | H0 | 768×512, 5.01 s | 121 / 30 | 274.95 s |

A new post-fix render was not started because the Debug app reported `MLX Environment Not Ready` and the sandboxed Python probe reported no Metal device. This is an environment limitation, not a claimed pass. The required final-request comparison, unit/integration tests, persisted real-output inspection, final xcodebuild and GUI checks all completed.
