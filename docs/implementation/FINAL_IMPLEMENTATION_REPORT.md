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
`swift run LTXTests`: **444 checks, 0 failures**. Includes CharacterBible persistence/migration, stable-ID rename/delete behavior, reference-asset codecs/storage policy, Director/Basic/Hybrid assignment, continuity precedence and multi-character prompt separation, plus exact Quick/Standard/High final-request comparison and all prior Director/render regressions.

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
5. Optionally evaluate additional local Ollama models for creative planning quality. `qwen3.6-claw-fast:latest` is installed and now passes the pure Storyboard structured-output path; deterministic template fallback remains available.

## 18. Exact Resume Prompt
> /Users/azimnb/ltx23appdev/ltx-video-mac の docs/implementation/CURRENT_STATE.md と FINAL_IMPLEMENTATION_REPORT.md を読んでください。branch は director-extensions、テストは `swift run LTXTests`（444 checks）です。Remaining Human Actions のうち完了したものを教えるので、対応する Runtime Verification（10Eros compat lab / 16GB lowram bench / full queue soak）を進め、結果を Compatibility Lab・BENCHMARK_RESULTS.md・TEST_MATRIX.md へ記録してください。Official fast path の regression 判定は同一 seed の MD5 比較（bf8020b1f55f73a62c075f2df1c65a8d）を基準にしてください。

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

## 20. Pure Storyboard structured-output root-cause closure

### Reproduction and root cause
Before changing the parser, the exact Japanese sea-side Brief was sent to the configured local model `qwen3.6-claw-fast:latest` using the app's existing Storyboard system prompt and JSON format request. Ollama returned:

- an empty outer `response` field;
- valid, exact-schema JSON for three 5-second shots in the outer `thinking` field;
- no Markdown fence, prose prefix/suffix, trailing comma, missing required field, invalid enum, type mismatch, or semantic violation.

`OllamaDirectorProvider` only read `response`. The valid plan was therefore converted into an empty string before Storyboard JSON extraction or strict validation ran. Retries repeated the same envelope mistake, and the preserved Basic/template fallback created one shot. The root cause was Ollama thinking-envelope handling, not schema strictness.

### Minimal Planning-layer fix
- Ollama Storyboard requests retain `format:"json"` and now send `think:false`, so thinking-capable models put structured output in `response`.
- Response extraction prefers a non-empty `response`, accepts non-empty `thinking` as a compatibility path, and emits a distinct no-response error if both are empty. There is no model-name-specific branch.
- The Storyboard pipeline is now: direct decode → balanced first-object extraction → decode → validation → conservative deterministic repair → one LLM repair request → existing Basic/template fallback.
- Extraction handles JSON-only, fenced JSON, and prose around the first balanced object while respecting braces inside strings. Deterministic repair is deliberately narrow: safe trailing commas, documented wrapper/field aliases, numeric duration strings, empty logline/title repair, and abnormal duration clamping. It does not invent story content.
- Diagnostics identify request, no response, extraction, syntax, Codable decode, schema, semantic, deterministic repair, retry, and template fallback stages. Debug-only raw responses use a size-bounded temporary log; Release does not retain them.
- FilmProject adds optional backward-compatible planning metadata: provider, model, AI/fallback mode, and fallback reason. Storyboard UI surfaces `Director: Local AI` or `Director: Basic Fallback` without exposing raw prompt/response content.

No LTX inference, Preset, GenerationSettingsResolver, text-encoder propagation, Take queue, retake, Final Assembly, or cancel implementation was changed.

