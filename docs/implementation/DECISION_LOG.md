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

## D-041 (2026-08-10) Adaptive Continuity Strength: policy is separate from the cut decision
`ContinuityReconciler` answers "should the previous look carry over"; the new
`ContinuityStrengthResolver` answers "how hard should it hold". Framing is read
only by the second question and never feeds back into the first, so a large
camera change still cannot turn a continuation into a cut.

Two policies, not a continuous curve: `standard` for an ordinary continuation and
`reframe` for a large framing jump. Classification uses the Director's own
shot-scale vocabulary as an ordered ladder (extreme-wide → wide → medium-wide →
medium → medium-close-up → close-up → extreme-close-up); a jump of three rungs
or more in either direction is a reframe. Angle and camera movement are
deliberately excluded because they do not change how much of the subject fills
the frame. Unrecognised vocabulary falls back to whether the shot describes a
detail insert. The resolver applies only to an Auto Movie inherited frame, after
CONTINUE is already decided, and never to an explicit user or CharacterBible
starting image, Generate, One Shot or Storyboard.

## D-042 (2026-08-10) Reframe strength is 0.5, and it does not buy a reframe

> **SUPERSEDED IN PART by D-052 (product-profile revalidation).** Everything
> below was measured at 512x320 / **25 frames** (1.04 s). Re-measured at
> 768x512 / 121 frames, 0.5 *does* buy a reframe: a medium-wide inherited
> frame reaches a genuine close-up with continuity intact, while 0.8 does
> not. The 0.5 value survives; the stated reason for it does not. The
> original measurements are kept below exactly as recorded.
Calibrated on the real failure: a medium-wide full figure inherited into a
planned close-up of a key entering a lock, same source frame, prompt, seed and
settings, only the strength varied.

| strength | SSIM vs inherited | reframed? | coherent? |
|---|---|---|---|
| 0.80 | 0.935 | no | yes |
| 0.65 | 0.909 | no | yes |
| 0.50 | 0.871 | no | yes |
| 0.35 | — | no | yes |
| 0.20 | — | partly | no — a hand pasted over the old composition |

No value in the usable range released the framing, and loosening degrades
coherence before it frees composition. A control render of the same prompt with
**no inherited image at all** did not produce the insert either: it produced a
different woman indoors. A second case asking only for a face close-up behaved
the same way at both 0.8 and 0.5.

So the detail-insert failure is a model/duration limit at this profile
(512×320, 25 frames, 15 steps), not a strength-tuning problem. This is recorded
as a genuine limitation rather than being declared a success.

0.5 is nevertheless adopted as the reframe value: it is the loosest setting that
preserved the person, wardrobe and set in every sample, so it gives the renderer
the most room where the plan asks for a big framing change. What it buys is
measurably more freedom, not a guaranteed reframe.

Standard continuity remains 0.8 and no user-facing strength control was added.
A per-shot continuous strength curve was deliberately not introduced: with no
measurable framing benefit across 0.8–0.35, finer granularity would be tuning
noise.

## D-043 (2026-08-10) Capability-Aware Shot Planning steers the plan, before generation

The previous round established that a planned detail insert could not be reached
by any conditioning strength, and that the same prompt failed even with no
inherited image. That leaves one honest lever: stop planning the shot.

`CapabilityAwareShotPlanner` runs once, on the Director's draft, inside Auto
Movie only. It classifies each shot as `normal` or `highRisk` — two levels, not
a score, because the measurements do not support finer precision — and where a
shot is high risk it plans a framing that renders instead. The narrative beat is
never deleted: a key still goes into a lock, at body scale rather than as a macro
insert.

Four rules, each traceable to something measured:
- a framing jump of three or more rungs at a boundary that inherits a frame;
- the tightest rung on the ladder (a detail insert);
- a hand or finger operating something described as small;
- four or more action clauses in one short take.

Close-ups are deliberately not banned. A close-up reached from a medium shot is
a two-rung step and is planned exactly as the Director asked. What the pass
targets is the combination that failed: a large jump, into detail, off an
inherited frame.

The pass runs on the draft rather than on built shots so the camera fields, the
compiled prompt and the persisted plan all describe the same effective shot —
compiling first and rewriting afterwards would have left the prompt asking for a
framing the plan no longer intended.

Placement relative to reconciliation is a non-issue by construction:
reconciliation reads location, time, cast and story state, never framing, so its
decisions are identical whichever order the two passes run in. Confirmed by a
test that reconciles the same scene at two very different framings.

## D-044 (2026-08-10) One ladder, one definition of a large reframe

`ShotScaleLadder` now owns the seven-rung scale vocabulary and its ranking, and
both `ContinuityStrengthResolver` and the capability planner use it. The largest
jump the planner will allow an inheriting shot is derived as
`reframeRankDistance - 1` rather than chosen independently, so the two passes
cannot drift into disagreeing about what "a large reframe" means.

This makes the relationship between the two features explicit: capability
planning is the first defence and tries to avoid planning a large reframe at
all; adaptive strength is the fallback that loosens the anchor for the reframes
that survive — for example one the user asked for themselves. Standard strength
stays 0.8 and the reframe fallback stays 0.5; neither was recalibrated.

The split-beat ladder in `AutoMovieBeatPlanner` is held to the same bound. A
two-beat movie previously went straight from wide to close-up, a four-rung jump
across a boundary that always inherits.

## D-045 (2026-08-10) Framing the user asked for is not rewritten

When the brief itself names a tight framing ("extreme close-up", "macro shot",
「マクロ」), the pass records the shot as high risk and changes nothing. An
automatic feasibility policy should not delete a visual choice the user made
deliberately; the shot may fail, but that is the user's stated intent, and the
reason is recorded either way.

The check is brief-level and therefore coarse — it stands the pass down for the
whole plan rather than for one shot. Distinguishing per-shot user intent would
need the brief to be attributed to individual shots, which is a schema change
this MVP does not justify.

