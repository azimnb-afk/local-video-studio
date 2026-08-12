# CURRENT_STATE

Updated: 2026-08-12

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

## 2026-08-09 Bilingual page descriptions

Generate, One Shot, Storyboard, Hybrid, Video Archive, and Settings now show a
page title followed by the English page description and its Japanese equivalent.
Navigation, buttons, presets, errors, workflow logic, and localization settings
remain unchanged; this is an always-visible two-line presentation rather than a
locale system. Canonical Debug GUI acceptance confirmed all six pages, English
navigation labels, intact One Shot Starting Image controls, and no clipping or
overlap at the tested window sizes.

## 2026-08-09 Bilingual Settings descriptions

Settings now presents 23 existing explanatory blocks in English followed by
Japanese across General, Generation, Director, Analysis, Audio, and Models &
Features. Item names, section headings, buttons, pickers, model names, paths,
status values, defaults, and all settings behavior remain English and unchanged;
no localization infrastructure was added. Conditional Python and Director
guidance uses the same bilingual presentation without changing its conditions.

Canonical Debug GUI acceptance covered every Settings tab (including About),
form scrolling, and the Analysis model picker. The additional text initially
compressed the shared Settings page description; assigning the existing page
header layout priority keeps both header lines visible while the form remains
scrollable. The accepted executable was the full canonical DerivedData path,
mtime `2026-08-09 22:38:15 +0900`, running as PID `89377`.

## 2026-08-09 Sidebar navigation layout fix

Primary sidebar navigation (Generate / One Shot / Storyboard / Hybrid / Video
Archive) could be clipped above the visible window area, leaving only the Queue
and Model Status panes reachable. The cause was detail-column size inflation:
AppKit-backed `HSplitView`s inside the `NavigationSplitView` detail column
reported their intrinsic content height (measured 1685pt inside a 948pt
window) instead of the offered viewport, and the oversized, bottom-anchored
layout pushed the top of both columns off-screen. See DECISION_LOG D-025 for
the measurements and the hypotheses this ruled out.

The detail column now clamps to the offered viewport, and the sidebar pins
navigation outside its scroll area so Queue/Model Status growth can never push
it out. Canonical Debug GUI acceptance re-verified fresh launch, relaunch,
small (900×500) and large (1680×948) windows, reopening at a small window,
window tab bar ON and OFF, and clicking all five navigation entries — the split
view measured exactly the window height (948) in every case. Settings bilingual
descriptions were unaffected and re-confirmed in the running app. No generation,
model download, or backend change was involved.

- `swift build`: PASS
- `swift run LTXTests`: **659 passed, 0 failed** (unchanged baseline)
- `xcodebuild -configuration Debug CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**

## 2026-08-10 Auto Movie continuity chain and automatic assembly

The long-form vertical slice is complete: an Auto Movie brief becomes multiple
shots that generate sequentially, inherit visual continuity from one another,
and assemble into a single finished movie without manual steps.

Hybrid is presented as **Auto Movie (Sora 2-like)**; the internal `hybrid`
workflow value, enum case and persistence keys are unchanged, so existing
projects keep loading (D-026).

Continuity chain: the previous shot's final usable frame is extracted with the
FFmpeg binary already used for assembly and passed as the next shot's
`sourceImagePath` through the existing single-image I2V bridge (D-028). Shots
carry `auto` / `continue` / `cut`; unknown values resolve deterministically and
conservatively — a shot only continues on positive evidence of the same scene,
otherwise it cuts, and the first shot always cuts (D-029). Starting image
precedence is explicit user selection, then the inherited frame, then plain
text-to-video; a shot that should continue but has no usable frame is blocked
with a reason and never silently downgraded (D-030).

Auto Movie enqueues one shot at a time because shot N+1's starting image only
exists once shot N has rendered; generation concurrency stays 1 (D-027).
Automatic Final Assembly runs once per completed run, guarded by a persisted
take-identity signature, and is blocked by failures, cancellations, blocked
continuity or ambiguous take selection. Storyboard keeps manual generation and
manual continuity but also gets the single automatic assembly (D-031).

Continuity is a visual anchor, not identity conditioning. It improves
continuity of person, wardrobe, location and lighting without guaranteeing an
identical person or place.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **718 passed, 0 failed** (659 baseline + 59 new)
- `xcodebuild -configuration Debug CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**
- `git diff --check`: PASS
- Real three-shot LTX continuity run: `scripts/automovie_continuity_e2e.sh`

### Pending
GUI acceptance for Auto Movie (GUI_ACCEPTANCE_CHECKLIST sections J–M) was not
executed: during the unattended run the graphical session was not vending
windows — every application, including TextEdit, reported zero windows and
screen captures were blank — so no app UI could be inspected. It needs one
session with an awake, unlocked display.

### 2026-08-10 run — final verification snapshot
- `swift build`: PASS
- `swift run LTXTests`: 718 passed, 0 failed
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `xcodebuild` Release clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- Real 3-shot Auto Movie continuity run: PASS (3.125 s assembled movie)
- GUI acceptance: **not executed** — the graphical session was not vending
  windows for any application during the run (see GUI_ACCEPTANCE_CHECKLIST J–M)

Exact resume action: open the canonical Debug app on an awake, unlocked
display and work through GUI_ACCEPTANCE_CHECKLIST sections J–M.

## 2026-08-10 Continuity strength calibration

`imageStrength` semantics were verified in the backend source (its help text is
inverted relative to its implementation): 1.0 pins the conditioned frame to the
source image, lower values allow recomposition. A controlled sweep on one
transition selected **0.8** as the knee — it recovers most of the available
narrative progression for a small anchor cost, and nothing below it progresses
further (D-032). The value lives once in
`AutoMovieRunCoordinator.continuityImageStrength` and applies **only** to frames
inherited from a previous shot; explicit user/CharacterBible starting images,
Generate's manual I2V, One Shot, Storyboard, cut shots and first shots are
unchanged.

A second, independent cause of composition leakage was isolated: a shot prompt
asking for a "steady camera" holds the framing regardless of strength (D-033).

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **736 passed, 0 failed** (718 + 18)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- GUI acceptance: **executed this session** (previously blocked). Auto Movie
  (Sora 2-like) page, bilingual descriptions, pinned sidebar navigation,
  existing hybrid projects loading, the new continuity schema decoding in the
  real app, and the "Continues from Shot 1" badge were all confirmed on the
  canonical Debug app.

## 2026-08-10 Auto Movie cinematic progression

Composition leakage had a second cause beyond image strength, and it was not the
camera. Auto Movie's split path reused the brief verbatim for every beat
("… — story beat 2 of 4"), and `PromptCompiler` feeds the shot summary in as the
action, so every shot described the same moment. The other candidates were
cleared first: the split path already varied scale and movement, the compiler
passes the camera plan through unchanged, the app never emits "steady camera"
anywhere, and the continuity context only carries location, time, weather,
lighting and outfit — it never constrains framing (D-034).

