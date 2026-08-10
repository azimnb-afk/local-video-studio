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
