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

## D-025 (2026-08-09) Sidebar navigation loss was detail-column size inflation, not scroll state
Symptom: the sidebar showed only Queue/Model Status; Generate / One Shot /
Storyboard / Hybrid / Video Archive were clipped above the visible window area,
while remaining present in the accessibility tree.

Measured root cause: the detail views embed AppKit-backed `HSplitView`s
(Generate, Storyboard, Video Archive, Character Reference). `NSSplitView`
reports its arranged subviews' intrinsic content height rather than accepting
the proposed viewport height, so the enclosing `NavigationSplitView` was laid
out at that intrinsic height. Evidence: the saved split-view geometry was
`328×1685` / `1680×1685` inside a `1680×948` window, and switching to the
`One Shot` tab — the only detail view with no `HSplitView` — produced
`328×948` / `1680×948` with identical sidebar code. The oversized layout is
bottom-anchored, so the top of BOTH columns was pushed above the content area.

Rejected hypotheses, with evidence:
- ScrollView restoration / scroll offset: the sidebar was not scrolled; the
  whole layout was oversized, and the detail column's header was clipped too.
- Saved split-view state corruption: deleting the autosave key **while the app
  was fully quit** still regenerated 1685 on the next launch, and the app wrote
  1685 on quit, so the value reflects live layout rather than stale state.
- Window tab bar: the tab bar was visible in both the broken (Generate) and
  working (One Shot) cases, and the fix holds with the tab bar ON and OFF.

Fix: the detail column is wrapped in a `GeometryReader` and clamped to the
offered viewport, so an inner AppKit split view can no longer inflate the
window layout. The sidebar additionally pins primary navigation outside the
scroll area and clamps to the same viewport, satisfying the invariant that
navigation stays anchored regardless of how much Queue/Model Status content
grows. No fixed pixel sizes, delayed `scrollTo`, or per-launch UserDefaults
deletion are used. Change is confined to `ContentView.swift`.

## D-026 (2026-08-10) Hybrid is presented as Auto Movie (Sora 2-like)
The workspace that turns one idea into several connected shots is now called
Auto Movie (Sora 2-like) in the sidebar, page header and bilingual description.
Only presentation changed: the `hybrid` enum case, the `"hybrid"` workflowMode
value, persistence keys and schema identifiers are unchanged, so existing
projects keep loading and are still recognised as automatic runs. The tab's
raw value changed, so a user who had that tab selected reopens on Generate
once; tab selection is transient UI state, not project data.

## D-027 (2026-08-10) Auto Movie queues one shot at a time
Hybrid previously queued every shot upfront in a single loop. That cannot work
with continuity, because shot N+1's starting image only exists after shot N has
rendered. `AutoMovieRunCoordinator` now enqueues exactly one shot, and the run
advances from `GenerationService` as each take completes. Generation
concurrency stays 1, and the dependency order (render → extract frame →
enqueue next) is explicit rather than implied by queue position.

## D-028 (2026-08-10) Continuity chain reuses the existing single-image I2V bridge
Continuity between consecutive shots is implemented by extracting the previous
shot's final usable frame and passing it as the next shot's
`GenerationRequest.sourceImagePath` — the same bridge the Starting Image
feature already uses. No new model conditioning, no video-to-video, no
multi-frame conditioning, no new media dependency: frames are extracted with
the FFmpeg binary already required for assembly.

Seek offsets are derived from the real probed duration and clamped to stay
inside the clip, so a 1-second take never seeks before its first frame. Three
strategies are tried in order (end-relative seek, absolute seek, full decode)
and the output is validated as a non-empty PNG before it is ever handed to the
renderer.

This improves visual continuity of person, wardrobe, location and lighting. It
is explicitly **not** identity conditioning and is never described as face or
identity lock; the same person is not guaranteed.

## D-029 (2026-08-10) Continue/Cut, and "if unsure, cut"
Chaining every shot would drag composition, camera position and pose across
intentional scene changes and prevent establishing shots. Shots therefore carry
a continuity mode. The Director schema gained an optional `"continuity"` field
("continue"/"cut"); missing or unknown values become `auto` and are resolved
deterministically at generation time.

The deterministic rule cuts on any scene-change directive, a different location
or time of day, a different cast, or a widening establishing shot, and requires
*positive* evidence of the same scene (same non-empty location or same
non-empty cast) before continuing. Absence of evidence is not evidence of
continuity, so unknown cases cut. The first shot is always a cut. The Auto
Movie duration-splitting path is the one place that marks shots as continuing
directly, because those beats are one continuous action split by construction.

## D-030 (2026-08-10) Starting image precedence and no silent text-to-video fallback
Precedence is: the shot's explicit user/CharacterBible starting image, then the
inherited continuity frame, then plain text-to-video. Continuity never
overwrites a user's own choice.