`AutoMovieBeatPlanner` now gives each beat a distinct stage and picks scale,
angle and movement to match it, keeping a static camera available for a
resolving beat. Continuing beats are short because they render image-to-video
and the scene already arrives in the inherited frame.
`ContinuityEngine.repeatedActionWarnings` adds a small deterministic warning for
consecutive shots that describe the same action (D-035).

The Director now has to advance each shot to a new visible state, is told that a
continuing shot keeps the world but not the framing, keeps a static camera valid
when the beat calls for it, and prefers a cut when the story genuinely moves.
Sampling revealed it would otherwise mark every shot "cut", so a worked
cut/continue/continue/cut example rebalances it (D-036). The longer instructions
made the plan JSON長 enough to truncate at Ollama's default budget, so the
request now sets `num_predict` explicitly (D-037).

Continuity strength stays 0.8. Generate, One Shot, Storyboard manual shots and
explicit Starting Images are untouched.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **792 passed, 0 failed** (736 + 56)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS

## 2026-08-10 Continuity Reconciliation

The local Director's cut bias could not be fixed with prompt wording alone
(0/3, then 2/3, then 2/4 plans with a continuation), and an all-cut plan means
nothing is inherited — a real run produced three different-looking people inside
one scene. `ContinuityReconciler` now runs once on the finished shot plan,
inside the Auto Movie coordinator only, and promotes a planned cut to a
continuation only on positive evidence from the Director's own metadata: the
same non-empty location AND the same non-empty cast, with no explicit
scene/time/weather directive, no story-state jump and no interior/exterior
crossing. It never demotes, never touches the first shot, and never overrules an
explicit scene change (D-038).

Framing is deliberately excluded from the conditions — inheriting at 0.8 already
frees the camera, so a wide shot followed by a detail insert of the same moment
is still a continuation (D-039). `Shot` gained `plannedContinuityMode` and
`continuityReconciliationReason`; `continuityMode` stays the effective value, so
generation, the chain and the badge were unchanged and a reload stays
explainable (D-040).

Measured: raw `cut,cut,cut,cut,cut` became `cut,continue,continue,continue,cut`
while plans that already had continuations were left alone. A real four-shot run
kept the same woman, dress, facade and light across the continued shots, where
the previous all-cut run had changed person entirely. The honest cost is that a
planned detail insert after a wide inherited frame does not reach its intended
framing — recorded in BENCHMARK_RESULTS, with per-shot continuity strength named
as the natural next step.

Continuity strength stays 0.8. Storyboard, One Shot and Generate are untouched.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **830 passed, 0 failed** (792 + 38)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- GUI: sidebar navigation pinned, Auto Movie page and projects load unchanged

## 2026-08-10 Adaptive Continuity Strength

Reconciliation made shots inherit correctly, but one honest cost remained: a
planned detail insert after a wide inherited frame never reached its framing,
because 0.8 holds the previous composition. This round asked whether a lower
strength recovers the reframe.

Calibrated on the real failing case (the same source frame, prompt, seed and
render settings; only `--image-strength` varied): 0.8, 0.65, 0.5, 0.35, 0.2,
plus a pure text-to-video control and a second case asking for a face close-up
instead of an object detail. **No strength achieved the reframe** (measured
under the 25-frame verification harness; see the 2026-08-10 Beat Feasibility
Calibration, which showed that harness was rendering 1.04-second shots). SSIM against
the source loosens monotonically (0.935 / 0.909 / 0.871 / 0.842) but the framing
stays full-figure at the same distance; at 0.2 the image degenerates. The
text-to-video control — zero conditioning — did not produce the intended
key-in-lock insert either, which places the failure in the model/prompt at
512x320, 25 frames, 15 steps rather than in the conditioning strength (D-041).

So the change is scoped to what the measurements do support. `standard` keeps
the calibrated 0.8; `reframe` uses 0.5, the loosest setting that still preserved
the person, wardrobe and set in every sample. `ContinuityStrengthResolver` picks
between them deterministically from the Director's own shot-scale ladder
(extreme-wide -> extreme-close-up): a jump of three or more rungs in either
direction is a reframe, otherwise standard, with a detail-insert text fallback
only when the scale vocabulary is unrecognised. Camera angle and movement are
read nowhere, and the policy never feeds back into cut vs continue (D-042).

Applied at the single existing site in `TakeGenerationCoordinator`, so it covers
Auto Movie inherited frames only. A user-selected starting image, Storyboard,
One Shot and Generate are untouched, and there is no user-facing slider.

A real four-shot run selected `standard 0.8` for wide -> medium-wide and
`reframe 0.5` for medium-wide -> extreme-close-up, kept the same woman, coat and
colonnade across shots 1-3, and still did not reach the planned insert framing
(SSIM 0.891 vs 0.934) — consistent with the calibration and recorded as such.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **863 passed, 0 failed** (830 + 33)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `xcodebuild` Release clean build: compiles; Developer ID signing unavailable
  on this machine, so Release was verified with an ad-hoc signing override and
  no project setting was changed
- `git diff --check`: PASS
- GUI: sidebar navigation pinned, Auto Movie page and projects load unchanged

## 2026-08-10 Capability-Aware Shot Planning

With strength tuning exhausted — no value reached the planned detail insert, and
a zero-conditioning control failed the same prompt — the remaining lever was to
stop planning shots this profile cannot render.

`CapabilityAwareShotPlanner` runs once on the Director's draft, inside Auto Movie
only, and classifies each shot `normal` or `highRisk` on four measured rules: a
three-rung-or-larger framing jump at a boundary that inherits a frame, the
tightest rung on the ladder, a hand or finger operating something small, and four
or more action clauses in one short take. High-risk shots get a framing that
renders and language that stops asking for a macro rendering; the beat itself is
never deleted (D-043). Close-ups are not banned — a close-up two rungs from the
previous shot is planned exactly as asked.

`ShotScaleLadder` now owns the scale vocabulary for both this pass and
`ContinuityStrengthResolver`, and the largest planned jump is derived from the
reframe threshold rather than chosen separately, so the two can never disagree.
Capability planning is the first defence, adaptive strength the fallback for
reframes that survive — including one the user asked for by name, which is left
untouched (D-044, D-045). `AutoMovieBeatPlanner`'s split ladder is held to the
same bound; a two-beat movie used to jump wide → close-up.

The pass runs on the draft so the camera fields, the compiled prompt and the
persisted plan all describe the same effective shot. `Shot` gained optional
`originalCameraScale` and `capabilityAdjustmentReason`; old projects decode
unchanged. Storyboard, One Shot, Generate and CharacterBible are untouched, and
the Basic (no-LLM) path gets the same policy.

Measured across four unrelated briefs (library, forest shrine, parked car,
control room): every brief triggered at least one adjustment, every action kept
its subject/verb/object, camera variety survived. In the real four-shot run the
Director's close-up became medium-close-up, which in turn meant the reframe
fallback was no longer needed (standard 0.8 throughout), and reconciliation still
promoted both boundaries.

