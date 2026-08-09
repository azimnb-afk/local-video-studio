# BENCHMARK_RESULTS

Hardware signature: Mac16,11 / M4 Pro / 48GB / macOS 26.5.2 — class: Measured. Other RAM tiers: Hypothesis only (no hardware).

## Phase 0 baseline — Measured 2026-08-08
Profile: 512x320, 25 frames, 15 steps, 24 fps, seed 42, cfg 3.0, model ltx23_distilled_q4 (notapalindrome/ltx23-mlx-av-q4), text encoder gemma-3-12b-it-4bit, tiling auto, HF_HUB_OFFLINE=1 (no network egress during render — verified generation succeeds fully offline).

| Run | Audio | Wall | Peak footprint | Swap delta | ffprobe actual | Status |
|---|---|---|---|---|---|---|
| T2V-A-ON | ON | 49 s | 23.66 GB | none (7484M→7484M) | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| T2V-A-OFF | OFF | 46 s | 17.23 GB | −405 M | 512x320 h264 24fps, 1.04 s | OK |
| I2V-A-ON | ON | 48 s | 23.66 GB | none | 512x320 h264 24fps + aac 48kHz 2ch, 1.01 s | OK |
| I2V-A-OFF | OFF | 47 s | 17.23 GB | none | 512x320 h264 24fps, 1.04 s | OK |

Notes:
- Audio pipeline adds ~6.4 GB peak footprint (23.66 vs 17.23 GB) at this profile.
- 25 frames @ 24fps yields 1.01–1.04 s actual duration (ffprobe = source of truth).
- Logs + MP4s: /tmp/ltx_baseline/ (regenerate any time with scripts/benchmark_baseline.sh).

## Regression run — post-implementation (2026-08-08, after Phase 7)
| Run | Wall | Peak footprint | ffprobe | MD5 vs baseline |
|---|---|---|---|---|
| REGRESSION-T2V-A-ON | 53 s* | 23.46 GB (< baseline 23.66) | identical (512x320, 1.01 s, h264+aac) | **IDENTICAL** (bf8020b1f55f73a62c075f2df1c65a8d) |

*Wall time contaminated: a queue-soak validation ran concurrently on the same
machine during this measurement; memory peak and the bit-identical output are
the meaningful signals. Same seed → byte-identical MP4 proves the official
fast path is completely unchanged (0% regression).

## Queue soak — short validation (2026-08-08, 3 sequential takes, audio OFF)
| Take | Seed | Wall | Peak |
|---|---|---|---|
| 1 | 1001 | 51 s | 17.215 GB |
| 2 | 1002 | 43 s | 17.228 GB |
| 3 | 1003 | 43 s | 17.227 GB |