A shot that is supposed to continue but whose inherited frame is missing,
unreadable or zero-byte is **blocked with a reason** and surfaced in the UI. It
is never quietly rendered as text-to-video, because that would silently produce
a discontinuous shot that looks like a model failure. Blocked shots also
prevent automatic assembly.

## D-031 (2026-08-10) Automatic assembly fires once per completed run
Assembly is triggered from the run advance, not per shot. It requires every
shot to have a usable take, nothing in flight, no blocked continuity, and a
non-ambiguous selection. A take-identity signature of the ordered selected
takes is persisted; assembly is skipped when the signature is unchanged, which
makes the trigger idempotent across re-entry, resume and manual retries.

A single completed take is auto-selected. Several completed takes with no
selection stay ambiguous on purpose: the app does not rank takes for the user
(AI best-take selection is explicitly out of scope). Failures and cancellations
block assembly. Storyboard keeps manual generation and manual continuity, but
also receives the one automatic assembly when its last shot lands.

Store access stays on the main actor; only the blocking FFmpeg work is moved
off it, and the result is written back on the main actor.

## D-032 (2026-08-10) Continuity image strength is 0.8, measured not guessed
`--image-strength` semantics were verified in the backend source rather than
taken from its help text, which is inverted relative to its own implementation.
`mlx_video/conditioning/latent.py` computes `denoise_mask = 1.0 - strength` and
blends `denoised * mask + clean_latent * (1 - mask)`, so **1.0 pins the
conditioned frame to the source image exactly** and lower values give the model
room to recompose. The app's UI label ("1.0 = exact first frame") is correct;
the backend docstring ("1.0 = full denoise") is not.

Calibrated on one isolated transition — same source frame, prompt, seed,
resolution, frames, steps, model and encoder; only the strength varied —
scoring SSIM against the inherited frame:

| strength | SSIM(source, first) = anchor | SSIM(source, last) = leakage |
|---|---|---|
| 1.0 | 0.966 | 0.931 |
| 0.8 | 0.952 | 0.827 |
| 0.7 | 0.943 | 0.835 |
| 0.6 | 0.930 | 0.819 |
| 0.4 | 0.891 | 0.806 |

Going from 1.0 to 0.8 captures 0.105 of the total 0.125 available progression
for 0.014 of anchor. Below 0.8 the shot does not progress further — 0.7 moved
*less* than 0.8 — while the anchor keeps weakening and, by 0.4, the character's
hair and face visibly drift. 0.8 is therefore the knee of the curve, and is
defined once as `AutoMovieRunCoordinator.continuityImageStrength`.

Scope: the value applies **only** to a frame inherited from the previous shot.
An explicit user or CharacterBible starting image, Generate's manual I2V, One
Shot and Storyboard all keep the existing exact-first-frame behaviour, and cut
shots and the first shot are unaffected. The effective value is snapshotted in
each Take's `settingsSnapshot`, so runs stay reproducible without a schema
change.

## D-033 (2026-08-10) Prompt camera direction is a separate factor from strength
Composition leakage has two independent causes. With strength and source frame
held constant at 0.8, a shot prompt ending in "steady camera" produced an
end-frame SSIM of 0.953 against its inherited frame, while a prompt asking the
camera to push in produced 0.911. A prompt that asks for no camera movement will
therefore hold composition regardless of strength.

This is why the calibration harness and the three-shot end-to-end script differ:
the calibration prompt requested a camera move and showed clear progression at
0.8, while the end-to-end script's hand-written prompts said "steady camera" for
every shot and progressed less. The app itself is better placed than that
script, because `PromptCompiler` emits a per-shot
"{scale} shot, {angle} angle, {movement} camera" line and the Auto Movie split
path already varies scale and movement between consecutive shots.

No Director or PromptCompiler change was made for this: the finding is recorded
so a future camera-progression improvement is not mistaken for a strength
regression.

## D-034 (2026-08-10) Repeated composition came from a repeated action, not the camera
Auto Movie shots looked static because the split path reused the brief verbatim
for every beat:

    shot.summary = "\(source.summary) — story beat \(index + 1) of \(desiredCount)."

and `PromptCompiler` feeds `shot.summary` straight in as the action, so every
shot described the same moment. The other candidates were checked and cleared
first: the split path already varied scale and movement, `PromptCompiler`
passes the camera plan through unchanged, the app never emits "steady camera"
anywhere (that string came from an earlier hand-written test harness, not the
product), and `ContinuityEngine.promptContext` only carries location, time,
weather, lighting and outfit — it never constrains framing.

`AutoMovieBeatPlanner` now gives each beat a distinct stage: the opening keeps
the brief because it renders text-to-video, and later beats state how the action
moves on. Continuing beats are deliberately short, because they render
image-to-video from the previous frame and the scene already arrives in the
image; restating it only fights the picture and inflates the prompt.