Honestly recorded as **PARTIAL**: character and environment continuity held, but
the unlock beat is still not visible and shots 1–3 hold the inherited
composition (SSIM 0.930 → 0.940 on shot 3). At this Quick profile an inherited
frame that does not already contain the preconditions for the next beat cannot
be moved to them in 25 frames — a single-frame-conditioning limit, not a
planning bug.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **945 passed, 0 failed** (863 + 82)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `xcodebuild` Release clean build: BUILD SUCCEEDED (ad-hoc signing override;
  Developer ID unavailable on this machine, no project setting changed)
- `git diff --check`: PASS
- GUI: sidebar navigation pinned, Auto Movie page and existing projects load
  after the two new optional Shot fields

## 2026-08-10 Auto Movie Beat Feasibility Calibration

Investigated why a CONTINUE shot appeared unable to advance the narrative, using
controlled real generations on the single boundary that had failed.

The answer was a measurement defect. The E2E harness hard-coded 25 frames;
the product derives frames from each shot's duration through
`PromptCompiler.frameCount`, so a 5 s shot renders 121 frames — confirmed
against a real persisted project (121 f, 5.01 s, 768×512, strength 0.8). Every
previous "beat did not progress" verdict was measured on 1.04-second shots
(D-046).

Five conditions on the same boundary, one variable at a time: current 25 f
(beat 0), 121 f (beat 2, continuity intact, framing genuinely moves), more steps
(byte-identical to baseline — `--steps` is ignored for unified models), CUT/T2V
(beat 3 but a different person in a different building) and preconditioned
CONTINUE (no better than plain 121 f).

No production change is justified: the only effective lever is duration, and the
product already applies it. Dynamic duration, dynamic steps, strategic CUT and
beat-boundary planning were each rejected on evidence (D-047). The harness now
derives frames per shot the way the app does, and its one remaining deliberate
difference from the product profile is documented and overridable.

The corrected end-to-end run produced a 20.17 s movie instead of 4.17 s, and the
image now moves substantially (SSIM against the inherited frame falling to
0.584 / 0.703 / 0.928, versus 0.940 — frozen — before). That run still failed
narratively for a newly isolated reason: the first shot's composition propagates
through the whole inherited chain, so a weak opening cannot be recovered later.
Recorded as the next thing worth investigating, not patched speculatively.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **945 passed, 0 failed** (unchanged; no production code
  was modified this round)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- GUI acceptance: not re-run, and not required — no production code changed

## 2026-08-10 Auto Movie Opening Shot Anchor

Tested whether the opening shot's final frame determines how the rest of the
inherited chain behaves. It does — and the useful correction turned out to be
subtractive.

Four openings were compared on the same brief, seed and 121-frame product
duration, varying only the opening wording: the Director's own (which contained
"her figure small against the towering walls"), one with composition guidance
added, one with a dictated ending state, and one with the miniaturizing clause
simply deleted and nothing added. The last was as good as either of the
elaborate versions — subject readable and at the destination by the final frame
— so the added language is not what worked (D-048).

Downstream: an opening ending with a tiny subject produced a Shot 2 where she
drifted to the frame edge; the anchored openings produced a Shot 2 that kept her
at usable scale. Confirmed at the product resolution of 768×512 with 121-frame
shots, where the current wording ends small and distant on the stairs and the
anchored wording ends at the doorway.

Implemented as the smallest thing the evidence supports: the capability planner
removes subject-miniaturizing phrases from the Auto Movie **opening shot only**.
Camera scale is untouched (a wide or extreme-wide establishing shot survives
unchanged), no facing or ending state is imposed, later shots are unaffected,
and a brief that asks for the small-figure look is respected. The word "small"
was already in the planner's miniaturizer list; it simply never reached this
shot, because removal only ran for `highRisk` shots and a wide establishing shot
is correctly `normal`.

Historical 25-frame results were scoped rather than deleted (D-049).

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **972 passed, 0 failed** (945 + 27)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- GUI: sidebar pinned, Auto Movie page and all five projects load
- Full 4-shot E2E ran clean (20.17 s), though the anchor did not fire in it —
  that plan had no miniaturizing language to remove

## 2026-08-10 Auto Movie Destination Anchor Calibration

Tested whether making the interaction target visually readable improves the
downstream arrival and interaction beats. It does not — because at the product's
own resolution the target is already readable.

Six destination wordings were compared on the same brief, seed and 121-frame
duration. At 512×320 the current wording produced no identifiable door
(readability 1), explicit destination wording produced a clear door but shrank
the protagonist into the background, persistence guidance on a vague noun
changed nothing at all, and a combined version protected the protagonist but
reversed her direction so the door left frame by the next shot. Neither
intervention improved arrival.

At 768×512 the current, unmodified wording already renders a readable door, the
protagonist approaches it, and Shot 2 arrives and stops at it (D-050). The
"destination readability ≈ 1" finding that motivated this round was an artifact
of the 512×320 Compact profile the previous calibration ran at.

No production change. A destination policy would have optimised a low-resolution
artifact and, on the 512×320 evidence, would have cost the protagonist
readability the opening anchor had just secured. The Director's
`position:<Character>=` directives and `props` remain available if the question
returns for a better reason; no schema was added.

Recorded as a methodological rule: calibrations that score objects in the world
run at 768×512 or name the profile as a limit (D-051). Subject-level findings
reproduce at both resolutions and are unaffected.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **972 passed, 0 failed** (unchanged; no production code
  was modified this round)
- GUI acceptance: not re-run, and not required — no production code changed

## 2026-08-10 Reframe revalidation at the product profile

The claim that large reframes are impossible with single-frame continuity came
from a calibration run at 512×320 / 25 frames. Both of those have since been
shown to distort results, so it was re-tested on one fixed source frame at
768×512 / 121 frames with only the strength varying.

The claim does not survive. At the product profile 0.8 does not reframe — the
subject stays full-figure and walks away — while 0.65 and 0.5 both reach a
genuine close-up with the same person, wardrobe and set. At 512×320 even 0.8
reframes, so duration is the dominant factor and resolution modulates it
(D-052). SSIM was useless here: 0.498 / 0.480 / 0.468 across three conditions,
one of which reframes and one of which does not.

Fine object interaction is the half of the original finding that survives — at
0.5 the camera reframed cleanly and the planned hand-to-door-handle action still
never happened.

Both strengths are kept: 0.8 preserves composition, which is what a standard
continuation should do, and 0.5 is validated for the opposite reason to the one
originally recorded. 0.65 works too, with no measurable advantage, so nothing
was changed on a single sample.

One production change, and it is a deletion. The capability planner clamped
three-rung framing jumps to two, which made the strength resolver read the
clamped distance and select 0.8 — so a planned close-up got neither its framing
nor the strength for it. Large framing jumps are no longer a capability risk;
the detail-insert, fine-manipulation and too-many-beats rules are untouched
(D-053). Reconciliation, the Opening Shot Anchor and both strength values are
unchanged.