### Pure Storyboard GUI evidence
Canonical app: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`. Executable mtime: `2026-08-09 08:11:28 +0900`. Running PID 58415 resolved to that exact executable path.

Project `2274CB69-B651-4C1F-A9B5-2BF975E00023` used the same Brief and persisted:

- `directorProvider=ollama`
- `directorModel=qwen3.6-claw-fast:latest`
- `planningMode=ai`
- `fallbackReason=null`
- `modelID=ltx23_distilled_q4`
- `textEncoderID=gemma3_12b_4bit`

The GUI reported `Planned 3 shots via Local AI Director (ollama)` and displayed three 5-second shots: The Walk, The Pause, and The Smile. All compiled prompts were non-empty and continuity state propagated the same character, outfit, beach, dusk timing, and explicit position changes. No BF16 encoder was selected, no model was downloaded, and Ollama was unloaded/stopped after planning.

A new video render was intentionally omitted: this task changed only Planning, while the same cached Q4/4-bit downstream queue, retake, mixed-resolution assembly, and cancellation paths had already passed real E2E at the immediately preceding checkpoint.

## 21. Zero-setup Storyboard Director experience

### Product architecture
Storyboard exposes one product concept, Director, with requested modes Auto (default/recommended), Local AI, and Basic. `DirectorEnvironmentService` is the shared source for loopback availability, installed models, configured preference validity, effective mode/model, and friendly status. Views do not perform curl, shell model discovery, or direct UserDefaults interpretation.

Auto queries the existing loopback `/api/tags` endpoint. It uses the configured `directorOllamaModel` when installed, otherwise selects the first deterministic compatible installed text-generation candidate (excluding obvious embedding/reranking tags). If the server or all candidates are unavailable it selects Basic. Explicit Local AI with a missing configured model reports that condition and still permits Basic fallback; explicit Basic never contacts Ollama. Actual planning/Test requests remain the structured-output capability check, and any failure falls through the bounded da86397 repair/fallback pipeline.

There is no automatic `ollama pull`, Hugging Face download, server process management, cloud LLM, or OpenClaw linkage. Planning success/failure remains distinct from LTX generation. After a Local AI Test or planning attempt the selected Ollama model is unloaded before any LTX work.

### User interface and metadata
- Storyboard creation presents Auto / Local AI / Basic and a short `Local AI Ready` or `Basic Director · No setup required` state. Endpoint/model transport terminology is absent from the normal workflow.
- Settings > Director provides mode, status, installed-model picker, Refresh Models, Test, and Advanced-only endpoint/technical status.
- The picker writes the pre-existing `directorOllamaModel` preference; model additions appear after Refresh without restarting the app. Existing FilmProjects are never rewritten.
- FilmProject keeps the previous optional provider/model/planning/fallback fields and adds optional `requestedDirectorMode` and `effectiveDirectorMode`. Explicit Basic is labeled `basic`, Auto failure is labeled `fallback`, and successful Local AI is labeled `ai`.
- Basic is a supported Director, not a terminal error. It only decomposes clearly marked first/next/final shot beats, avoiding broad heuristic story invention; other briefs retain the safe single-shot behavior.

### Canonical GUI evidence
The canonical app executable mtime was `2026-08-09 08:45:59 +0900`; PID 59844 ran the exact DerivedData path. The installed-model picker listed ten existing models and persisted/restored qwen selections. Test succeeded and unloaded the model.

| Case | Project | Requested | Effective | Planning | Result |
|---|---|---|---|---|---|
| Auto, Ollama/model ready | `668BCE7F-D25C-4AB8-A68C-24FDDA280181` | auto | localAI | ai | qwen fast, 3×5 s, fallback nil |
| Explicit Basic, Ollama running | `93CA9860-CF98-4009-9D81-F600873DC397` | basic | basic | basic | template, 3×5 s, no Ollama request |
| Auto, Ollama stopped | `B37EC01D-47A1-441F-A9D1-2B22210A8DC6` | auto | basic | fallback | 3×5 s, `localAIServerUnavailable` |

The Homebrew Ollama service was restored to its original started state after the offline test. Mode is Auto, preferred model is `qwen3.6-claw-fast:latest`, and `/api/ps` is empty. Every project retained Official Q4 + Gemma 12B 4-bit. No download or video generation was initiated.

## 22. CharacterBible Phase 0 — Foundation

### Shared architecture and capability boundary
The former minimal `CharacterBibleEntry` stub was expanded rather than replaced. `FilmProject` now owns a schema-versioned `CharacterBible`; each `BibleCharacter` has a stable UUID, name/aliases, structured visual appearance, default costume, personality, speaking style, role notes, continuity notes, trait locks, future reference-asset metadata, and timestamps. `Shot.characterIDs` stores only UUIDs, so rename cannot break identity relationships.

Storyboard and Hybrid use one common path:

`CharacterBible → StoryboardDirector/Basic Director → Shot.characterIDs → ContinuityEngine → PromptCompiler → Generation prompt`

The Director sees concise planning-relevant summaries and is instructed to return exact available UUIDs. Old responses may omit the optional field. Exact unique name/alias resolution is supported as a narrow compatibility path; unknown IDs are removed with a diagnostic rather than invalidating the entire plan, and ad-hoc Brief characters remain allowed without silently creating Bible records. Basic Director assigns an exactly mentioned Bible character and carries a sole Brief character across explicit First/Next/Finally beats. Hybrid calls the same planner and compiler and has no duplicate character model.

Continuity resolves explicit/current state before Bible defaults. PromptCompiler emits separate compact blocks only for characters assigned to the Shot. It includes visual identity, current/default costume, relevant locks, and continuity-critical notes, but excludes long personality/speaking-style text from visual render prompts. Known Bible characters are removed from the older name-keyed global continuity dump so UUIDs and unrelated Bible characters cannot leak into every Shot.

### Persistence, assets, and legacy coexistence
- FilmProject schema version 2 decodes missing Bible, `characterIDs`, and base prompt fields with safe defaults while preserving existing Shots, Takes, Jobs, and assembly metadata.
- The old CharacterProfile feature remains unchanged for Generate. An explicit non-mutating candidate bridge exists for a future “Add from Character Profile” action; no profile is automatically migrated or rewritten.
- Reference assets have string-backed forward-compatible types and metadata for character sheet, face, front, side, back, expression, costume detail, and other. The store reserves project-owned `Assets/Characters/<CharacterID>` paths and rejects absolute/path-traversal references.
- Phase 0 does not import or inspect files. It adds no Vision model, face detection/crop/embedding, identity extraction, LTX reference input, cloud upload, or same-face guarantee. Trait locks are textual continuity guidance only.

### User interface
Storyboard and Hybrid creation and project detail share the same Characters UI. A lightweight sheet supports Add/Edit/Cancel/Save for all Phase 0 fields and clear Face/Hair/Eyes/Body/Costume/Accessories locks. The UI states that locks guide continuity and do not guarantee pixel-identical identity. Same-name records show an ID prefix. Each Shot has a native multi-selection menu and live prompt recompilation.

Delete requires confirmation and removes the UUID from every Shot before autosave while preserving existing Takes. Rename updates only Bible display data. Hybrid retains automatic first-pass generation as the default; an explicit “Generate first pass after planning” option permits a planning-only acceptance workflow without changing the established production default.

### Automated and canonical-app evidence
`swift build` passed; `swift run LTXTests` passed **444 / 444**; unsigned Debug `xcodebuild` succeeded; `git diff --check` was clean. Coverage includes old-project migration, UUID stability, delete/reload integrity, all asset-type round trips including unknown future types, managed-path rejection, CharacterProfile bridge non-mutation, AI/Basic/Hybrid assignment, unknown-ID diagnostics, continuity precedence, lock changes, and separated two-character prompts.

Pure Storyboard project `F9C4AC55-B1A4-4962-9869-FBE477A8B6B2` contains three shots that all reference `C7133C84-7791-4F7F-AFC8-0A31ADD2A140`. The character was entered as Adventurer Heroine, renamed to Maya, and remained assigned by the same UUID after rename and app restart. The restored compiled prompts use Maya and the selected face/hair/eyes/costume guidance.

Hybrid project `9F8F7FF6-852E-48EF-9627-E9A9A8D65D7C` contains three shots that all reference `B04A90CE-85AA-40AE-9121-E370FA1BFAA5`. Removing and restoring the Shot assignment removed and restored the character prompt block. A temporary character passed confirmed delete with no dangling references. Planning-only mode left Jobs/Takes empty, and no LTX generation or model download was started.

## 23. CharacterBible Phase 1 — Character Sheet Import / Local Vision Analysis

### Import, storage, and persistence
Storyboard and Hybrid use one shared Character Sheet workflow. `NSOpenPanel` admits PNG/JPG/JPEG; `FilmProjectStore` validates the source, copies it with a collision-safe UUID filename into the owning project/character asset directory, and creates `.characterSheet` metadata only after the copy succeeds. The external original is never moved, renamed, modified, or deleted. Cancel removes only the staged project copy, while a saved sheet remains as the full-resolution future source. Missing managed files do not prevent project/character loading.

`CharacterReferenceAsset` remains backward compatible and now optionally records MIME type, pixel dimensions, byte size, detected views, expressions, provider/model, and analysis time. `BibleCharacter.accessories` was added with a legacy default. These values re-enter the existing Phase 0 path through `CharacterBible -> Shot.characterIDs -> ContinuityEngine -> PromptCompiler`; sheet bytes are not sent to LTX.

### Local analysis and review-before-save
Character Sheet Analysis has its own Auto/Local Vision/Manual preference and `characterSheetVisionModel` key, separate from the Director text model. Installed compatible models are determined from reported Ollama capabilities, with metadata probing only when tag capability data is absent; there are no model-name heuristics and no download path. The provider accepts loopback URLs only, sends a bounded analysis image, requests JSON, performs direct/extracted decode plus conservative trailing-comma repair and at most one model repair, then unloads the model. A service-level generation-active gate and disabled GUI prevent concurrent LTX/Vision loading.

Analysis produces a transient candidate, never a `BibleCharacter`. Review presents the source preview and editable detected fields. Existing characters show Current/Detected separately and default non-empty current fields to not applied. Save is the truth boundary and preserves existing UUIDs. Visual analysis does not invent or update personality, speaking style, role, aliases, or locks. Server/model absence and schema failure are normal Manual Review paths and do not block Character Sheet registration.

### Verification and capability boundary
Automated coverage passed **498 / 498** and includes valid/fenced/prose/trailing-comma/malformed JSON, unknown future views, missing core structure, bounded repair, unload success/failure, no provider call during generation, capability metadata/no name guessing, PNG/JPEG atomic import, original preservation, cancel cleanup, PDF rejection, candidate mapping, selective Maya merge, old-asset decoding, project reload, stable Shot UUIDs, and compiled prompt propagation. `swift build`, unsigned Debug `xcodebuild`, and `git diff --check` also passed.

The exact user sample was not available, so no image was downloaded. Canonical GUI acceptance used a local synthetic 1600×1600 Front/Side/Back/Close-Up/Expressions/Costume Details sheet. Auto used installed `agents-a1:32k`, exhausted one repair because the result lacked the required appearance structure, unloaded successfully (`/api/ps` empty), and entered Manual Review. The reviewed Maya project retained an identical managed copy (SHA-256 `27a289b...d1b7a`), persisted metadata through restart, and compiled reviewed face/hair/eyes/costume/accessories. A second Basic Director project produced three shots that all reference UUID `9C0C46EE-DBF7-4F0B-BCA2-9C576618FD1B`; explicit Face/Hair/Eyes locks appeared as textual guidance.

Phase 1 does not implement PDF parsing, face crops, face recognition/embedding, identity/reference conditioning, image delivery to LTX, multi-view conditioning, or a same-person guarantee.