`Shot` gained two optional fields, `originalCameraScale` and
`capabilityAdjustmentReason`, so a reloaded project still shows what the Director
asked for and why the effective plan differs. Old projects decode unchanged and
report no adjustment.

## D-046 (2026-08-10) The beat-progression failure was a harness artifact

Every previous Auto Movie E2E hard-coded 25 frames. The product never renders a
planned shot at 25 frames: each shot's `durationSeconds` becomes
`targetDurationSeconds`, and `AutoQualityEngine` converts it through
`PromptCompiler.frameCount` (8n+1), so a 5 s shot is 121 frames. A real
persisted project confirms 121 frames / 5.01 s per take.

So the harness was rendering 1.04-second shots and we were reading the result as
"CONTINUE cannot advance the narrative". A controlled comparison on the exact
failing boundary — identical source frame, prompt, seed and settings, frames the
only variable — scored 0 at 25 frames and 2 at 121 frames, with the framing
genuinely moving wide → close-up and continuity intact.

The lesson is procedural: the verification harness must derive its parameters
the way the product does, not restate them as constants. The frame count is now
computed per shot by a documented mirror of `frameCount`, and the one remaining
deliberate difference (512×320 for turnaround, versus the product's 768×512) is
named in the script and overridable.

## D-047 (2026-08-10) No production change from this calibration

Five conditions were compared on one boundary. Longer CONTINUE is the only lever
that moved the result — and the product already gives CONTINUE shots their full
planned duration, so there is nothing to implement. Adding a "dynamic duration"
feature would have been building a fix for a defect that only ever existed in
the test harness.

Rejected with evidence rather than by preference:
- **More steps**: `mlx_video` uses fixed stage sigmas for unified models and
  ignores `--steps`. 15 and 30 produced byte-identical output. As a side effect
  the app's per-preset steps values are inert on this model path; left alone
  here because changing preset semantics is out of scope for a calibration.
- **Strategic CUT**: text-to-video renders the beat perfectly and loses both the
  character and the location. That is precisely the cost the continuity design
  exists to avoid.
- **Beat boundary planning**: a source frame that already placed the subject at
  the door did not improve on the ordinary one, so shot boundaries are not the
  constraint.

Capability-Aware Shot Planning, Continuity Reconciliation and the 0.8 / 0.5
strengths are all unchanged; nothing in this round contradicts them.

The residual, newly isolated limitation is recorded rather than patched: the
first shot's composition propagates through the entire inherited chain, so a
weak opening framing cannot be recovered by later shots.

## D-048 (2026-08-10) The opening anchor is one deleted clause, not added guidance

The hypothesis was that a weak opening poisons the whole continuity chain,
because every later shot inherits the opening's final frame. Confirmed: an
opening that ends with the protagonist a few pixels wide produced a Shot 2 in
which she drifted to the frame edge, while an opening that ends with her at
usable scale produced a Shot 2 that kept her.

What is *not* confirmed is the obvious remedy. Three interventions were compared
against the Director's own opening: composition guidance ("stays clearly
visible, entrance visible ahead"), a dictated ending state ("ends with her
standing close to the doorway"), and simply deleting the clause "her figure
small against the towering walls" while adding nothing. All three improved on
the baseline, and **deletion alone was as good as either**. The added language
was therefore not the mechanism, and none of it ships.

So `CapabilityAwareShotPlanner` now removes subject-miniaturizing phrases from
the Auto Movie opening shot only, and does nothing else. Camera scale is never
touched, so a wide or extreme-wide establishing shot survives exactly as
planned; the subject is not turned toward the camera; no ending state is
imposed. Walking away from the camera stays perfectly acceptable — what the rule
targets is a protagonist who is *unreadable*, not one who is facing away.

The machinery already existed and simply never reached this shot: "small" was
already in the planner's miniaturizer list, but removal only ran for `highRisk`
shots, and a wide establishing shot is correctly classified `normal`. The fix is
that the opening gets this one correction regardless of its risk class, because
its final frame is the whole chain's input.

Where the brief itself asks for the small-figure look, nothing is changed —
consistent with D-045. Confirmed at 768×512 with the product's 121-frame shots,
not only at the calibration resolution.

## D-049 (2026-08-10) Historical 25-frame results kept, but scoped

Earlier documents generalised from runs made under the 25-frame harness, which
the Beat Feasibility Calibration showed was rendering 1.04-second shots. Those
measurements are real and are kept — they are not deleted or rewritten — but the
claims that read as general model limits now say which harness produced them.
Evidence history stays intact; only its stated scope was corrected.

## D-050 (2026-08-10) Destination anchoring rejected: it was a resolution artifact

The previous round ended by naming destination readability as the next
bottleneck — it had scored ~1 in every opening condition. This round tested six
destination wordings and found the score was a property of the 512×320 Compact
profile those conditions were measured at, not of the plan.

At 768×512 — the resolution Standard and High actually ship — the current,
unmodified wording "toward the library entrance" renders a clearly readable
door, the protagonist approaches it, and the following shot arrives and stops at
it. There is nothing to fix.

At 512×320 the interventions did make the target more readable, and made the
result worse. Explicit destination wording bought a visible door by shrinking
the protagonist into the background; protecting the protagonist as well reversed
her direction so the door left frame entirely by the next shot. The two anchors
compete for a frame that small.

So no destination policy ships. Adding one would have optimised a low-resolution
artifact at the cost of the protagonist readability the previous round had just
established, and it would have fired hardest exactly where it helps least.

The Director's structured metadata that a policy would have used —
`position:<Character>=` directives and `props` — is real and remains available
if this question returns for a better reason. No schema was added.

## D-051 (2026-08-10) Calibrations that score world objects must run at 768×512

A methodological consequence, recorded so it is not rediscovered. Subject-level
findings reproduce at both resolutions: the opening anchor behaved identically
at 512×320 and 768×512. Object-level findings do not — Compact renders doors,
panels and similar interaction targets materially worse.

Turnaround pressure pushed earlier rounds toward 512×320, and that is fine for
anything about the protagonist or about motion. Anything scored about objects in
the world is now either run at 768×512 or reported with the profile named as a
limit. The affected earlier statement has been scoped in BENCHMARK_RESULTS
rather than deleted.

## D-052 (2026-08-10) Large camera reframes are feasible; the old limit was the harness

D-041/D-042 concluded that no conditioning strength achieves a large reframe.
That was measured at 512×320 / 25 frames — 1.04-second shots, a configuration
the product never renders. Re-measured on one fixed source frame at the product
profile (768×512, 121 frames, seed 42, only `--image-strength` varying):

| strength | 768×512 / 121 f |
|---|---|
| 0.8 | no reframe — the subject stays full-figure and walks away |
| 0.65 | close-up achieved, continuity intact |
| 0.5 | close-up achieved, continuity intact |

Duration is the dominant factor: at 25 frames nothing reframes at any strength,
because there is no time for a camera move. Resolution modulates it — at
512×320 even 0.8 reframes, so the standard anchor holds composition more firmly
at the higher-quality profiles.

The conclusion splits in two, and only one half survives. A large **camera**
move is supported. **Fine object interaction** is not: at 0.5, the shot reframed
to a clean close-up and the planned hand-to-door-handle action still never
happened. The original finding was right about the insert and wrong about the
framing.

`Standard = 0.8` and `Reframe = 0.5` are both kept. 0.5 is validated, though for
the opposite reason to the one recorded in D-042: it does buy the reframe.
0.65 also works, with no measurable advantage over 0.5, so nothing was changed
on the strength of a single sample.

## D-053 (2026-08-10) The capability clamp was cancelling the reframe strength

A defect this revalidation exposed. `CapabilityAwareShotPlanner` clamped any
framing jump of three or more rungs down to two, on the belief that large
reframes were impossible. `ContinuityStrengthResolver` then measured the
*clamped* distance, saw two rungs, and selected the standard 0.8 — the one
setting now measured **not** to reframe at 768×512. So a shot the Director
planned as a close-up received neither the framing it asked for nor the strength
that would have delivered it. Visible in the previous run's log: a planned
`medium-wide → close-up` became `medium-close-up`, then `strength policy:
standard @ 0.8`.

The fix is to delete the rule, not to add another. A large framing jump is no
longer classified as a capability risk, so it reaches the resolver at its true
distance and gets 0.5. The detail-insert, fine-manipulation and too-many-beats
rules are untouched — those are the ones re-measurement confirmed.

`maxInheritedRankJump` survives only as the smoothness bound on the no-LLM beat
ladder, and its documentation now says so rather than implying a feasibility
limit. Continuity Reconciliation, the Opening Shot Anchor and both strength
values are unchanged.

Known remaining gap, recorded rather than patched: a shot clamped for
*detail-insert* reasons is still handed to the resolver at its reduced distance
and so still receives 0.8. Making the resolver read the Director's original
framing intent (already persisted as `Shot.originalCameraScale`) would fix that,
but the combination was not measured, so it is not being shipped on inference.

## D-054 (2026-08-10) Detail-clamped shots keep the standard anchor

D-053 left one gap open: a shot clamped for detail reasons is handed to the
strength resolver at its reduced framing distance, so it receives the standard
0.8 rather than the reframe 0.5 its original intent implied. That was recorded
rather than fixed, because the combination had not been measured. It has now.

Measured on the shipping planner's own clamped shot — original
`extreme-close-up`, effective `medium-close-up`, reason "detail-insert framing;
fine hand/object manipulation" — from one source frame at 768×512 / 121 frames,
identical prompt, two seeds, with only the strength varying:

| | framing | interaction | character | environment |
|---|---|---|---|---|
| 0.8 | 2 | 0 | 3 | 3 |
| 0.5 | 2 | 0 | 3 | 3 |

Indistinguishable at both seeds. **No production change.** Strength keeps coming
from the post-clamp effective scale, and `originalCameraScale` stays a
persisted explanation rather than a resolver input.

The reason this does not contradict D-052 is worth stating, because it looked
like it would. There, 0.8 failed a *3-rung* framing request and 0.5 delivered
it. Here the clamp has already reduced the request to *2 rungs*, which 0.8
delivers on its own. The clamp lowers the ask to something the standard anchor
can satisfy, so the two passes are self-consistent. The suspected conflict was
an artifact of reasoning about the original intent rather than the actual
request, and measuring it was the only way to tell.

Experiment C (0.65) was not run: it is gated on an unclear tradeoff between 0.8
and 0.5, and there was none.

Fine object interaction still fails at both strengths. That limitation is
unchanged and is not a strength problem.

## D-055 (2026-08-10) Auto Movie v1: READY WITH KNOWN LIMITATIONS

Three unrelated briefs were run end to end at the full product profile
(768×512, 121 f per 5 s shot), one run each, no regeneration until something
looked good. 12/12 shots rendered, 3/3 movies assembled, no pipeline errors.

Every system-level component behaved: the Director produced sane plans, the
Opening Anchor fired on a real plan and only where needed, reconciliation
promoted exactly one boundary and left the others alone, the strength resolver
selected 0.8 and 0.5 correctly every time, continuity frames were extracted
with no silent fallback, generation stayed strictly sequential, assembly put
each shot in exactly once with frame counts matching the per-shot plans, and
real persisted projects round-trip their continuity metadata while legacy ones
still decode.

One case (the seaside plaza) is the strongest result the project has produced:
four beats, one man, one suit, one location, clean camera progression, no
artifacts. Two cases carry a coherence artifact — a pasted hand and a duplicated
subject — and in both the system chose the right strength, inherited the right
frame and planned a reasonable shot. Under the audit's own model-versus-product
rule those are model limitations.

No production code was changed. No defect appeared in two or more cases, which
is the bar this audit set for itself precisely to avoid the single-sample
overfitting that has bitten this project before.

Two single-case planner observations are recorded and deliberately left alone:
the fine-action verb list does not contain "grip", and the multi-beat rule
counts comma clauses so a facial-reaction description gets pulled wider than it
wants. Each appeared once. Neither is worth a rule change on one sample.

Classified **READY WITH KNOWN LIMITATIONS**: the pipeline is reliable, and what
remains unreliable is fine object manipulation, which four separate calibrations
have failed to move by duration, resolution, strength, framing or clamping.

## D-056 (2026-08-10) The Archive is history-driven, not directory-driven

Recorded because the audit surfaced it. `HistoryManager` reads `history.json`;
the Video Archive lists those entries rather than scanning the Videos folder.
Audit videos copied into the folder are therefore visible on disk and playable,
but do not appear in the Archive UI. `history.json` was deliberately not
edited — it is user data, and injecting synthetic entries risks corrupting a
real library for cosmetic completeness.

## D-057 (2026-08-10) Opening Character Anchor: implemented, optional, off by default

A requested feature: let an Auto Movie start from a CharacterBible reference so
the protagonist's appearance has a stronger starting point, with the existing
continuity chain carrying it forward.

Implemented as project-level state (`FilmProject.characterAnchor`) resolved at
generation time, not as a per-shot field. Source precedence in
`TakeGenerationCoordinator` is explicit and ordered: a starting image the user
picked for the shot wins; then the anchor, **and only on shot index 0**; then an
inherited continuity frame; then text-to-video. Shots 2+ are untouched — the
reference is never re-injected, which is the single most important regression
this feature could have introduced and is covered by a dedicated test.

No second image path was built. The anchor rides the existing
`sourceImagePath` bridge that One Shot and explicit starting images already use.

A missing character, a missing asset or a missing file each raise a distinct,
actionable error and block the shot. Silently rendering a different-looking
protagonist is exactly the failure this feature exists to prevent, so the
project's no-silent-fallback rule is extended rather than excepted.

## D-058 (2026-08-10) The anchor reuses the Starting Image strength, because weakening it measured worse

The pre-measurement assumption was that a character sheet needs a weaker anchor
than a user-picked frame, and 0.45 was written into the code before testing. The
calibration overturned that.

The backend always blends the conditioning image into frame 1. Lowering the
strength therefore does not trade "reference" for "scene" — it trades a clean
reference for a corrupted one. At 0.45 the opening frame is still the plate; at
0.25 and 0.15 it is a smeared, torn plate. And at no strength, including 1.0,
did the reference's costume or face carry into the body of the shot.

Since there is no value that produces a good opening from a flat sheet, the
shipped behaviour is the simplest defensible one: the same 1.0 an explicit
Starting Image already uses. One behaviour for "an image the user picked",
rather than two that differ for no measured reason.

The honest limitation is documented rather than papered over: with a
character-sheet extraction the movie opens on the reference and then moves into
the scene, and identity carry-over was not observed. The feature remains useful
as a Character-Bible-driven starting image, and is off by default so no existing
project's output changes.

## D-059 (2026-08-11) Opening Reference Image: the picture is the opening frame

The Character Anchor calibration established what a conditioning image actually
is on this backend: not an identity hint, but the movie's first frame. A
character-sheet extraction therefore put a posed figure on a flat plate at the
head of the film, and its costume and face were not carried into the shot that
followed.

This feature accepts that mechanic instead of fighting it. An Opening Reference
Image is a scene-like still the user picks — ideally already a plausible movie
frame, with the character, wardrobe, place and light in it — and the opening
shot begins on it. The better the picture already reads as a frame, the more
there is for the continuity chain to carry into shots 2, 3 and 4.

Kept deliberately separate from Character Anchor rather than merged into a
vague "reference" control, because the two answer different questions: *which
Character Bible asset* versus *which frame*. Precedence when both are set is
explicit — an explicit per-shot starting image, then the opening reference, then
the anchor, then text-to-video — and the UI says so where both are configured.
Clearing the reference hands shot 1 back to the anchor.

Shot 1 only. Shots 2+ inherit from the shot before them and never see the
reference, which is the regression this could most easily have introduced and is
covered by its own test.

The image is copied into the project (`Assets/OpeningReference/`) through the
same copy-then-atomic-move path `importCharacterSheet` already uses, so the
external original is never moved, renamed or persisted as an absolute path, and
a project keeps working after the source file moves. Replacing removes the copy
it supersedes rather than orphaning it. A missing file blocks generation with a
distinct error — it never silently becomes text-to-video and never silently
falls through to the Character Anchor.

Strength is the same 1.0 an explicit Starting Image uses. D-058 already measured
that lowering it corrupts the conditioning image rather than softening it, and a
deliberately scene-like still has even less reason to be treated more weakly
than any other frame the user picked.

## D-060 (2026-08-11) Character Anchor copy corrected, feature kept

The Character Anchor UI copy implied the reference established "the character's
appearance". Measurement showed the selected image *is* the opening frame,
plain background included. The copy now says that plainly and points users at
the Opening Reference Image for a cinematic opening. The feature itself is kept:
it remains the quickest way to start from a Character Bible asset, and its
behaviour is unchanged.

## D-061 (2026-08-11) Opening Reference belongs to movie creation, not to a shot card

The control shipped in the wrong place. It rendered in the project detail view
above the shot list, which reads as belonging to Shot 1, and it was only
reachable *after* the movie had already been planned and its first shot queued —
by which point choosing an opening image is too late to matter.

The Opening Reference is an input to the movie, so it now lives in the New Auto
Movie sheet alongside Brief, Preset and Target Duration. The sheet holds a plain
file URL while it is open and imports nothing; the managed copy is made only
when Create is pressed, so cancelling leaves no project asset behind.

Ordering is the part that had to be exact. `createProject` imports the image and
sets `project.openingReferenceImage` **before** `store.save(project)`, and the
first shot is queued after that save. Importing afterwards would have raced the
first render and produced a movie whose opening ignored the chosen image. A test
covers that order directly rather than trusting the call sequence to stay put.

An import failure at Create refuses to create the movie and says why, instead of
quietly producing a text-to-video opening the user did not ask for.

## D-062 (2026-08-11) Three image controls, told apart by where they live

Auto Movie now has three places an image can enter, and the risk is a user
confusing them. They are separated by scope and labelled accordingly:

- **New Auto Movie sheet — Opening Reference Image**: the primary path. Chosen
  before the movie exists.
- **Project page — "Movie Settings — Opening Reference Image"**: the same value
  after creation, for Replace/Clear. Its subtitle says it applies to the movie as
  a whole, not to any shot below it.
- **Shot card — "Starting Image (this shot only)"**: the pre-existing per-shot
  Character Bible override, untouched. Its help text now names the movie-level
  reference and states that the per-shot override wins.

Precedence is unchanged: explicit per-shot starting image, then opening
reference, then Character Anchor, then text-to-video.

## D-063 (2026-08-11) Global production queue sits above the existing render gate

`GenerationService` already renders one request at a time, for every mode, and
an Auto Movie already chains its own shots. So the queue did not need a second
renderer — it needed a *job* boundary.

Without one, two queued movies interleave. Each movie appends its next shot to
the shared render queue as the previous shot lands, so the order becomes A1, B1,
A2, B2. `ProductionQueueCoordinator` admits exactly one job's work at a time: a
movie renders every shot and assembles before the next job is allowed to start.

The coordinator is transport-agnostic — it decides what runs next and records
state, and hands the work to a runner closure. That is what makes the
single-active-job guarantee testable without a GPU, and the concurrency test
asserts a peak of one active job across completion, failure and cancellation.

Concurrency is fixed at one and deliberately not configurable. On Apple Silicon
a second concurrent render competes for the same unified memory and is the
fastest way to make both fail.

## D-064 (2026-08-11) Jobs are snapshots, not live references

A waiting job records what the user asked for at enqueue time: brief, preset,
model, seed, Director mode, and — for Auto Movie — the project-relative paths of
the Opening Reference Image and Character Anchor. Editing the project afterwards
does not reach into a job already in the queue.

Images are referenced by managed project-relative path rather than copied as
bytes: the copies are already owned by the project, so the reference is stable
and the queue file stays small. The path is resolved again at execution time, so
a file deleted while the job waited fails that job with a clear reason instead
of quietly opening the movie on a different-looking protagonist.

## D-065 (2026-08-11) A film job is finished by the project, not by an idle renderer

Found in a real run, not in review. The first completion rule was "the render
queue is empty, so the job is done". Between two Auto Movie shots the queue is
momentarily empty — the finished take has been removed and the next shot is only
appended once the run coordinator advances — so a movie was marked completed
while its second shot was still rendering. The next queued job would then have
started on top of it, which is exactly the interleaving the queue exists to
prevent.

Completion is now decided by the project: every shot has a completed take and an
assembled movie exists, or a shot failed. All shots rendered but no assembly yet
holds the job open under an "Assembling" stage. A regression test pins each of
those cases.

Persistence is atomic, and a single malformed record is dropped rather than
discarding the whole queue — losing one job is recoverable, losing an overnight
queue is not. A job recorded as running when the app quits restores as
`interrupted`: its render subprocess died with the process, so it is never
silently resumed or reported complete.

## D-066 (2026-08-11) A queue that watches only the renderer stalls on assembly

D-065 fixed *premature* completion. The real two-job run then exposed the
opposite failure: job A never completed at all. Its four shots had rendered and
`_final.mp4` was on disk, but the panel read "Assembling" for six minutes and
job B never started.

`ProductionQueueService` woke only on `GenerationService.$queue`. Final assembly
begins after the last take has already been removed from that queue, so the
render queue never publishes again — there was no signal at all for the one
transition that ends a film job. The queue was stalled for as long as the app
stayed open, which is precisely the unattended-overnight case the feature
exists for.

`GenerationService` now publishes a `FilmRunEvent` for run outcomes the render
queue cannot show: assembled, assembly failed, blocked, or settled with nothing
to assemble. The queue subscribes to that in addition to `$queue`. Outcomes are
addressed to a project, so one movie's result is never read as another's, and
the stored event is cleared when a job starts so a retry cannot inherit the
previous attempt's outcome.

Every outcome that means "no movie is coming" now **fails** the job rather than
holding it open. A job that cannot finish must not take the queue with it.

## D-067 (2026-08-11) Progress counted takes that are only selected at the end

The panel read "Shot 1 / 4" for an entire four-shot movie. Progress counted
shots whose *selected* take was completed, but `autoSelectUnambiguousTakes` runs
only when the whole run finishes, so mid-run the count is always zero.

It counts rendered takes now — the same thing the completion rule already looked
at. Both rules live in one pure decider, `FilmJobDecider`, so the shot the panel
shows and the shot the queue believes it is on cannot drift apart. Being pure,
it is checked directly in tests without a GPU, a renderer, or a main actor.

## D-068 (2026-08-11) Creating a movie jumped the queue instead of joining it

Found while exercising the panel: with two jobs queued while paused, they were
listed newest-first. Creating an Auto Movie called `enqueueNext`, which inserts
at the head of the waiting jobs — so three movies queued 1, 2, 3 would have run
3, 2, 1. It went unnoticed in the A/B run only because A was already *running*
when B was created, which put B behind it by luck rather than by rule.

Creating a job appends. `enqueueNext` stays, reserved for a deliberate "Generate
Now". "Queue three movies and go to bed" has to mean first, second, third.

## D-069 (2026-08-11) A Character Sheet can be time-evolved into a scene, if it fills the frame

The Character Anchor experiment established that a Character Sheet used directly
as a starting image yields a reference plate as frame 1. The Temporal Bridge
hypothesis was that time, not strength, is the missing variable: let LTX run for
five seconds and extract a later frame.

It works — with one decisive precondition. Two 768×512 bridges were run from the
same Adventurer Heroine Front reference, same seed, same prompt, differing only
in how the 287×774 portrait crop was fitted to the landscape frame.

Aspect-**fit** (figure centred on white padding) failed: a courtyard formed, but
only inside the 190 px column that held image content. The padding columns moved
by 0.2/255 from first frame to last and stayed at 252 while the centre moved by
77.75. Synthetic padding is inert — the model transforms content, not emptiness.

Aspect-**fill** (crop the band, no empty regions) produced a complete cinematic
courtyard by 25% of the clip, with hair, vest, belt, socks and boots intact.

Two working rules follow, and both are counter-intuitive enough to record:
`load_image()` hard-resizes with no aspect preservation, so any future feature
must aspect-**fill**, never pad; and the usable frame is **early-middle (~25%)**,
not late. Per-frame motion collapses to 0.01–0.04 after ~67%: the transformation
finishes and then stalls, so a longer bridge buys nothing.

## D-070 (2026-08-11) The bridge is not the bottleneck — reframe identity is

The bridge still was fed through the existing Opening Reference path and
compared against a T2V control on the same brief.

The bridge reference is clearly better: environment continuity 3 vs 1, opening
quality 3 vs 1, shot-to-shot continuity 2 vs 0. The control produced three or
four different women across four shots; the bridge run opened on the intended
character and kept one consistent figure.

But the Adventurer Heroine's actual identity is lost at shot 3 — the "looks over
her shoulder" reframe — leaving a generic cream-coated woman who is then stable
for the rest of the film.

Re-examining two earlier runs that used *hand-made* scene references shows the
same pattern, which is the useful part: a low-specificity character (man in a
dark suit) holds across all shots, while a high-specificity one (the blue-haired
girl) loses her defining trait after shot 1. So the ranking is
`T2V < Temporal Bridge ≈ manual scene reference`, not
`T2V < Temporal Bridge < manual scene reference`.

The Temporal Bridge produces a still about as useful as one a human would
prepare. The ceiling is the continuity chain, which carries composition,
environment and broad costume across a reframe but not facial identity. A better
still generator — Z-Image included — would improve shot 1 and not shot 3. That
is worth knowing before committing to it.

## D-071 (2026-08-11) The Director contradicts the Opening Reference in every prompt

Correcting D-070's attribution. The bridge-referenced Auto Movie was believed to
lose its protagonist at the shot-3 reframe. Reading the persisted project shows
something simpler and more fixable.

`CB BRIDGE C`'s auto-created Character Bible reads `name: "Character1",
defaultCostume: "Beige trench coat, dark jeans, boots"` with every appearance
field empty and no reference assets. The brief never named the Adventurer
Heroine, and **the Opening Reference image is never analysed into the Character
Bible**. So all five compiled prompts opened with
`CHARACTER 1: Character1. Current costume: Beige trench coat, dark jeans, boots.`

The beige trench coat was not drift. It was an instruction, present in shot 1
alongside an opening frame showing a navy-uniformed adventurer. Sampling shot 1
confirms a continuous slide rather than a break: full costume at 0%, cape
lengthening by 20%, navy vest gone by ~40%, a distant plain cream coat by 60%.
Shot 3 was simply the first close-up after identity had already gone.

Two further facts: shot 3 ran at `imageStrength 0.8`, the Standard value, so the
0.5 reframe profile was never exercised; and the continuity frame handed to
shot 3 is a wide plate in which the character is a ~30x80px figure seen from
behind, carrying no face, hair or costume detail at all.

The app already has a working local vision path — `CharacterSheetAnalysis` posts
image bytes to Ollama `/api/generate`, and both installed models report the
`vision` capability. Analysing the Opening Reference into the Character Bible is
therefore a bounded fix that would remove an actively wrong instruction from
every shot of every referenced movie.

## D-072 (2026-08-11) Identity survives a reframe when the source frame carries identity

Four controlled generations, one variable at a time, same seed (1721937161),
768x512, 121 frames, 25 steps, same model and encoder, run outside the GUI so
seeds and shot counts could be fixed.

A used the verbatim production shot-3 prompt on the shot-3 continuity frame at
strength 0.8. B replaced only the prompt with a change-focused one. C lowered
only the strength to 0.5. D changed only the source, to the Opening Reference
still.

A produced exactly its dictated costume: a Western woman in a beige trench coat.
B and C invented different women, but without the wrong costume. D preserved the
Adventurer Heroine — hair, navy collar with gold trim, cream cape and face —
through the full wide to close-up reframe, executing the same beat.

The dissociation is clean. Prompt strategy changed *what* was invented but not
*whether* invention happened; source content changed whether it happened at all;
strength changed neither, and there was no identity-versus-camera tradeoff to
find — 0.5 and 0.8 both reframed fully.

So on this stack the dominant variable is whether the conditioning frame
contains resolvable identity at the scale the next shot needs. The external
guidance that motivated this (ComfyUI's LTX2 text-gen node: "Describe only
changes from the image... Inaccurate descriptions may cause scene cuts") is
borne out in its narrower claim — A's inaccurate costume did steer the result
away from the image — but change-focused wording alone does not rescue a source
that carries no identity.

Product consequence: give important reframe shots a fresh identity-bearing
anchor, rather than lowering strength or limiting camera movement.

## D-073 (2026-08-11) Change-focused prompting is for CONTINUE shots, not for the bridge

The same prompt philosophy was applied to the Temporal Bridge, with everything
else held identical to the successful aspect-fill run including the negative
prompt. It was clearly worse: reference-sheet removal 3 -> 0, Opening Reference
usability 3 -> 0.

The failure is specific. The model rendered the character standing inside a
literal reference-sheet panel — a white board carrying annotation-label blocks,
mounted in front of the courtyard — for the whole clip. The sheet layout was not
dissolved; it was promoted to a prop.

This is consistent rather than contradictory. For a continuation the input image
is the truth and should not be re-described. For the bridge the input is a
reference sheet we explicitly want destroyed, so "keep everything consistent with
the input image" is the wrong instruction. Any future Director split must scope
change-focused prompting to CONTINUE/I2V shots and leave the bridge prompt
appearance-directive.

## D-074 (2026-08-11) The Opening Reference is read before the Director plans

Fixing D-071 at its source rather than downstream. Two things were wrong and
both were ordering, not modelling.

`StoryboardView.create()` called the Director first and imported the Opening
Reference afterwards, so the plan could not have seen the image. And
`StoryboardDirector` seeded an empty Character Bible from
`draft.initialState.characterOutfit` — the LLM's guess from brief text. The
guess then reached every render through `PromptCompiler`'s
`Current costume: …` line.

The flow is now: import the managed asset, analyse it with local vision, seed the
Bible from what was seen, plan, apply the evidence again over anything the
Director still produced, recompile, save, enqueue. The Director is handed a Bible
that already matches the image, so there is nothing left for it to contradict.

Precedence is explicit: user-authored appearance, then image evidence, then the
Director's guess, then no claim. An entry counts as user-authored when it carries
reference assets, locked traits or prose the Director never writes — the seeding
path sets only name and costume, so a placeholder is recognisable and may be
superseded while anything richer may not.

Nothing is invented when vision is missing, malformed, or sees several people;
all three apply no appearance at all. Ambiguity is deliberately a refusal:
guessing which of two people is the protagonist would write the wrong costume
into every prompt, which is the failure being fixed.

No second vision backend was added — model selection and the request both reuse
the Character Sheet importer's existing loopback Ollama path.

## D-075 (2026-08-11) CONTINUE shots describe the change, not the character

`CharacterPromptPipeline` emitted the full appearance block for every shot
regardless of continuity mode. A CONTINUE shot begins from the previous shot's
last frame, where the character, clothes, place and light already exist, so that
block made the text argue with the picture.

CONTINUE shots now carry one compact continuity statement plus only the fields
that actually differ between the state entering the shot and the state after its
explicit changes. A real wardrobe change is still described; an unchanged one is
not restated. CUT, auto and T2V keep the existing descriptive policy unchanged —
auto included, because the run coordinator may resolve it to a cut and a
continuation with no source frame would be ungrounded.

The Temporal Bridge is excluded by construction: it is not a Shot and never
reaches this pipeline. D-073 showed continue-semantics there preserves the
character sheet as a physical panel, because transform and continue are opposite
instructions.

## D-076 (2026-08-11) Identity survives exactly as far as the source frame carries it

Measured in production, same opening still and brief as the failing run.

Shot 1 no longer drifts at all: costume, hair and silhouette hold from 0% to 99%,
where the old run had lost the navy vest by ~40% and showed a distant plain coat
by 60%. First clothing drift moved from inside shot 1 to shot 3, and the beige
trench coat never appears anywhere.

What remains is not prompt-driven. Shot 2 inherited a large front-on frame with
the face visible and kept the character. Shot 3 inherited a frame showing her
from behind — the costume survived, because it was visible, and the face was
re-invented, because it was not. Shot 4 followed shot 3.

That is D-072 reproduced in the product rather than in a harness, and it settles
the next architecture question: when a shot needs a scale change the inherited
frame cannot support — typically a close-up after a back view — it needs a fresh
identity-bearing anchor. Lower strength does not help and neither does more
prompt text. Prompt tuning stops here.

## D-077 (2026-08-11) A better source repairs the transition; a better prompt does not

Gate for Adaptive Identity Refresh, run before any production code. The exact
failing transition from the previous production movie was reproduced with every
variable fixed — seed 551658229, 768x512, 121 frames, 25 steps, same prompt,
model and encoder — and only the source image changed.

From the inherited back-view frame: a different woman in a blue-grey dress, face
0, identity 1. From the movie's own opening still: the Adventurer Heroine intact,
face 3, hair 3, clothing 3, identity 3, with the same framing and the same beat.

So the repair is available and it is a source problem, exactly as D-076
predicted. This is what justified building the feature rather than continuing to
tune prompts.

## D-078 (2026-08-11) The refresh anchor can be generated, but reuse is cheaper

Second gate. A short LTX preparation clip — 49 frames, a valid 8n+1 count, 122s
against 270s for a full shot — transformed the opening still into a
target-compatible anchor: camera settled into medium-close-up, face clearly
visible, costume intact. The frame at 80% scored 3 on every criterion; as with
the earlier bridge, the transformation completed well before the end, so the last
frame is not the best one.

Re-running the target shot from that generated anchor matched the manual anchor
on identity and was far closer to it than to normal continuity.

But the manual anchor also won the narrative beat and cost nothing. Where the
strongest identity anchor is already scene-compatible, using it directly beats
regenerating it. The generator belongs behind `IdentityAnchorGenerator` as the
fallback for when no compatible anchor exists.

## D-079 (2026-08-11) Refresh triggers on missing information, not on framing

The rule is deliberately not "the next shot is a close-up". D-072 showed an
identity-bearing source survives a wide-to-close reframe intact, so triggering on
framing alone would spend a generation on shots that were never going to fail.

Two separate questions, separately testable: does the next shot need facial
detail, from its shot scale; and does the inherited frame contain it, from a
vision visibility assessment that never attempts identification. Refresh only
when the first is yes and the second is no. Ambiguous or unavailable vision
declines — a refresh costs a whole render, and an unassessed frame is not
evidence that anything is wrong.

The first production run bore this out in the negative direction: the Director
planned a close-up, the policy assessed the inherited frame as medium scale,
front-facing, partial face, and correctly declined. No false positive, no wasted
generation — and, honestly, no observation yet of the trigger firing in a real
movie. That remains proven by unit tests and the two gate experiments only.

## D-080 (2026-08-11) A refresh decision does not imply a refresh generation

Gate #1 had already shown the movie's own Opening Reference repaired the failing
back-view-to-close-up transition as well as a generated anchor, with a better
narrative beat and zero generation cost. Therefore `IdentityRefreshPolicy`
continues to answer only whether inherited continuity is risky. A separate pure
`SceneCompatibleIdentityAnchorResolver` now asks whether an already-owned
cinematic image can satisfy that need before `IdentityAnchorGenerator` is
invoked.

The resolver considers prior generated refresh anchors, most recent first, then
the Opening Reference. It requires visibility evidence for exactly one
unambiguous subject with clear face, hair and costume; no biometric matching is
performed. Deterministic scene metadata rejects stale anchors, disjoint cast,
location/time/weather changes, wardrobe/outfit changes, and character
transformations. A shared location or uninterrupted CONTINUE segment positively
establishes compatibility. Camera and action changes do not reject an anchor,
because the measured backend can reframe a good identity-bearing source.

Explicit per-shot Starting Image precedence is untouched, and Character Sheet
plates are never direct candidates. Reuse/generation origin and prior-anchor
source Shot are optional persisted fields, preserving legacy decode. Opening
Reference Replace/Clear and upstream Retake invalidate dependent decisions. The
real GUI pass found that the View also failed to call the existing derived-
appearance invalidator; Replace/Clear now invalidate both appearance evidence
and refresh-anchor reuse before saving.

## D-081 (2026-08-11) The conservative true-positive path is production accepted

A deterministic production fixture used a real completed opening Shot, then let
the shipping queue render Shot 2 so that it genuinely ended back-facing in the
same Stone Courtyard. Its actual extracted frame was assessed by
`agents-a1:32k` as one medium subject, face none, hair partial, costume clear,
orientation back. The unchanged policy required refresh for the following
close-up.

The new resolver reused the project-owned Opening Reference. The next real
render command named that exact absolute path; no IdentityRefresh bridge process
or managed bridge asset existed. The elapsed gap from Shot 2 output to Shot 3
child start was 19 s (frame extraction + Vision + resolver), compared with the
prior generated bridge's ~122 s. Added LTX generations: zero.

A direct source-only control used the same target prompt, seed, model, encoder,
size, frames, steps and conditioning strength. Normal inherited continuity
replaced the heroine with a different woman (Face/Hair/Clothing/Identity
0/1/1/1); production reuse kept her at 3/3/3/3. Framing, look-back beat,
courtyard and artifact scores remained 3 in both. The four-Shot movie assembled
to a valid 20.061 s H.264/AAC output, and one-second subprocess sampling recorded
maximum concurrency one.

This closes the missing positive half of D-079. Freeze the architecture as:
normal continuity -> risk assessment -> existing-anchor reuse -> generated
refresh fallback. Further identity-backend expansion is not justified by this
acceptance; next work is observability, performance and product polish.

## D-082 (2026-08-11) Do not productize prompt-only Opening Shot protection

The implementation gate compared a real completed Auto Movie Shot 1 against an
otherwise identical render. Source, full appearance/scene/action/audio prompt,
seed, model, encoder, 768x512/121f/24fps profile, strength and audio were fixed;
only the requested slow push-in/arc became explicit static/no-reframe wording.

The protected condition did not improve identity and was transiently worse at
20%. Direct frame review and the installed local Vision model both found its
strongest face/hair morph there. Static wording also failed to make the measured
composition static. The control was scene- and narrative-coherent and did not
show the catastrophic failure strongly enough at the required samples to justify
a general detector.

The gate therefore rejects production implementation. Do not add a Shot-1 risk
heuristic, automatic prompt rewrite or provenance field from this evidence, and
do not involve Adaptive Identity Refresh or Production Queue. A future gate must
start from the exact catastrophic case or a verified tiny-face reference and
must demonstrate that the proposed intervention changes actual motion and beats
the control before code is added.

## D-083 (2026-08-11) Attribute the original face melt to a transient raw failure

The exact user-observed Final, project selection metadata and retained raw take
were traced end to end. Final Shot 1's 117 decoded frame hashes equal the raw
take's 117 hashes. Assembly used the compatible concat/stream-copy path and the
worst frame is 1.510 s before the next shot begins. Assembly is excluded; raw
frame 84 at 3.500 s already contains the strongest geometric face collapse.

Calibration A is the same MP4, not a rerun. Its checksum equals the failing raw
take. The earlier six-frame evaluation skipped from raw frame 70 to 93 and
therefore missed the frame-84 peak; full-scene presentation further hid a face
only about 49 pixels wide. Preserve D-082's rejection of static-camera wording,
but supersede its implication that control A lacked the severe transient.

Freeze production code again. Do not repair Final Assembly or add a new prompt
heuristic. If generation testing resumes, first isolate source face scale with
one aspect-preserving, scene-compatible larger-face condition and dense face
review. Frame-level quality rejection is a separate future gate because the
transient is now proven, but its false-positive behavior remains unmeasured.

## D-084 (2026-08-11) Aspect-preserved input beats the transient before a tight crop is needed

Two new same-prompt, same-seed, same-backend renders used explicit 768x512
aspect-preserved inputs. A retained full-body framing and a 40 px source face,
closely matching the historical failure's 38 px face and 38-to-58 px push-in
trajectory. Unlike the historical hard-stretched input, A had no geometric
face collapse. B began with a 77 px face and also stayed anatomically clean,
but the wide-shot prompt pulled it back to 37 px and invented unseen boots.

Classify this gate as “aspect-preserving input is the stronger lever,” not
“larger face fixes identity.” A already removed the specific failure without a
tight source, so B did not materially improve worst face geometry. More
importantly, a hidden tight conditioning crop is not composition-neutral: it
changes the opening camera path and causes the backend to reconstruct visual
information outside the crop.

Do not implement automatic Opening Identity Crop or alter Opening Reference
semantics. Historical-versus-new same-seed visual determinism is not proven,
and the two new outputs even contain 117 versus 119 readable frames. The next
gate is one exact A repeat; only after repeatability should an aspect-only pair
be designed with the content window held constant.