Historical D-041/D-042 and their benchmark section are kept verbatim and marked
with the profile they were measured at.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **972 passed, 0 failed** (two tests that encoded the
  disproven belief were updated to the corrected policy)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS

## 2026-08-10 Detail-clamp × strength interaction

Closed the last open question from the reframe revalidation: whether a shot
clamped for detail reasons should still receive the reframe strength its
original framing intent implied.

The architecture gap is real — `saferScale` clamps a detail shot to
medium-close-up, `Shot.originalCameraScale` is persisted, and
`ContinuityStrengthResolver` reads only the effective scale. But it does not
matter. On the shipping planner's own clamped shot, at 768×512 / 121 frames
with identical prompt and source and two seeds, 0.8 and 0.5 were
indistinguishable: same framing progression, same failure to perform the
hand-to-lock action, same strong character and environment continuity (D-054).

No production change. Strength continues to come from the post-clamp effective
scale.

This is consistent with the revalidation rather than contradicting it: there,
0.8 failed a 3-rung framing request that 0.5 delivered; here the clamp has
already reduced the request to 2 rungs, which 0.8 delivers on its own. The clamp
lowers the ask to something the standard anchor satisfies.

Fine object interaction still fails at both strengths — unchanged, and not a
strength problem.

### Build & verification
- `swift run LTXTests`: **972 passed, 0 failed** (unchanged; no production code
  was modified this round)
- GUI acceptance: not re-run, and not required — no production code changed

## 2026-08-10 Auto Movie v1 production readiness audit

Three unrelated briefs (courtyard/library, seaside plaza, city street/car) run
end to end at 768×512 / 121 frames per 5 s shot, one run each. 12/12 shots
rendered, 3/3 movies assembled, no pipeline errors.

All system components passed: Director planning, Opening Anchor (fired in one
case, correctly dormant in two), Continuity Reconciliation, Strength Resolver
(0.8 and 0.5 selected correctly every time), continuity frame extraction with no
silent fallback, strictly sequential generation, Final Assembly with each shot
once and frame counts matching per-shot plans, and persistence — real projects
round-trip chain frames, source take IDs and planned-vs-effective modes while
legacy projects still decode.

The plaza case is the best result the project has produced: four beats, one man,
one suit, one location, clean camera progression, no artifacts. The other two
carry a coherence artifact (a pasted hand, a duplicated subject) where the
system nonetheless chose the right strength and frame — model limitations under
the audit's own rule, not product failures.

**No production code changed.** No defect recurred across cases, which was the
bar set to avoid single-sample overfitting. Two single-case planner
observations are recorded but not acted on (D-055).

**Verdict: READY WITH KNOWN LIMITATIONS.** Fine object manipulation remains the
one unreliable area, unmoved by duration, resolution, strength, framing or
clamping across four calibrations.

Audit videos are preserved for manual review in
`~/Library/Application Support/LTXVideoGenerator/Videos` as `AUDIT_*.mp4`
(15 files). They are on disk and playable but do not appear in the Video Archive,
which is driven by `history.json` (D-056); that file was not edited.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **972 passed, 0 failed** (unchanged)
- `git diff --check`: PASS
- Debug rebuild not required — only `scripts/automovie_progression_e2e.py`
  changed; no compiled source was touched
- GUI acceptance: sidebar and all five pages normal, Auto Movie projects load,
  Video Archive lists 144 history entries

## 2026-08-10 Auto Movie Opening Character Anchor

An optional CharacterBible reference now conditions an Auto Movie's **opening
shot only**; shots 2+ continue through the existing continuity chain unchanged.

Data model: `FilmProject.characterAnchor` (enabled flag, character ID, reference
asset ID, asset type), resolved at generation time by
`CharacterAnchorResolver`. Old projects decode with the anchor disabled and
behave exactly as before.

Source precedence in `TakeGenerationCoordinator`, explicit and ordered: an
explicit per-shot starting image wins, then the anchor **on shot 0 only**, then
an inherited continuity frame, then text-to-video. No second image path was
built — the anchor rides the existing `sourceImagePath` bridge. A missing
character, asset or file raises a distinct error and blocks the shot rather than
silently producing a different-looking protagonist (D-057).

UI: a compact "Character Anchor (Optional)" section on the Auto Movie project
page with a character picker, a reference picker (character sheets excluded —
a multi-pose layout is not a frame a shot can start on), a thumbnail, a missing
reference warning, and bilingual copy that says consistency may improve without
identity being guaranteed.

Calibration overturned the assumption behind the strength. The backend always
blends the conditioning image into frame 1, so lowering the strength corrupts
the reference rather than replacing it with a scene: at 0.45 the opening frame
is still the plate, at 0.25 and 0.15 it is smeared and torn. At no strength did
the reference's costume or face carry into the body of the shot. The anchor
therefore reuses the existing explicit Starting Image strength of 1.0 (D-058).

**Measured limitation, stated plainly:** with a character-sheet extraction the
movie opens on the reference image and then moves into the scene, and identity
carry-over was not observed. The feature is off by default on every project, and
is most useful with a scene-like reference, where it behaves like the continuity
chain that is already known to work.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **1001 passed, 0 failed** (972 + 29)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS

## 2026-08-11 Auto Movie Opening Reference Image

A scene-like still can now be chosen as the first frame of an Auto Movie's
opening shot. Shots 2+ continue through the existing continuity chain, unchanged
and never re-injected with the reference.

This is the follow-on from the Character Anchor measurement, which established
that a conditioning image on this backend is not an identity hint but the shot's
first frame — so a character-sheet plate becomes the head of the film and its
costume is not carried forward. The Opening Reference accepts that mechanic
rather than fighting it: give the opening a picture that already reads as a
movie frame, and the continuity chain has something worth carrying (D-059).

Data model: `FilmProject.openingReferenceImage` — a project-relative managed
path plus display metadata. The image is copied into
`Assets/OpeningReference/` through the same copy-then-atomic-move path
`importCharacterSheet` uses, so the user's original is never moved, renamed or
persisted as an absolute path. Replacing removes the copy it supersedes.
Old projects decode with no reference.

Precedence for shot 1, explicit and ordered: an explicit per-shot starting image,
then the opening reference, then the Character Anchor, then text-to-video.
Clearing the reference hands shot 1 back to the anchor. A missing file blocks
generation with its own error — never a silent text-to-video, and never a silent
fall-through to the anchor.

UI: an "Opening Reference Image (Optional)" section above Character Anchor with
Choose / Replace / Clear, a thumbnail, the filename, a missing-file warning, and
bilingual copy that recommends scene-like images and warns that character sheets
and plain plates appear directly in the opening frame. Character Anchor's copy
was corrected to say the same thing about itself (D-060); the feature is kept.