## D-035 (2026-08-10) Camera follows the beat, and stillness stays available
The planner picks scale, angle and movement per beat — establishing wide, moving
middles, a closer resolution — instead of cycling fixed lists. Angle is now
varied too, because holding one angle for three shots trips the existing
monotony rule. A static camera is deliberately kept in the vocabulary for the
resolving beat: stillness is a choice the beat can call for, not something to
ban.

`ContinuityEngine.repeatedActionWarnings` adds a small deterministic check for
consecutive shots that describe the same action or lead with the same verb. It
warns only, and is not a new QC subsystem: no generated video is inspected and
nothing is regenerated automatically.

## D-036 (2026-08-10) Director instructions separate world continuity from framing
The planning prompt now requires each shot to advance to a new visible state and
forbids restating the previous action. It states that a continuing shot keeps the
character, clothing, place, light and props but NOT the framing, asks for one
primary camera idea per shot, keeps a static camera valid when the beat calls for
it, and prefers a cut when the story genuinely moves — outside to inside opens
with its own establishing shot.

Sampling the local Director three times showed a second problem: with the
conservative "when unsure, cut" rule alone it marked every shot "cut", which
would mean the continuity chain never engages. A worked example showing a
cut/continue/continue/cut sequence rebalanced it without swinging back to
always-continue, which was the original leakage failure.

Continuity strength is unchanged at 0.8 and this work touches Auto Movie only:
Generate, One Shot, Storyboard manual shots and explicit Starting Images keep
their existing behaviour.

## D-037 (2026-08-10) Local AI planning needed a larger response budget
The richer planning instructions made the Director's JSON longer, and at
Ollama's default response budget a four-shot plan intermittently came back as
truncated JSON — which burned the repair attempts and silently dropped the run
to the Basic Director. The request now sets `num_predict` explicitly; three
consecutive samples then returned valid plans. This is a reliability fix for a
regression risk introduced by the longer instructions, not a new feature.

## D-038 (2026-08-10) Continuity Reconciliation: the Director owns the story, not the hand-off
Measured sampling showed the local planner marking an entire continuous scene as
cuts (0/3 plans with a continuation under the conservative rule, 2/3 with a
worked example, 2/4 with stronger wording). When every boundary is a cut nothing
is inherited, and a real four-shot run produced a dark-haired woman in black, a
woman in silver armour and a middle-aged man across one scene. Prompt wording
alone did not fix this reliably, so the fix is a deterministic pass rather than
more instruction text.

`ContinuityReconciler` runs once, on the finished shot plan, inside the Auto
Movie coordinator only. It uses the Director's own structured metadata:
per-shot `explicitChanges`, the cumulative `ContinuitySnapshot` (location, time,
weather, story state) and the cast. Cast evidence prefers stable CharacterBible
identifiers and falls back to the planner's own continuity-state character keys,
because a project without a Bible resolves `shot.characterIDs` to empty — the
keys are structured planner output, not a guess pulled out of prose.

Promotion requires positive evidence on both axes: the same non-empty location
AND the same non-empty cast. One signal alone is not enough, and absent metadata
keeps the conservative cut. Any of these keeps the planned cut: an explicit
`location=`/`timeOfDay=`/`weather=` directive, differing scene state, a differing
cast, a story-state jump between two stated states, or a shot that crosses an
interior/exterior threshold.

The pass only ever promotes `cut` to `continue`. It never demotes a planned
continuation, never touches the first shot, and never overrules an explicit
scene change. Storyboard, One Shot and Generate are untouched.

## D-039 (2026-08-10) A framing change is not a scene change
Shot scale, angle and camera movement are deliberately excluded from the
promotion conditions. Requiring them to match would put continuity in direct
conflict with the cinematic progression added in D-034/D-035, and it is
unnecessary: inheriting at the calibrated 0.8 already leaves the camera free to
move. A wide approach followed by an extreme close-up insert of the same moment
is a continuation, and is promoted as one.

The interior/exterior check reads the shot's own summary and title first and
only falls back to the recorded location, because the case it exists for is a
shot that has moved indoors while the location string still names the old place.
A test caught the opposite ordering silently cancelling itself out.

## D-040 (2026-08-10) Reconciled decisions are persisted and explainable
`Shot` gained two optional fields: `plannedContinuityMode` (the Director's raw
decision) and `continuityReconciliationReason`. `continuityMode` remains the
effective value, so generation, the continuity chain and the shot badge all keep
reading one field and needed no change. A reload therefore reproduces the same
behaviour and still shows that the Director asked for a cut and why the boundary
was promoted. Projects saved before this decode unchanged.

Measured effect on real plans for the same brief: raw `cut,cut,cut,cut,cut`
became `cut,continue,continue,continue,cut` — and the closing interior shot
correctly stayed a cut. Plans that already contained continuations were left
untouched.
