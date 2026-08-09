# DECISION_LOG

## D-001 (2026-08-08) Source acquisition by cloning upstream
No app source existed on this machine (docs only in ~/ltx23appdev; installed DMG 2.3.66). Cloned MIT-licensed `james-see/ltx-video-mac` @ a441dc2 into /Users/azimnb/ltx23appdev/ltx-video-mac. Upstream git history retained; `origin` remote points at upstream — NEVER push. Baseline = upstream main.

## D-002 (2026-08-08) Repo-local git identity
No global git identity configured. Set repo-local user.name=azimnb, user.email=azimnb@gmail.com (user's real address from session context, not fabricated; not set globally).

## D-003 (2026-08-08) SPM harness instead of xcodebuild
No Xcode.app installed; only CLT (Swift 6.3.3 + macOS 26.5 SDK). Added root `Package.swift` compiling app sources as a library + unit-test target so build/test discipline is possible. `.xcodeproj` untouched; Xcode users unaffected. Producing a signed .app remains a Remaining Human Action (install Xcode).

## D-004 (2026-08-08) Docs are spec-first, code-first on conflict
Deep Research claims re-verified against a441dc2 code; all key claims confirmed (see BASELINE.md table). No conflicts found requiring override.

## D-005 (2026-08-08) Baseline profile choice
Full-default generation (768x512x121f/30steps) takes very long on Q4+12b-4bit; baseline uses the app's own "Low Memory Preview" profile (512x320/25f/15steps/24fps, seed pinned) with audio ON/OFF as the reproducible reference, matching the master prompt's allowance to take one known-good generation plus a harness for the rest.

## D-007 (2026-08-08) GUI-first feature-flag defaults
User acceptance of the built .app showed the new features were invisible because every flag defaulted OFF. Per the GUI-first product definition, defaults changed to: modelRegistryV1 / autoQualityV1 / directorV1 / filmProjectV1 / storyboardV1 = ON by default; derivedModelsV1 / adultModelsV1 / lowRAMAdapterV1 / localAPIv1 stay OFF (unverified models, adult content, unverified backends, network listeners remain opt-in). The §45 rollback guarantee is preserved: FeatureFlags.disableAll / Preferences toggles restore the exact legacy path. Quality picker defaults to "Advanced" so default generation parameters are still exactly what the user set manually.

## D-006 (2026-08-08) Development source override retired in Phase A2
The former `useLocalMlxVideoRepo` preference and `LTX_FORCE_LOCAL_MLX_VIDEO`
override could make a Release build depend on `~/projects/mlx-video-with-audio`.
Phase A2 removes that runtime behavior and clears inherited `PYTHONPATH` in the
render wrapper. The configured external Python environment's installed
`mlx-video-with-audio` package is the sole runtime source of truth.

## D-008 (2026-08-08) Preset is the GUI concept; QualityMode stays internal
The existing AutoQualityEngine and QualityMode execution strategy remain unchanged. A shared `GenerationPreset` maps Quick Preview→Compact, Standard→Auto, High Quality→High and Custom→Advanced across Generate, One Shot, Storyboard and Hybrid. Manual controls are shown under Custom, avoiding contradictory preset/manual states. Existing legacy custom parameter bundles remain available only inside Custom. Preset changes are project settings changes, not storyboard rebuilds; Take creation is append-only and snapshots Preset/Quality/effective profile metadata.

## D-009 (2026-08-08) Hybrid is thin orchestration over completed services
Hybrid uses StoryboardDirector, PromptCompiler, ContinuityEngine, FilmProjectStore, TakeGenerationCoordinator, GenerationService and FinalAssemblyService. It adds no inference implementation. The deterministic no-LLM template fallback is expanded into 4–6 second shots from target duration so Hybrid remains usable without Ollama; all first-pass requests enter the existing single-flight queue.

## D-010 (2026-08-08) One concrete generation-settings resolver
`GenerationSettingsResolver` is the sole boundary that applies a resolved `QualityProfile` to `GenerationRequest`. Generate, One Shot, Storyboard, Hybrid, all take/regeneration actions, legacy REST and Local API v1/OpenClaw carry metadata to that same boundary. Retry fallback calls the same application function. This prevents mode-specific copies from silently diverging.

Duration precedence is explicit: a non-Custom profile owns resolution, FPS, steps, tiling and audio capability; a workflow `targetDurationSeconds` then owns frames through `PromptCompiler.frameCount` (8n+1); Custom/Advanced owns manual frames and ignores automatic duration constraints.

## D-011 (2026-08-08) Standard is distinct from Quick and explicit High on 48 GB
The former Auto policy treated any lower-profile success as a permanent ceiling. Production history proved the failure: a C3 success made Standard resolve to C3, identical to Quick. Auto now begins with a hardware prior, and lower successes cap it only when that exact prior's latest outcome is failure. On 48 GB the Standard prior is S0 (768×512/25 steps); explicit High remains H0 (768×512/30 steps). A fallback reason is persisted and displayed. A known H0 success confirms, but does not promote, Standard beyond S0; 64 GB+ retains H0 as its Auto prior.

## D-012 (2026-08-08) Diagnostics are persisted, not inferred later
`GenerationRequest` carries target duration and workflow source. `GenerationResult` and `Take` store effective profile reason, target/requested duration, effective audio and source, all backward-compatible optional fields. `GenerationService` prints the full final renderer settings before every attempt. Archive/Take UI exposes the durable fields so a future preset regression can be diagnosed without reconstructing transient UI state.

## D-013 (2026-08-09) Storyboard Director is zero-setup Auto with explicit effective state
The normal product concept is Director, not Ollama. Auto is the default and chooses Local AI only when the loopback server and an installed compatible candidate are available; otherwise it uses the fully supported Basic Director without blocking Storyboard creation. Local AI and Basic remain explicit expert choices. Installed models come from `/api/tags`, the existing `directorOllamaModel` key remains the sole model preference, and no automatic download or process management is added. Requested and effective modes are separate optional FilmProject metadata so Auto fallback is visible without changing old projects. OpenClaw remains an unrelated optional REST client.

## D-014 (2026-08-09) Character identity uses stable project-owned IDs
`FilmProject.characterBible` is the Storyboard/Hybrid source of truth, and `Shot.characterIDs` stores stable UUIDs. Names and aliases are editable display/planning data and never become the durable relationship. Director compatibility may resolve an exact unique UUID/name/alias, but unknown or ambiguous values are never guessed; unknown values are dropped with diagnostics and a Brief-only character may remain ad-hoc without automatic Bible registration.

Character data has one shared path through Director, Shot, ContinuityEngine, and PromptCompiler. Explicit Shot/current continuity state takes precedence over Bible defaults. Only assigned characters contribute compact visual guidance; personality and speaking style are available to planning but do not inflate every render prompt. Existing CharacterProfile remains a separate legacy/Generate model, with only an explicit non-mutating candidate bridge and no automatic migration.

Reference assets are project-owned metadata foundations. Future imports belong under `Projects/<ProjectID>/Assets/Characters/<CharacterID>` and persistence accepts only managed identifiers or safe project-relative paths, never an unstable absolute-path dependency. Phase 0 trait locks are textual continuity metadata. They do not claim face recognition, embedding, image/reference conditioning, or pixel-identical identity; those capabilities require later backend proof.

## D-015 (2026-08-09) Character Sheet analysis is a local candidate workflow
Character Sheet files become project-owned originals under the existing character asset boundary; an external source is copied, never referenced as the sole absolute path or modified. UUID filenames prevent collisions, metadata is created only after successful copy, and wizard Cancel removes only its staged project copy. The original managed sheet is deliberately retained for future crop/reference phases.

Vision analysis is independent from Storyboard Director: it has separate Auto/Local Vision/Manual mode and model keys. Compatibility is based on provider-reported capability metadata rather than model names. Only installed models may be used; no Ollama pull, Hugging Face download, cloud fallback, or OpenClaw path exists. The loopback provider uses a bounded derivative, one repair retry, and explicit unload, and cannot start while LTX generation is active.

Model output is not truth. It becomes an editable `CharacterSheetAnalysisCandidate`; only user Save mutates the Bible. Existing-character merges are field-selective and preserve the UUID, with non-empty fields unselected by default. Visual analysis never infers personality, speaking style, role, aliases, or trait locks. Schema/provider failure falls back to Manual Review while keeping the imported sheet usable.

Phase 1 remains textual continuity. Character Sheet bytes are not sent to LTX and no face crop, recognition, embedding, identity/reference conditioning, multi-view conditioning, or same-person guarantee is exposed.

## D-016 (2026-08-09) User-reviewed normalized crops are truth; originals supply pixels
Phase 2 separates semantic proposal, review geometry, and image materialization. The local Vision model may analyze a bounded derivative and return imperfect provider coordinates, but those values are only proposals. Persisted crop geometry uses normalized `x/y/width/height` in `0...1` with a top-left origin; only a user-reviewed rectangle becomes durable reference metadata.

All derived pixels come from the project-owned original after explicit orientation normalization. The extraction service writes lossless PNGs at native crop resolution, never from the analysis derivative and never with automatic upscale or visual filters. Derived assets retain optional source UUID/crop/source-dimension provenance and remain usable if the source sheet is later absent because each is an independent project-owned pixel file.

Real-sheet testing with installed `agents-a1:32k` is classified C: semantic panels can be identified, but localization varies enough to require correction. Auto Detect is therefore a best-effort accelerator, while manual crop remains fully supported without Vision. Reference presence does not change trait locks and is not connected to PromptCompiler, GenerationRequest, LTXBridge, MLX conditioning, face recognition, or an identity guarantee.

## D-017 (2026-08-09) Current I2V is temporal frame conditioning, not character identity

The installed `mlx-video-with-audio` 0.1.36 public API accepts one `image`, one `image_strength`, and one `image_frame_idx`. It VAE-encodes the entire image and replaces a selected video latent slice at both denoising stages. The app supplies one Source Image and strength but not the frame index, so current GUI/API generation always targets latent index zero. `image_strength` controls that temporal frame's denoise mask; it is not reference/identity guidance weight.

No face encoder, identity embedding/token/adapter, named-subject binding, generic reference input, or public multi-image input exists in the installed path. A face crop used as the I2V image is therefore only an experimental Starting Image misuse and must not be presented as Face Lock. Front/Side/Back cannot currently form one multi-view identity set. Official temporal keyframe and separate IC-LoRA pipelines are backend gaps, not current app capability and not evidence of face-only identity.

Phase 4 must not automatically connect CharacterBible reference assets to generation. The safe current terms are `Reference Images` for the library and `Starting Image` for explicit one-image I2V. Any future identity-capable adapter requires its own dependency, Q4/audio/memory, leakage, multi-character binding, and runtime audit before product claims.

## D-018 (2026-08-09) Phase 4 Starting Image Bridge reuses existing single-image I2V
CharacterReferenceAssets (derived Front, Side, Back, Face, Expression, Costume Detail) are bridged to Storyboard/Hybrid Shots via stable UUID `Shot.startingImageReferenceAssetID`. Raw Character Sheet originals are excluded from the candidate picker. `TakeGenerationCoordinator` resolves the asset ID to a project-owned managed file URL at request assembly time and assigns `GenerationRequest.sourceImagePath`.

No backend Python code, model dependency, or identity adapter was added. If a selected reference asset ID is unknown or its file is missing on disk, preflight throws `CoordinatorError` (`startingImageNotFound` / `startingImageUnavailable`), preventing silent T2V fallback. The UI strictly uses the term `Starting Image`; terms `Face Lock`, `Identity Lock`, `Same Face`, `Same Person`, and `Character Identity Conditioning` remain prohibited.

## D-019 (2026-08-09) Phase 5 Starting Image Evaluation: Default to None, Front Optional for Shot 1, Face Advanced
Controlled 3-condition real generation evaluation (A: None, B: Front, C: Face) demonstrated that while Starting Images increase visual resemblance to reference sheets, they introduce significant composition, posture, and studio background leakage.

1. `None` (Text-only CharacterBible) provides the highest camera freedom, motion naturalness, and zero composition leakage. It remains the recommended default for general users and multi-shot storyboards.
2. `Front` reference is the best Starting Image option when a visual anchor is desired for Shot 1, providing full-body costume/boots/cape continuity at the cost of initial frontal pose framing.
3. `Face / Close-Up` reference causes extreme composition leakage, locking the entire video into a static close-up framing. It must be treated as Advanced/Optional and never presented as "Face Lock".
4. Phase 6 UX will preserve `None` as the default recommendation, allow `Front` as an optional anchor for Shot 1, and present clear warning badges regarding composition lock when a Starting Image is selected.

## D-020 (2026-08-09) CharacterBible Phase 6B — Production UX Specification Implementation
The Production UX specification approved in Phase 6A has been fully implemented across `FilmProject.swift`, `StoryboardView.swift`, `PromptInputView.swift`, and `StartingImageUXTests.swift`.

1. **Default & IA**: Starting Image defaults to `None (Recommended)`. The candidate menu categorizes reference assets into `Recommended Anchor (Front)`, `Other Views (Side / Back)`, and `Advanced (Face / Close-Up, Expression, Costume Detail)`. Raw Character Sheets remain strictly excluded.
2. **Terminology & Wording**: Trait locks use non-guarantee continuity names (`Facial Features`, `Hair`, `Eyes`, `Body Appearance`, `Costume`, `Accessories`) under section header `Keep Consistent`. Identity lock terms (`Face Lock`, `Identity Lock`, `Same Face`, `Same Person`, `Identity Reference`, `Multi-view Identity`) remain zero across all user-facing code and docs.
3. **Warnings & Assistance**: Displays inline camera freedom guidance, framing constraint warning for Face images, and `AspectMismatchCalculator` warnings for aspect ratio/orientation mismatch (threshold >=20%) without blocking video generation.
4. **Missing Asset Safety**: Missing starting image files on disk retain user selection, present a red `Image unavailable` badge with explicit `Clear` and `Change...` buttons, and fail preflight (`CoordinatorError.startingImageUnavailable`) to block silent T2V fallback.
5. **Shared Workflow UX**: Storyboard and Hybrid workflows share identical UI elements and missing asset behavior. Generate and One Shot remain unmutated with legacy `CharacterProfile`.

## D-021 (2026-08-09) Phase A1 First Run / Dependency Onboarding Architecture
Centralized dependency health checking (`DependencyHealthManager`) replaces fragmented launch alerts (`showPythonSetupAlert`, `showLaunchPackageUpgradePrompt`) and ensures non-blocking app onboarding.

1. **Required vs Optional Dependencies**: Python Environment, FFmpeg, Video Model, and Text Encoder are classified as Required for video generation (`isGenerationReady = true` when all 4 are `.ready`). Ollama (Local Director) and Local Vision are classified as Optional and do not block Generation readiness.
2. **Subprocess Python Validation**: Phase A2 accepts Python 3.11+ (the backend package minimum) and probes `mlx_video.generate_av` plus the LTX text-encoder import. It does not gate MLX video on unrelated PyTorch or diffusers imports. Invalid saved paths recover through non-mutating `autoDetectPython()`.
3. **No Silent Mutations**: Managed Python environment installation/upgrade (pip/Homebrew/bundled binaries) is deferred. The app never runs `sudo`, silent `pip install`, `brew install`, or background model/encoder downloads.
4. **Unified Generation Gating**: All video generation triggers across all UI views (Generate, Add to Queue, Batch, One Shot, Storyboard Take, Generate Missing Takes, Regenerate Selected Shots, Hybrid auto generation, Retake, History) check `isGenerationReady` and present `SetupWizardView` when required dependencies are missing.
5. **App Exploration Unblocked**: Missing dependencies only block video rendering actions. Users may dismiss `SetupWizardView` ("Continue to App") to browse Archive, existing Projects, CharacterBible, and Settings.

## D-022 (2026-08-09) Phase A2 Thin Client distribution boundary
v1 direct distribution is a thin client: external isolated Python with
`mlx-video-with-audio` 0.1.36, external FFmpeg, and external Hugging Face model
and encoder caches. The app bundles none of those assets. App Sandbox remains
OFF for direct Developer ID distribution; Hardened Runtime remains ON with an
empty entitlement set and no CS exceptions. Local-test packaging is an explicit
ad-hoc Release artifact only. Distribution mode requires a valid Developer ID
Application identity and notary credentials before replacing generated
artifacts, then requires accepted notarization, stapling, and Gatekeeper checks.

Normal validation and generation readiness do not mutate Python environments or
start package/model downloads; any setup mutation is a visible user action.

## D-023 (2026-08-09) Preset preflight must use the final settings resolver
Quick Preview previously resolved correctly at the execution boundary, but the
Generate UI's memory-risk gate and queue could still describe stale Custom
parameters. This made a Quick label appear alongside 512×768 / 121-frame /
30-step warning values. `GenerationSettingsResolver` now supplies a best-effort
preflight resolution to every queue producer and to Generate's display/warning
logic; `GenerationService` repeats resolution immediately before the backend
call so current memory state remains authoritative. The fallback is deliberately
non-blocking: an unexpected preflight failure preserves the original request
and the execution boundary reports a real error. Storyboard creation retains
the selected preset's dimensions except when Custom is explicit. This does not
change the QualityProfile ladder, model/encoder selection, rendering command,
or packaging policy.

## D-024 (2026-08-09) Generate is direct generation; One Shot owns directed single-scene input

Generate remains the direct T2V/I2V production surface and must not contain a
second One Shot planning experience. One Shot owns the short brief, local
Director planning, and one optional `Starting Image`. Its image preference is
independent from Generate so navigation cannot leak stale source-image state.

The Starting Image is explicitly temporal first-frame conditioning. It reuses
`GenerationRequest.sourceImagePath` and the existing MLX I2V adapter; it is not
a CharacterBible reference, identity lock, multi-image set, or new backend
capability. Text-only One Shot is represented by a nil image path. A non-nil
path must resolve to a readable decodable image both before planning and just
before queue insertion. Missing or invalid state is actionable failure, never
an implicit downgrade to T2V; only explicit Clear returns to text-only.