Untouched: Opening Shot Anchor, Capability-Aware Planning, Continuity
Reconciliation, and the 0.8 / 0.5 continuity strengths.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **1031 passed, 0 failed** (1001 + 30)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS
- GUI acceptance: **partial** — sidebar, Storyboard, Auto Movie page and all
  eight existing projects load correctly with the extended schema, and there is
  no layout regression. The Opening Reference section inside project detail is
  still unverified: selecting a project row needs a real click, which synthetic
  input cannot do on this SwiftUI list. Listed as outstanding in
  GUI_ACCEPTANCE_CHECKLIST.

## 2026-08-11 Opening Reference moved into Auto Movie creation

The Opening Reference Image is now chosen in the **New Auto Movie sheet**, before
the movie is planned — the workflow it was always meant to have. It previously
appeared only on the project page above the shot list, where it read as Shot 1's
control and came too late to affect the first render (D-061).

The sheet holds a plain file URL and imports nothing while open, so cancelling
leaves no managed asset. On Create the image is copied into the project and set
on the model **before** the project is saved and the first shot is queued; a
failed import refuses creation rather than silently producing a text-to-video
opening.

The post-creation control remains for Replace/Clear, relabelled "Movie Settings
— Opening Reference Image" with a subtitle stating it applies to the whole movie
rather than to any shot below. The shot card's pre-existing per-shot control is
untouched and now reads "Starting Image (this shot only)", with help text naming
the movie-level reference and confirming the per-shot override wins (D-062).

Verified in the running app: created a movie from the sheet with a reference
selected, and the project persisted
`Assets/OpeningReference/opening-reference-<uuid>.png` while shot 1's queued take
carried that exact path as its `sourceImagePath` — shots 2–4 had no take yet,
waiting on continuity.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **1038 passed, 0 failed** (1031 + 7)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS

## 2026-08-11 Global Production Queue

Several movies or renders can now be queued and left to run unattended, one
after another.

Architecture: `ProductionQueueCoordinator` (ordering, states, persistence,
one-active-job rule) + `ProductionQueueService` (starts each job through its
mode and watches for it finishing) + `ProductionQueueStore` (atomic JSON at
`Application Support/LTXVideoGenerator/production_queue.json`). It sits *above*
`GenerationService`, which was already the single-render gate; what it adds is
the job boundary that stops two movies interleaving their shots (D-063).

All four modes route through it: Generate (a batch is one job), One Shot,
Storyboard and Auto Movie. Jobs are snapshots — brief, preset, model, seed,
Director mode, and the project-relative Opening Reference and Character Anchor
paths — so editing a project afterwards cannot change a job already waiting
(D-064). Preflight runs again at execution: a reference deleted while the job
waited fails that job with a reason rather than opening on a different
protagonist.

States: waiting / running / completed / failed / cancelled / interrupted. A
failed job never blocks the queue. Cancelling the running job stops the render
in flight, drops what it had queued behind it, and moves on. Retry re-queues
from the original snapshot as a new record, so the failure stays visible. A job
recorded as running when the app quit restores as interrupted and offers
Restart. Sidebar panel shows each job with status, progress and per-state
actions.

**Status: PASS.** Proven in the real app, not only in unit tests. Three Auto
Movies were queued from the GUI and run unattended (10:00–10:21): job A ran its
five shots and assembled, job B then started **by itself** and ran its four
shots and assembled, and job C started after B. Renders never overlapped and
never interleaved.

Closing PARTIAL took three more defects, all found by actually running it:

- **D-066** — the queue only woke on render-queue changes, but final assembly
  starts *after* the last take leaves that queue. Job A sat in "Assembling" with
  the finished movie already on disk and job B never started: the queue stalled
  for as long as the app stayed open. `GenerationService` now publishes a
  `FilmRunEvent` for outcomes the render queue cannot show (assembled, assembly
  failed, blocked, settled), and any of those that means "no movie is coming"
  fails the job instead of holding the queue open.
- **D-067** — mid-run progress counted *selected* takes, but takes are only
  selected when a run ends, so the panel read "Shot 1 / 4" for an entire movie.
  It counts rendered takes now.
- **D-068** — creating an Auto Movie inserted the job at the *head* of the
  waiting jobs. Three movies queued 1, 2, 3 would have run 3, 2, 1. Creation
  appends; only "Generate Now" jumps the queue.

The completion rule now lives in one pure decider, `FilmJobDecider`, shared by
the completion path and the progress path so the two cannot disagree, and
testable without a GPU or a main actor.

### Real E2E evidence
- Render concurrency sampled every 0.5 s for the whole run: **max 1**, with a
  clean gap between every render.
- Every render mapped back to its owning project: A shots 1–5, then B shots 1–4
  — **one job switch, zero interleaving**.
- Queue progression recorded from `production_queue.json`: A Shot 1/5 → 5/5 →
  Completed, B Shot 1/4 → 4/4 → Completed, C Waiting throughout both.
- Assembled outputs preserved as `QUEUE_ACCEPT_A_*` (25.07 s) and
  `QUEUE_ACCEPT_B_*` (20.06 s) in the Videos folder via `cp -n`.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **1123 passed, 0 failed** (1108 + 15 new)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- GUI acceptance: PASS — see GUI_ACCEPTANCE_CHECKLIST.md

### Known cosmetic gap
A completed job keeps its last `stageDescription` ("Assembling") in the
persisted record. The panel hides progress text for terminal states, so nothing
incorrect is shown; only the JSON looks stale. Left alone rather than changed
after the accepted run.

## 2026-08-11 Opening Reference Vision Sync + CONTINUE Change-Focused Prompts

Auto Movie used to contradict its own opening image. The Director invented a
costume from the brief text ("Beige trench coat, dark jeans, boots"), persisted
it as the Character Bible, and every compiled shot prompt carried it — including
shot 1, whose opening frame showed a navy-uniformed adventurer. The costume
drifted toward the text within one shot.

Two changes fix it upstream.

**Opening Reference is now read before the Director plans.** The managed asset is
imported, analysed with the existing local vision path (no second backend, no
network beyond loopback Ollama), and used to seed the Bible. Precedence is
user-authored > image evidence > Director guess > no claim. Vision missing,
malformed, or seeing several people all apply nothing rather than inventing.
Replace and Clear invalidate the derived appearance.

**CONTINUE shots describe what changes.** They carry one compact continuity
statement plus only genuinely differing fields; a real wardrobe change still
appears, an unchanged one is not restated. CUT, auto and T2V are unchanged, and
the Temporal Bridge is excluded by construction (D-073).

### Measured result
- Shot 1 drift: **eliminated** — costume holds 0%→99% (previously lost by ~40%).
- First clothing drift moved from **inside shot 1** to **shot 3**.
- "Beige trench coat" appears nowhere in the new project.
- Remaining drift is **source-information loss**: shot 3 inherited a back view,
  so the costume survived and the face did not.

