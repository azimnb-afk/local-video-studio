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

## D-006 (2026-08-08) useLocalMlxVideoRepo pref is stale
User pref useLocalMlxVideoRepo=1 but ~/projects/mlx-video-with-audio does not exist; bridge logic falls back to pip package (0.1.36). No action needed; noted for support.

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