Peak flat across runs (+0.07%): each generation is its own subprocess, so exit
is a hard reclamation boundary. Full 20-take soak: `scripts/queue_soak.sh 20`
(≈17 min) — HARNESS READY. Concurrency was 1 throughout (sequential script,
matching the app's single-flight queue).

## Regression acceptance
Post-change official-path runs must stay within 1.05x of: wall 49 s (audio ON) / 46 s (audio OFF); peak 23.66 / 17.23 GB; identical actual resolution/fps/duration/audio streams.

## Auto Movie continuity chain — real LTX run (2026-08-10)

Harness: `scripts/automovie_continuity_e2e.sh` (M4 Pro / 48 GB, ltx23_distilled_q4
+ gemma-3-12b-4bit, 512×320 / 25f / 15 steps / 24fps, audio off, `HF_HUB_OFFLINE=1`).
Brief: a woman approaches an old stone library, reaches the entrance, opens the
door and steps inside — shot 1 text-to-video, shots 2 and 3 continuing from the
previous shot's final frame.

| Step | Result |
|---|---|
| Shot 1 (T2V) | 45 s → 512×320, 1.04 s |
| Shot 1 → 2 frame extraction | 185,845-byte PNG |
| Shot 2 (I2V from inherited frame) | 44 s → 512×320, 1.04 s |
| Shot 2 → 3 frame extraction | 182,035-byte PNG |
| Shot 3 (I2V from inherited frame) | 44 s → 512×320, 1.04 s |
| Final assembly (stream copy) | h264 512×320, **3.125 s**, playable |

Sequential throughout; one generation at a time.

### Observed continuity (honest assessment)
- **Building / set: strongly preserved.** The same stone facade, red-brown
  doors, window rhythm and background spire persist across all three shots.
- **Lighting and colour: preserved.** Consistent overcast palette.
- **Wardrobe and general figure: preserved.** Dark coat and long light hair
  stay consistent.
- **Hand-off is real.** Each continuing shot's first frame matches the previous
  shot's final frame, confirming the inherited image reached the renderer.
- **Identity: not verifiable and not claimed.** The face is small and
  motion-blurred at this resolution. This mechanism is a visual anchor, not
  identity conditioning; the same person is never guaranteed.
- **Composition leakage is real and significant.** Camera angle and framing
  stayed essentially locked across all three shots, and the narrative beats did
  not progress: the subject kept walking along the same facade instead of
  reaching the entrance and entering. With `imageStrength = 1.0` the inherited
  frame dominates the prompt.

### Consequences
1. Chaining every shot would be wrong; this run is direct evidence for the
   `cut`-by-default rule (D-029). Scene changes and establishing shots must cut.
2. Continuous action across a chained shot needs either a lower image strength
   or fewer chained shots in a row. Exposing per-shot continuity strength is a
   sensible follow-up, deliberately **not** implemented here.
3. Continuity quality should be described as *improved visual continuity*, never
   as guaranteed identity or guaranteed scene progression.

Evidence: `/tmp/ltx_automovie_e2e/` (per-shot MP4s, extracted frames,
`continuity_sheet.png` comparing each shot's first and last frame, and
`auto_movie_final.mp4`).

## Continuity strength calibration (2026-08-10)

Harness: `scripts/continuity_strength_calibration.sh`. One transition, one
source frame (the previous run's shot-1 final frame), one prompt, seed 42,
512×320 / 25f / 15 steps / 24fps / audio off — only `--image-strength` varied.
Each render took 44–46 s.

| strength | anchor SSIM(source, first) | leakage SSIM(source, last) | read |
|---|---|---|---|
| 1.0 | 0.966 | 0.931 | scene held, shot barely evolves |
| **0.8** | **0.952** | **0.827** | **scene held, clear push-in and advance** |
| 0.7 | 0.943 | 0.835 | no more progression than 0.8, weaker anchor |
| 0.6 | 0.930 | 0.819 | slight extra motion, drift begins |
| 0.4 | 0.891 | 0.806 | hair/face visibly change |

Selected **0.8** (`AutoMovieRunCoordinator.continuityImageStrength`): it captures
0.105 of the 0.125 total available progression for 0.014 of anchor, and nothing
below it progresses further.

### Prompt is a separate lever from strength
Same strength (0.8) and same source frame, prompt changed only:

| shot-3 prompt | end-frame SSIM vs inherited frame |
|---|---|
| "…cinematic, **steady camera**." | 0.953 (composition holds) |
| "…**The camera pushes in** to a closer shot and follows her…" | 0.911 (composition moves) |

A prompt that asks for no camera movement holds the composition regardless of
strength. The in-app `PromptCompiler` already emits a per-shot
"{scale} shot, {angle} angle, {movement} camera" line and the Auto Movie split
path varies scale and movement between shots, so the app is better placed than
the hand-written prompts in the end-to-end script.

### Three-shot end-to-end at 0.8
45/44/44 s renders, frames extracted between shots, assembled to a playable
3.125 s h264 512×320 movie. Building, wardrobe, hair and lighting carried across
all three shots; the subject scale advanced between shots. Identity remains
unverifiable at this resolution and is not claimed.

Evidence: `/tmp/ltx_strength_calib/strength_sheet.png`,
`/tmp/ltx_strength_calib7/`, `/tmp/ltx_automovie_e2e_08/continuity_sheet_08.png`.

## Auto Movie cinematic progression (2026-08-10)

Harness: `scripts/automovie_progression_e2e.py` — unlike the earlier shell
script, shot prompts are not hand written. It calls the same Local AI Director
with the same system prompt the app sends, compiles each shot the way
`PromptCompiler` does, and honours the Director's own continuity decision.

### Planning quality — clearly improved
Before, the split path produced the same sentence four times
("… — story beat N of 4"). The Director now plans genuinely different beats:

| Shot | Camera | Action |
|---|---|---|
| 1 | wide · eye-level · dolly-back | walks the overgrown path toward the entrance |
| 2 | medium-wide · low · static | arrives at the doors, stops, looks up at the archway |
| 3 | extreme-close-up · eye-level · static | gloved hand pulls a key and inserts it into the lock |
| 4 | medium-close-up · eye-level · static | the heavy door creaks inward, revealing darkness |

Four shots at 50/46/46/46 s assembled to a playable 4.167 s h264 512×320 movie.
Camera scale, angle and movement all change between shots, and the insert
close-up is a real cinematic beat rather than a restatement.

### The cost of an all-cut plan — measured, and still open
That run marked every shot "cut", so nothing was inherited and each shot was
independently text-to-video. The result: shot 1 is a dark-haired woman in a
black dress, shot 2 a woman in silver armour, shot 4 a middle-aged man. Cutting
everything gives excellent cinematic variety and **no character or wardrobe
continuity at all**.

Continuation rate across sampled plans for the same brief:

| Director instructions | plans with ≥1 continuation |
|---|---|
| conservative rule only | 0 / 3 |
| + worked cut/continue/continue/cut example | 2 / 3 |
| + explicit "same place, same character, same moment MUST continue" | 2 / 4 |

The worked example made continuation reachable; the stronger restatement did not
improve on it measurably. This small fast planning model retains a cut bias that
prompt wording alone does not fix reliably.

The Director's decision is deliberately **not** overridden: silently promoting a
planned cut to a continuation would re-introduce the composition leakage this
work removed, and would override directorial intent. Recommended next step is a
deterministic reconciliation pass that promotes a planned cut to a continuation
only when the Director's own stated location, time and cast are unchanged and no
scene-change directive exists — or simply a stronger planning model.

Evidence: `/tmp/ltx_progression_e2e/` (director_plan.json, per-shot prompts and
MP4s, `progression_sheet.png`, `auto_movie_final.mp4`).

## Continuity Reconciliation (2026-08-10)

### Effect on real Director plans
Same brief, three fresh plans from the local Director, reconciled with the
deterministic pass:

| sample | raw Director | effective after reconciliation |
|---|---|---|
| 1 | cut, continue, continue, cut | unchanged |
| 2 | **cut, cut, cut, cut, cut** | **cut, continue, continue, continue, cut** |
| 3 | cut, cut, continue, continue, cut | unchanged |

The all-cut failure case is repaired and plans that already contained
continuations are left alone. The closing interior shot in sample 2 correctly
stayed a cut. Every sampled plan now ends up with at least one continuation,
against 2/4 for the prompt-only attempt.

### Real four-shot run (`scripts/automovie_progression_e2e.py`)
Plan: wide approach → medium-wide arrival → close-up key in lock → interior.
Director itself chose cut, continue, continue, cut; reconciliation left it
unchanged. 63/47/47/46 s, assembled to a playable 4.167 s h264 512×320 movie.

**Character and environment continuity: clearly improved.** Shots 1–3 keep the
same blonde woman in the same white dress with the same red bodice, the same
arched stone facade, the same mossy courtyard and the same light. The previous
all-cut run produced a dark-haired woman in black, then a woman in silver
armour, then a middle-aged man across a single scene.

| boundary | anchor SSIM (first frame vs inherited) | end drift |
|---|---|---|
| shot 2 | 0.937 | 0.716 |
| shot 3 | 0.935 | 0.885 |

Shot 1 first frame vs shot 3 last frame: 0.601 — the scene evolves while staying
recognisably the same place and person.

### Honest cost: detail inserts after a wide inherited frame
Shot 3 was planned as a close-up of a key entering a lock. The render kept the
full-figure framing and the key/lock action did not appear: inheriting a wide
full-body frame at 0.8 constrains a requested detail insert more than the prompt
can overcome. Shot 4, a genuine cut, was free to show a new interior — and, being
a cut, shows a different person.

So the trade-off moved rather than disappeared:

| run | narrative/camera progression | character continuity |
|---|---|---|
| all-cut (previous) | strong | broken |
| reconciled (now) | strong across cuts, weak inside a continued run | maintained within the scene |

This is the insert-shot limitation anticipated during design. It is recorded
rather than worked around: no per-shot strength levels were added, and detail
inserts are not force-cut, because that would trade the continuity this pass
just secured. A per-shot continuity strength — looser for a planned detail
insert — is the natural next step and is deliberately not implemented here.

## Adaptive Continuity Strength calibration (2026-08-10)

Case: the real failure from the previous run — a medium-wide full figure
inherited into a planned close-up of a key entering a lock. Same source frame,
prompt, seed, model, encoder, 512×320 / 25f / 15 steps / 24fps, audio off; only
`--image-strength` varied.

| strength | SSIM vs inherited (first) | reframed? | coherent? |
|---|---|---|---|
| 0.80 | 0.935 | no | yes |
| 0.65 | 0.909 | no | yes |
| 0.50 | 0.871 | no | yes |
| 0.35 | — | no | yes |
| 0.20 | — | partly | **no** — a hand pasted over the old composition |

**Controls that settle the cause**
- Same prompt with **no inherited image at all**: still no key-in-lock insert —
  it rendered a different woman indoors. The prompt/duration cannot produce this
  insert even unconstrained.
- A second, easier reframe (a face close-up rather than an object detail) behaved
  identically at 0.8 and 0.5: SSIM fell 0.881 → 0.803 while the framing stayed
  full-figure.

So loosening the anchor changes pixels but not composition, and it loses
coherence (0.2) before it releases framing. There is no good intermediate value.
This is a single-frame-conditioning and duration limit at this profile, not a
tuning failure.

**Selected:** standard 0.8 (unchanged), reframe **0.5** — the loosest setting
that preserved person, wardrobe and set in every sample.

### Real four-shot run with adaptive strength
Director planned wide → medium-wide → extreme-close-up → medium; reconciliation
promoted shot 2 (`cut → continue`); the resolver then chose:

| boundary | framing | policy | strength |
|---|---|---|---|
| shot 2 | wide → medium-wide (1 rung) | standard | 0.8 |
| shot 3 | medium-wide → extreme-close-up (4 rungs) | **reframe** | **0.5** |
| shot 4 | — | cut | none |

57/47/47/46 s, assembled to a playable 4.167 s movie. Character and environment
continuity held across both continuations (same dark-haired woman, same coat,
same colonnade, same light). Shot 3 moved further from its inherited frame than
a standard continuation (SSIM 0.891 vs 0.934) but **kept the full-figure framing
— the planned detail insert still did not happen**.

### Conclusion
The classification mechanism works and is correctly scoped, and the looser anchor
measurably increases freedom without harming continuity. It does not deliver a
large reframe, and no strength does. Achieving a planned detail insert needs
something other than single-frame conditioning at this profile — a longer or
higher-step render, or conditioning that is not a single first frame. Two
policies are sufficient for now precisely because finer granularity would be
tuning noise across a range with no measurable framing benefit.

## Capability-Aware Shot Planning (2026-08-10)

### Plan sampling across four unrelated briefs
Real plans from the local Director (`qwen3.6-claw-fast`, the app's own system
prompt), each handed to the shipping Swift policy via
`swift run LTXTests --capability-plan` — the rules are not reimplemented in the
harness. Script: `scripts/capability_plan_sampling.py`.

| brief | shots | adjusted | what changed |
|---|---|---|---|
| library / unlock door | 5 | 1 | close-up → medium-close-up (3-rung reframe + fine hand/object action) |
| forest / glowing shrine | 4 | 1 | medium-close-up → medium (3-rung reframe) |
| parked car / get inside | 4 | 2 | medium-close-up → medium; medium-wide → medium (3-rung pull-back) |
| control room / start machine | 4 | 1 | close-up → medium-close-up (3-rung reframe) |

Every brief triggered at least one adjustment, so the policy is not specific to
the library case that motivated it. In all four, the action text kept its
subject, verb and object; the only additions were a visibility note where a fine
manipulation was detected. Camera variety survived: the effective plans still
range from wide to close-up.

One conservative over-trigger is visible and accepted: the car brief's fourth
shot is a planned cut with no explicit scene directive and no interior/exterior
crossing, so it is treated as inheriting and its framing is pulled from
medium-wide to medium. Reconciliation would very likely promote that boundary
anyway, and the cost is one rung.

### Controlled single shot, previous failing case
Same inherited frame, prompt lineage, seed and render settings; only the plan
differs.

| plan | framing | strength | result |
|---|---|---|---|
| previous (Director's) | close-up | 0.5 (reframe) | full-figure, no unlock action |
| capability-aware | medium-close-up | 0.8 (standard) | full-figure, no unlock action |

Honest result: the rewrite did not rescue this shot. The inherited frame here
shows the subject on the path, not at the door, so the unlock beat has no
precondition in the image to act on. This is a plan-level problem, which is what
the full run tests.

### Real four-shot Quick Auto Movie E2E
Brief: "A young woman walks toward an old stone library, reaches the entrance,
unlocks the door, and steps inside." 512×320, 25f, 15 steps, seed 42, audio off.

Pipeline behaved exactly as designed:

| stage | result |
|---|---|
| Director plan | wide / medium-wide / **close-up** / medium, all `cut` |
| capability planning | shot 3 `highRisk` → **medium-close-up** (3-rung reframe while inheriting) |
| reconciliation | shots 2 and 3 promoted `cut → continue` (framing changes did not block it) |
| strength policy | shot 2 standard 0.8, shot 3 **standard 0.8** — the reframe fallback was no longer needed |
| assembly | 4 shots → 4.167 s playable movie |

Outcome per success criterion:

| criterion | result |
|---|---|
| character continuity | **PASS** — same woman, same teal dress across shots 1–3 |
| environment continuity | **PASS** — same colonnade, doorway and light |
| narrative progression | **FAIL** — approach / arrive / unlock are not distinguishable |
| camera progression | **FAIL** — shots 1–3 hold the inherited composition |
| beat feasibility | **FAIL** — the unlock beat is still not visible |

SSIM against the inherited frame: shot 2 first 0.942 → last 0.815 (it does move);
shot 3 first 0.930 → last 0.940 (it barely moves at all).

### Conclusion
The classification and rewrite work, generalise across briefs, and interact with
reconciliation and adaptive strength exactly as intended — the plan is now honest
about what this profile can render, and the reframe fallback stopped being needed
in the target scenario. What did not improve is the outcome that matters: at 0.8
the inherited composition is held so firmly that even a planned two-rung change
does not happen, so the unlock beat still is not shown.

The limit is therefore not the plan and not the strength in isolation, but
single-frame conditioning at this profile: an inherited frame that does not
already contain the preconditions for the next beat cannot be moved to them in
25 frames. Wording stays scoped to what was tested — at this Quick profile, large
reframes and fine object-detail inserts were unreliable.