**Status: PASS WITH LIMITATION.** The prompt contradiction is gone; identity now
degrades only where the inherited frame stops carrying it.

### Build & verification
- `swift build`: PASS
- `swift run LTXTests`: **1191 passed, 0 failed** (1123 + 68)
- `xcodebuild` Debug clean build (`CODE_SIGNING_ALLOWED=NO`): BUILD SUCCEEDED
- GUI: "Opening appearance: Analysed locally" status renders with the derived
  costume; Choose/Replace/Clear, thumbnail, queue and all five pages intact at
  1680x948.
- Production Queue untouched and still passing.

## 2026-08-11 Adaptive Identity Refresh — existing-anchor reuse and production acceptance

**Status: PASS — ADAPTIVE IDENTITY REFRESH PRODUCTION ACCEPTED.** The previous
MVP generated a short LTX preparation clip whenever the conservative refresh
policy fired. It now first asks a pure
`SceneCompatibleIdentityAnchorResolver` whether the project already owns a
scene-like image with enough visible identity information. Only when none is
suitable does the existing `IdentityAnchorGenerator` run.

The production insertion point is unchanged: after a completed Shot's last frame
is extracted and assessed, and before the next take is enqueued. Source
precedence is still explicit per-shot Starting Image > refresh anchor > inherited
continuity > Shot-1 Opening Reference > Character Anchor. Raw Character Sheet
plates are never direct target-shot candidates.

Candidates are the most recent prior generated refresh anchors and the movie's
Opening Reference. Identity sufficiency requires an assessed, unambiguous single
subject with clear face, hair and costume, not back-facing or tiny. Scene
compatibility uses project metadata: an earlier state in the same movie, shared
cast when known, the same location or uninterrupted CONTINUE segment, and no
location, time, weather, wardrobe/outfit or character-transformation transition.
Ordinary camera scale and action changes do not force generation. Stale anchors
and missing files are rejected. Opening Reference Replace/Clear invalidates
dependent reuse decisions; prior-anchor reuse follows its generated root's
retake staleness recursively. The GUI pass also caught that Replace/Clear had
not called the pre-existing `OpeningReferenceSync.invalidateIfStale` helper;
both actions now drop stale derived appearance in the same transaction.

`Shot.identityRefreshAnchorOrigin` records `generated`,
`reusedOpeningReference`, or `reusedPriorRefresh`; the optional source Shot UUID
records prior-anchor provenance. Both fields are optional, so legacy project JSON
still loads and old anchors keep the original take-based staleness rule.

### Forced production true positive

Deterministic project `8650AE3C-45A8-43A8-A96D-5315C3AFDC3D` ran through the
real Production Queue. Its generated Shot 2 ended with one medium-scale subject
facing fully away. The shipping local-Vision assessor (`agents-a1:32k`) reported
`subjectPresent=true`, `subjectCount=1`, `subjectScale=medium`,
`faceVisibility=none`, `hairVisibility=partial`, `costumeVisibility=clear`, and
`subjectOrientation=back`. Shot 3 was a close-up, so the unchanged policy
returned refresh-required. The resolver selected the project-owned Opening
Reference in the same Stone Courtyard; the generator invocation count was zero.
The persisted Shot 3 take and the real `mlx_video.generate_av` command both used
that Opening Reference as `sourceImagePath`.

Shot 2 output completed at 18:27:00; extraction, one Vision call and resolution
finished with Shot 3 starting at 18:27:19. Added orchestration latency was 19 s,
pure resolver time was negligible, and added LTX time was **0 s**. This avoids
the previously measured ~122 s generated bridge whenever a reusable anchor
exists.

A source-only A/B used the production Shot 3 prompt, seed `1202830483`, Q4 model,
4-bit encoder, 768x512, 121 frames, 25 requested steps and strength 0.5. The
identity-poor control changed to a different woman (Face 0, Hair 1, Clothing 1,
Identity 1); production reuse kept the Adventurer Heroine (3/3/3/3). Both scored
3 for requested framing, narrative beat, scene compatibility and artifacts.

All four Shots completed and the Production Queue assembled a 20.061 s,
768x512 H.264 + AAC stereo movie. One-second process sampling recorded maximum
concurrent LTX renders = 1. Shot 4 preserved the protagonist and courtyard but
introduced an unrequested secondary figure near the doors; that is ordinary
generative beat variance, not a refresh/source-selection failure.

### Build and verification

- `git diff --check`: PASS
- `swift build`: PASS
- `swift run LTXTests`: **1269 passed, 0 failed**
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**
- Review copies: `IDREFRESH_ACCEPT_*_20260811_183800` under the Videos folder;
  `history.json` was not edited.

## 2026-08-11 Opening Shot Identity Protection calibration

**Status: REJECTED — no production implementation.** A controlled Shot 1 A/B
used the newest real Auto Movie Opening Reference and held source, full prompt,
seed, Q4 model, 4-bit encoder, 768x512/121f/24fps, audio and image strength 1.0
constant. B changed only `slow push-in + arc` to explicit static/no-reframe
wording.

B did not improve identity. Its clearest transient at 20% was worse than A
(Face/Hair/Identity 1/1/1 versus A's usable drift), and local Vision independently
flagged the same frame. The backend also continued to evolve the composition
despite static wording. Therefore no Shot-1 risk policy, persisted provenance,
UI, Queue, Vision Sync or Adaptive Identity Refresh code was changed. See
`OPENING_SHOT_IDENTITY_PROTECTION_EVAL.md`; review media is preserved as
`OPENSHOTID_*_20260811_201500` in the Videos folder.

## 2026-08-11 Original Face-Melt Forensic

**Status: PASS — TRANSIENT RAW FAILURE IDENTIFIED.** Dense inspection of the
user-observed Final mapped its worst facial collapse at Final 3.520996 s to
Shot 1 raw frame 84 at 3.500 s. All 117 decoded frames in the Final's first
segment match the exact selected raw take, and assembly used compatible stream
copy with no transition or re-encode. The failure belongs to LTX generation,
not Final Assembly.

The previous calibration A is SHA-256-identical to that raw MP4; it did contain
the failure. Its 0/20/40/60/80/99% samples jumped from frames 70 to 93 and
missed the frame-84 peak, while the face occupied only about 49 pixels. The
source was also hard-stretched by the installed backend from 1672x941 to
768x512 (no aspect-preserving crop/pad), and the push-in enlarged the detected
face from about 38 to 58 pixels across the take. These correlations do not yet
prove a source-scale or camera cause.

No LTX rerun and no production source change were made. Do not add another
camera/prompt heuristic. The next controlled generation, if authorized, should
isolate an aspect-preserving, scene-compatible larger-face crop while holding
the exact failing prompt/seed/settings constant and reviewing every 4–5 frames.
See `ORIGINAL_FACE_MELT_FORENSIC.md`; review evidence is preserved as
`FACEMELT_*` in the Videos folder.

## 2026-08-11 Opening Reference aspect-preserving production fix

**Status: PASS — OPENING REFERENCE ASPECT FIX PRODUCTION ACCEPTED.** The exact
Condition A input/prompt/seed/model/encoder/settings were rerun once before any
source change. A2 completed in 278.3 s backend time with 117 readable frames
and was byte-for-byte identical to A1. Dense review again found no geometric
face melt, so the repeat gate passed.

`ImageConditioningPreparer` now forms the single backend-facing geometry
boundary for official LTX I2V requests. Arbitrary-aspect sources are converted
to the final effective 64-pixel-aligned canvas with deterministic centered
scale-to-fill/crop; exact-size continuity and generated refresh frames are
passed through unchanged. There is no stretch, padding, face/subject/Vision
crop or user option. The canonical source remains unchanged and continues to
feed the UI, Vision, prompt enhancement, project metadata and Take provenance;
only the path sent to `mlx_video.generate_av` uses the cached PNG.

The real canonical-app Auto Movie project
`A0058572-38A4-47C5-8E2F-79A0CBE92F86` imported the untouched 1672x941 failing
source. The backend received a 768x512 derived image from source rectangle
`(131, 0, 1410, 940)`. Shot 1 completed in 290.748 s with 117 readable frames.
Every fourth frame was directly reviewed: mild identity drift remains around
0.83–1.0 s, but H's f64/2.667 s melt onset and f84/3.500 s severe collapse do
not recur. Hair, costume, flag, scene and wide-to-medium push-in remain coherent.
All four shots completed sequentially and assembled to a valid 20.061333 s
768x512 H.264/AAC movie. GUI displayed the original thumbnail and reported
`Completed movie ready`.

Source precedence, Adaptive Identity Refresh policy/resolver/provenance and
Production Queue behavior are frozen. Opening Reference Replace/Clear now also
invalidates its internal derivative. Validation: `swift build` PASS,
`swift run LTXTests` **1316 passed / 0 failed**, Xcode clean build succeeded and
`git diff --check` passed. See `OPENING_REFERENCE_ASPECT_FIX_EVAL.md`; review
media is preserved as `FACEMELT_ASPECT_*` and `ASPECTFIX_*` in Videos.

## 2026-08-12 Overnight: consistency, continuity v1, motion audit, plan preview

Four independent phases, each checkpointed.

**Character Sheet ↔ Opening Reference consistency — PASS.** The app had two
kinds of visual evidence and no way to say they were different kinds. A
sheet-backed character was already protected (`isUserAuthored` is true whenever
`referenceAssets` is non-empty) but disagreement was never reported. A pure
reporting layer now compares canonical identity against scene observation, with
`unknown` as a first-class verdict. Conservative: a conflict needs both sides to
name recognised values from the same mutually-exclusive set. It never rewrites
canonical data and never changes which image shot 1 starts from.

**LTX Continuity v1 — PASS, PRODUCTION ACCEPTED.** Consolidation, not redesign.
`LTXContinuityResolver` is a pure classifier mirroring the coordinator's
precedence, adding Requested/Effective/Actual provenance with no persisted field
and no behaviour change. Real E2E: opening reference on shot 1 at 1.0, inherited
frames at 0.8, and a mid-movie cut that inherited nothing at all.

**LTX Motion Continuation — PARTIAL.** The multi-frame conditioning primitive
and the video VAE are both present in `mlx-video-with-audio` 0.1.36, but there is
no video decode for conditioning, `prepare_image_for_encoding` hardcodes the
frame axis to 1, and no surface reaches it. Not expressible without patching a
vendored dependency, so last-frame continuity stays the production system.

**Auto Movie Plan Preview — PASS (MVP).** Read-only plan summary shown before
generation, reusing the continuity resolver so it cannot disagree with what will
actually run.

### Verification
- `swift run LTXTests`: **1415 passed, 0 failed** (1316 → 1415)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- 1 real LTX Auto Movie run, max concurrent LTX = 1, no stale process
- Production Queue untouched throughout

## 2026-08-12 Character/Opening consistency precision and visibility

**Status: PASS — FALSE ACCESSORY CONFLICT REMOVED.** The persisted Auto Movie
project **旗の子** had a false conflict because an older comparator compared all
accessory colour words as one bag: a blue flag on the Character Sheet appeared
to contradict a brown belt in the Opening Reference. Version 2 compares colours
only for the same recognised accessory object. Different objects are `unknown`,
not conflicting, and `gold`/`golden` are equivalent.

Old saved verdicts are safely rederived from their persisted Character Sheet and
Opening Reference analyses on load. This is entirely offline: no Vision call,
no LTX work, no opening-image substitution, and no canonical CharacterBible
mutation. The consistency summary is now above Planned Shots, so users see it
before reviewing or starting a long Auto Movie render. It remains informational.

The real project now reports `partial` (hairstyle and clothing colours match;
hair colour and accessories unknown), as expected. See
`CHARACTER_OPENING_CONSISTENCY_EVAL.md` and D-089.

## 2026-08-12 Auto Movie Plan Preview Phase A — editable action and camera

**Status: PASS.** Auto Movie now lets the user edit the pre-render **Action**
and existing Director camera fields (**Framing**, **Angle**, **Movement**) for
each planned shot. The edit writes directly to the persisted `Shot.summary` and
`Shot.camera`, rebuilds that shot's `baseCompiledPrompt`, then reapplies only its
existing CharacterBible prompt context. `TakeGenerationCoordinator` therefore
uses the revised `compiledPrompt` when a future take is planned.

The edit boundary intentionally excludes duration, Cut / Continue mode,
continuity source, opening reference, selected/generated takes and queue state.
Existing take prompt snapshots also remain immutable; the UI calls this out as
an edit for future takes. A newly materialized Auto Movie is a fresh Director
plan — there is no unsafe in-place plan regeneration or override migration.

Canonical-app GUI acceptance used Basic Director with first-pass generation
disabled. Shot 1 was edited to a bridge action with `medium close-up`, `low`,
and `slow dolly-in`; the preview and the actual shot card both updated, later
shots kept their Continue sources, and the project retained the edit after an
app restart. No LTX generation was started.

## 2026-08-12 Auto Movie Plan Preview Phase B — editable Cut / Continue

**Status: PASS.** Planned Shots now expose a compact Cut / Continue segmented
control. `Shot.continuityMode` remains the only persisted source of truth; no
override model or new continuity engine was added. Shot 1 is always shown and
executed as Cut, and its control is disabled.

Changing either direction invalidates prepared state derived from the previous
choice (`continuityImageRelativePath`, source-Take/block metadata and Adaptive
Identity Refresh provenance). It does not delete project assets, rewrite past
Take snapshots, or clear an explicit per-shot Starting Image. At execution,
Auto Movie still uses `AutoMovieRunCoordinator` to extract the selected previous
Take's last usable frame for Continue. `TakeGenerationCoordinator` and
`LTXContinuityResolver` now also refuse stale previous-shot paths when the
effective mode is Cut; unrelated valid source precedence is unchanged.

Validation: `swift build` PASS, `swift run LTXTests` **1510 passed / 0 failed**,
Xcode Debug clean build succeeded, and `git diff --check` passed. Canonical GUI
acceptance toggled Shot 2 Continue → Cut → Continue → Cut in the isolated
`Plan Edit GUI Acceptance` project. The preview and lower Shot status stayed in
sync, restart preserved Cut, Shot 1 stayed fixed, and Phase A Action/Camera
values remained. No LTX generation was started.

## 2026-08-12 LTX Generation Diagnostics — Phase 1

**Status: implementation and automated verification PASS; latest-binary GUI
acceptance deferred safely.** Each newly queued Storyboard, Hybrid, or Auto
Movie Take now persists an immutable `GenerationSourceDiagnostics` snapshot.
It records the requested continuity mode, the existing logical source term
(explicit Starting Image, Identity Refresh anchor, inherited last frame,
Opening Reference, Character Anchor, or T2V), actual T2V/I2V mode, a safe
filename/project-relative source reference, continuation Take and its selected
versus latest-completed reason, and Identity Refresh reuse/generation
provenance. It is a reporting record: no source precedence, prompt, strength,
refresh policy, queue, or LTX-generation behavior changed.

At the existing backend image-conditioning boundary, I2V Takes receive the
observed original and effective dimensions and either `No-op` or
`Scale to fill · center crop`; only the backend filename is retained, never a
cache absolute path. Take cards distinguish a queued **source plan** from
historical **recorded generation details**. Earlier Takes with no snapshot show
an explicit unavailable message and still load normally.

Validation: `swift build` PASS; `swift run LTXTests` **1530 passed / 0 failed**;
Xcode Debug `clean build` **BUILD SUCCEEDED**; `git diff --check` PASS. The
debug build is at the canonical DerivedData path documented below, with
executable mtime `2026-08-12 10:16:23 +0900` from HEAD
`4051d91282ba3925447577ee40fe076d9864114e` before the local checkpoint.

The active render completed, so the earlier process was quit only after the
queue reported no pending generations. The latest app was then launched at the
full canonical path as PID `29138` at `10:19:23`; a completed legacy Take
visibly displayed `Generation diagnostics unavailable for this earlier Take.`
No new LTX render was queued merely to populate a new diagnostic Take; the
new-Take source/provenance and image-preparation paths are covered by the
automated integration tests.

### Canonical development app path

Resolve `TARGET_BUILD_DIR` and `WRAPPER_NAME` with
`xcodebuild -showBuildSettings`; do not hard-code the DerivedData hash. At this
time the resolved Debug artifact is
`~/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-*/Build/Products/Debug/LTXVideoGenerator.app`.
GUI acceptance always records `git HEAD`, executable modification time, and the
running process’s executable path, launches the explicit full `.app` path, and
never uses `open -a LTXVideoGenerator` or a `/tmp` build as the normal app.

## 2026-08-12 Selected Take continuity regression fix

**Status: PASS.** Future Auto Movie Continue generations now derive their
starting frame from the current upstream selection at the shared
`TakeGenerationCoordinator.planTakes` boundary. This covers the initial run,
Shot-card Generate/Regenerate, and bulk regeneration without adding a parallel
continuity implementation.

The formal order is: usable selected completed Take, then newest usable
completed Take, otherwise an actionable unavailable-continuity result. Failed,
cancelled, running, missing-output, and corrupt-output selections do not pin the
chain. Cut and an explicit per-shot Starting Image retain their existing
semantics. When the winning upstream Take changes, a previously prepared
Identity Refresh anchor is invalidated before it can outrank the new Last Frame.

Existing Takes and their `GenerationSourceDiagnostics` are never rewritten.
Only newly planned Takes receive the current source snapshot. Selection remains
the existing persisted `Shot.selectedTakeID`; no migration or new source model
was introduced.

Automated validation: `swift build` PASS; `swift run LTXTests` **1547 passed / 0
failed**; Xcode Debug `clean build` **BUILD SUCCEEDED**; `git diff --check` PASS.
Canonical GUI acceptance used isolated project `SELECTED TAKE CONTINUITY GUI`.
Shot 1 Take 2 (`72C073D4…`) remained selected after restart; the historical
Shot 2 Take still reported Take 1 (`5DE36E94…`), while the regenerated Shot 2
Take reported `Selected take · 72C073D4` and a Take-2-named managed continuity
PNG. The production queue stayed empty and no LTX render was started.

## 2026-08-12 LTX Generation Diagnostics — Phase 2

**Status: PASS — runtime/failure diagnostics frozen after this checkpoint.**
Each project-backed Take now has an optional immutable
`GenerationRuntimeDiagnostics` snapshot in addition to the existing Phase 1
`GenerationSourceDiagnostics`. It starts at the existing queue execution
boundary and is finalized on the existing success, failure, or cancellation
paths. No source precedence, selected-Take semantics, Cut/Continue behavior,
Identity Refresh, image conditioning, generation settings, retry ladder, model
selection, or queue ordering changed.

The snapshot separates requested, effective, and actual values. Requested
resolution/frames/duration remain the Take's original planning facts; effective
resolution records the existing backend request after its normal 64-pixel floor
and any already-existing profile resolution; actual resolution, duration, FPS,
and frame count are read only from the output media file. `actualFrameCount` is
saved only when ffprobe explicitly supplies `nb_frames`; duration × FPS is never
used as a substitute. Output existence and metadata readability are recorded
independently, so an unreadable/corrupt output is safe and never becomes fake
metadata.

Failures record a small stage (`sourcePreparation`, `backendLaunch`,
`backendGeneration`, `outputMissing`, `outputValidation`, `cancelled`, or
`unknown`), concise size-capped error text, backend result, and any exit code
already present in the existing error plumbing. Full stderr remains in the
existing local runner log rather than project JSON. Earlier Takes remain runtime
diagnostics-unavailable; the app does not infer or backfill their historical
facts from current settings.

The existing compact Take disclosure now groups **Source** and **Runtime**
without a raw-log viewer. It shows status, elapsed, requested/effective/actual
resolution, available video facts, backend/exit result, failure stage/error,
and output/metadata state. Phase 1 provenance remains unchanged.

Validation: baseline was **1547 passed / 0 failed**; Phase 2 finishes at
**1600 passed / 0 failed**. `swift build`, Xcode Debug `clean build`, and
`git diff --check` pass. The canonical app was resolved by
`xcodebuild -showBuildSettings`, then launched by its full path (not `open -a`)
after stopping the old process. GUI acceptance project
`RUNTIME DIAGNOSTICS GUI ACCEPTANCE` confirmed legacy, success, failure, and
selected-Take continuation details using existing MP4 fixtures; no LTX render,
download, or production-queue work was started.
