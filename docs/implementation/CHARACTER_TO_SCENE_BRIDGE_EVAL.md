# Character-to-Scene Temporal Bridge — Evaluation

**Date:** 2026-08-11
**Baseline HEAD:** `0918365` on `director-extensions`, worktree clean
**Hypothesis:** a Character Sheet cannot be used directly as an Auto Movie
starting image, but LTX-2.3 might *evolve* it over time into a scene-like frame
that can then be used through the existing Opening Reference path.

**Classification: PASS WITH LIMITATION**

The bridge itself works and is the surprise of this experiment. What does not
work is the step after it: the Auto Movie continuity chain does not carry a
high-specificity character identity past a meaningful reframe — and it does not
do so for a *hand-made* scene reference either. The bridge is not the
bottleneck.

> **Later correction — see §R1.** The follow-up experiment kept this
> classification but corrected *why* identity was lost. It was not the reframe:
> the Director had written a contradictory costume into every shot prompt, shot 3
> never ran at the reframe strength, and identity had already dissolved inside
> shot 1. Read §R1 before relying on the attribution in this section.

---

## 1. Source asset

| Item | Value |
| --- | --- |
| Character | **Adventurer Heroine** |
| Character ID | `7F76DC58-1349-40F4-9D1F-B29352D83605` |
| Project | `Character Reference Extraction Phase 2 Actual` (`07FA8292…`) |
| Asset used | **Front** reference (`type=front`, label "Front") |
| Path | `Assets/Characters/7F76DC58…/References/8962D90A-0D53-45AC-A0AC-092979F2F55A.png` |
| Source dimensions | **287 × 774** (aspect 0.371) |
| Original file | not modified |

Visible attributes: dark-brown hair in a high ponytail with side bangs; navy
sailor-style vest over a white long-sleeve shirt; navy bow with a gold emblem;
cream hooded cape; brown leather belt with pouches and a brass pocket
watch/compass; navy pleated skirt with white stripes; navy knee-high socks;
brown buckled leather boots; brown fingerless gloves. Plain white background.
The crop retains the partial text "eference Sheet" along the top edge — a
reference-sheet artifact that is useful as a leakage tell.

### 1.1 An aspect problem that had to be solved first

`mlx_video.utils.load_image()` resizes with
`image.resize((width, height), LANCZOS)` — **no aspect preservation, no
letterboxing**. Feeding a 0.371-aspect strip to a 768×512 (1.5) target stretches
the character ~4× horizontally and makes her unrecognisable, which would have
measured distortion recovery rather than the hypothesis. Two variants were
therefore prepared, and the difference between them turned out to be the single
most important result here.

| Variant | Preparation | Result |
| --- | --- | --- |
| **A — aspect-fit** | figure scaled to full height (190 × 512), centred on white | scene forms **only inside the 190 px column**; white bars never change |
| **B — aspect-fill** | 287 × 191 band cropped and upscaled 2.68× to fill 768 × 512 | full-frame cinematic scene forms |

---

## 2. Bridge configuration (both runs identical apart from the input image)

| Setting | Value |
| --- | --- |
| Backend | `mlx-video-with-audio` 0.1.36, MLX 0.32.0 |
| Model | `notapalindrome/ltx23-mlx-av-q4` (LTX 2.3.0, Q4, 20 GB) |
| Text encoder | `mlx-community/gemma-3-12b-it-4bit` |
| Resolution | 768 × 512 |
| Frames / fps | 121 @ 24 fps (≈ 5.04 s) |
| Seed | **12345** (fixed, both runs) |
| Steps / CFG | 30 / 3.0 |
| Image strength | **1.0** — production Starting Image semantics (`OpeningReferencePolicy.openingImageStrength = 1.0`) |
| Tiling | aggressive |
| Audio | `--no-audio` (frames only; A/V denoising still runs, so video is unaffected) |

No strength matrix was run — §11. Strength 1.0 means `denoise_mask = 0` at frame
0, i.e. frame 0 *is* the reference image.

### Bridge prompt (verbatim)

> A young woman with dark brown hair in a high ponytail with side bangs stands
> naturally in a quiet stone courtyard outside an old library at dusk. She wears
> a navy blue sailor-style vest over a white long-sleeve shirt with a blue bow
> and gold emblem, a cream hooded cape, a brown leather belt with pouches and a
> brass pocket watch, a navy pleated skirt with white stripes, navy knee-high
> socks, and brown leather boots with buckles. The plain white studio background
> transitions into a realistic stone courtyard with weathered flagstones, stone
> walls and the library entrance behind her. Cinematic medium-wide composition,
> natural relaxed posture, soft directional evening light, real environmental
> depth.

Negative: `text, labels, watermark, reference sheet, character sheet, turnaround
sheet, split panel, multiple views, collage, white studio background, plain
background, worst quality, inconsistent motion, blurry, jittery, distorted`

### Cost

| Run | Time | Peak memory |
| --- | --- | --- |
| Bridge A | **273.8 s** | **14.70 GB** |
| Bridge B | **278.5 s** | **14.70 GB** |

Comfortable on a 48 GB M4 Pro. Two bridge generations used of the maximum three.

---

## 3. Bridge A (aspect-fit) — frame scores

Scale 0–3. Columns: Ref-removal / Face / Hair / Clothing / Overall identity /
Scene / Framing / Pose / Artifacts / Opening-Reference usability.

| Frame | Ref | Face | Hair | Cloth | Ident | Scene | Fram | Pose | Art | Use |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 % | 0 | 3 | 3 | 3 | 3 | 0 | 0 | 0 | 3 | 0 |
| 50 % | 1 | 3 | 3 | 3 | 3 | 0 | 0 | 0 | 3 | 0 |
| 65 % | 1 | 1 | 2 | 3 | 2 | 2 | 1 | 1 | 2 | 1 |
| 75 % | 1 | 1 | 2 | 3 | 2 | 2 | 1 | 1 | 2 | 1 |
| 85 % | 1 | 1 | 2 | 3 | 2 | 2 | 1 | 1 | 2 | 1 |
| 95 % | 1 | 1 | 2 | 3 | 2 | 2 | 1 | 1 | 2 | 1 |
| Final | 1 | 1 | 2 | 3 | 2 | 2 | 1 | 1 | 2 | 1 |

**Progression:** plate → text fades (50 %) → courtyard appears between 50 % and
65 % → frozen. The costume survives well and the character turns to profile.

**The defect:** measured over the whole clip, the padding columns change by
**0.22 / 0.20** mean absolute difference from frame 0 to the last frame, and
their column means stay at **252.0** (white). The centre column changes by
**77.75**. Scene formation is strictly confined to the region that already held
image content — synthetic white padding is inert. Every late frame is a
white-barred vertical strip, unusable as a 768×512 opening reference.

**Also frozen in time:** per-frame motion falls to 0.01–0.04 after ~67 %. The
evolution *completed and stalled*; it did not run out of time. §19 only permits
a longer bridge when "5 s ends too early", which is not the case here, so no
8-second run was made.

**Bridge A fails Gate #1** (ref-removal 1 < 3, usability 1 < 2).

---

## 4. Bridge B (aspect-fill) — frame scores

| Frame | Ref | Face | Hair | Cloth | Ident | Scene | Fram | Pose | Art | Use |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 25 % | **3** | **2** | **3** | **2** | **2** | **3** | **3** | 2 | **3** | **3** |
| 50 % | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |
| 65 % | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |
| 75 % | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |
| 85 % | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |
| 95 % | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |
| Final | 3 | 1 | 2 | 2 | 2 | 3 | 3 | 2 | 3 | 2 |

**Progression:** the model zoomed *out* from the input close-up and had built a
complete stone courtyard — flagstones, stone walls, wooden doors, wall lanterns,
a building entrance — by 25 %. It then held that scene, essentially static, to
the end.

**Selected frame: 25 %** (§17 priority order — plate gone in all candidates, so
selection fell to identity/clothing/face, where 25 % is clearly strongest
because the character is largest and best resolved).

Saved as
`Videos/CHARBRIDGE_best_opening_still_768x512_20260811_125505.png`.

**Costume drift, recorded honestly:** the short shoulder cape became a long
knee-length cream coat, and the pleated skirt lengthened. Retained: navy vest,
white shirt, navy bow, gold emblem, brown belt with pouches, knee-high socks,
brown buckled boots, brown ponytail with side bangs.

### Gate #1

| Criterion | Required | B @ 25 % | |
| --- | --- | --- | --- |
| Reference-sheet removal | ≥ 3 | 3 | ✅ |
| Face | ≥ 2 | 2 | ✅ |
| Hair | ≥ 2 | 3 | ✅ |
| Clothing | ≥ 2 | 2 | ✅ |
| Overall protagonist | ≥ 2 | 2 | ✅ |
| Scene quality | ≥ 2 | 3 | ✅ |
| Artifacts | ≥ 2 | 3 | ✅ |
| Opening Reference usability | ≥ 2 | 3 | ✅ |

**GATE #1: PASS.**

The core question of §43 — can a raw Character Sheet evolve into a clean
cinematic frame *without losing the character* — is answered **yes**, provided
the input fills the frame.

---

## 5. Auto Movie A vs C

Both created through the real GUI and run through the Production Queue.

| | A — control | C — bridge reference |
| --- | --- | --- |
| Title | CB CONTROL A | CB BRIDGE C |
| Project | `01589734…` | `D5A0840B…` |
| Opening Reference | none (T2V) | `CHARBRIDGE_best_opening_still…png` |
| Preset / resolution | Standard, 768 × 512 | Standard, 768 × 512 |
| Frames / steps | 121 / 25 per shot | 121 / 25 per shot |
| Model | LTX-2.3 Distilled Q4 | LTX-2.3 Distilled Q4 |
| Director | Auto → Local AI `qwen3.6-claw-fast` | same |
| Target duration | 20 s | 20 s |
| Shots planned | **4** | **5** |
| Final duration | 20.06 s | 25.07 s |
| Continuity | Standard 0.8 / Reframe 0.5 (unchanged) | same |

Brief (identical): *"A young woman walks across a quiet stone courtyard toward
an old library. She slows near the entrance. The camera moves closer as she
looks over her shoulder. She then turns back toward the building."*

**Confounds, stated plainly.** The app assigns per-take seeds and the New Auto
Movie dialog exposes no seed field, so **A and C do not share seeds** (A shot
seeds 252128558 / 415278271 / 972174618 / 438422675). The Director also planned
**4 shots for A and 5 for C**. Both follow from testing through the real product
path; neither was avoidable without changing production code, which §3 and §35
forbid. This is a two-sample qualitative comparison, not a controlled trial.

### 5.1 Results

**A (T2V control)** — protagonist identity collapses shot to shot:

| Shot | What appears |
| --- | --- |
| 1 | distant woman in a dark coat, from behind |
| 2 | two distant figures, one in a light coat |
| 3 | Western woman, reddish-brown hair, cream sweater |
| 4 | tanned dark-haired woman, sunglasses pushed up |

Effectively three to four different women. Lighting also drifts from dusk to
harsh daylight.

**C (bridge reference)**:

| Shot | What appears |
| --- | --- |
| frame 0 | **the Adventurer Heroine exactly** — the bridge still is the first frame |
| 1 | figure walking away; cream cape and dark boots retained |
| 2 | distant figure, cream coat, consistent silhouette |
| 3 | **identity collapses** — Western woman, wavy auburn hair, beige trench coat, jeans |
| 4 | same collapsed identity as shot 3 |
| 5 | same coat/silhouette, longer wavy hair |

### 5.2 Scores (whole-movie, 0–3)

| Criterion | A | C |
| --- | --- | --- |
| Face continuity | 0 | 1 |
| Hair continuity | 0 | 1 |
| Clothing continuity | 1 | 2 |
| Overall protagonist continuity | 0 | 2 |
| Body / silhouette | 1 | 2 |
| Environment continuity | 1 | 3 |
| Camera freedom | 3 | 3 |
| Narrative progression | 2 | 3 |
| Shot-to-shot continuity | 0 | 2 |
| Opening quality | 1 | 3 |

### 5.3 Shot-by-shot

- **Shot 1** — A: anonymous distant figure. C: the intended character, correct
  costume, correct golden-hour courtyard. **C clearly better.**
- **Shot 2** — A: two figures, ambiguous. C: single consistent cream-coated
  figure in the same courtyard. **C better.**
- **Shot 3 (the reframe, §27)** — A: a completely new woman. C: also a new
  woman, but she keeps the cream/beige coat and the belt, and she stays
  consistent for the rest of the film. **C better, but the specific identity is
  gone.** This is the decisive negative result.
- **Shot 4** — A: yet another woman. C: same person as shot 3. **C better.**
- **Shot 5** — C only; same coat and silhouette, hair longer.

**Camera freedom:** unchanged. The opening reference did not restrict the
Director; C actually received a *longer* plan (5 shots) with a wider range.

---

## 6. Comparison with a hand-made scene reference (§30)

Two earlier runs that used a manually prepared scene-like Opening Reference were
re-examined for context:

| Run | Character specificity | Identity outcome |
| --- | --- | --- |
| `OpenRef Create Test` | **low** (man in a dark suit) | holds across all 4 shots |
| `青髪少女` | **high** (blue-haired girl) | **blue hair lost after shot 1**; environment holds strongly |
| `CB BRIDGE C` (this run) | **high** (Adventurer Heroine) | costume abstraction holds; specific identity lost at shot 3 |

The pattern is about the *character*, not about how the still was made. A
hand-made scene reference with a high-specificity character loses the
distinctive trait too. So the honest ranking is:

> **T2V  <  Temporal Bridge ≈ manual scene reference**

and not `T2V < Temporal Bridge < manual scene reference`. The Temporal Bridge
produces a still that is about as useful as one a human would prepare. The
ceiling is imposed by the continuity chain, which propagates *composition,
environment and broad costume* well and *facial identity* poorly across a
reframe.

---

## 7. Failure modes observed (§21)

- **Bridge A:** F (reference artifacts persist — as inert white padding) and a
  variant of A (scene forms, but only in part of the frame).
- **Bridge B:** J — works as intended.
- **Auto Movie C:** E — identity changes while clothing broadly survives.
  Not B, C, D, G or H: the key image composition was not destroyed, no reference
  plate leaked, no artifacts, no OOM.

---

## 8. Answers

| Question | Answer |
| --- | --- |
| Can a Character Sheet evolve into a clean cinematic frame without losing the character? | **Yes** — bridge B, best frame at 25 % |
| Does the white studio background become a scene? | Only where the source had content. Synthetic padding is inert (0.2/255 change). |
| Is a longer bridge worth trying? | **No** — motion stalls after ~67 %; it finishes early, it does not run out of time |
| Where is the best frame? | **Early-middle (25 %)**, not late — the §14 assumption was wrong for the fill variant |
| Is the resulting Auto Movie materially more consistent than T2V? | **Yes**, on environment, silhouette, opening quality and shot-to-shot stability |
| Does the Character Sheet identity survive the movie? | **No** — lost at the shot-3 reframe |
| Is the bridge the bottleneck? | **No** — a hand-made reference fails the same way on a high-specificity character |

---

## 9. Recommendation

**Do not productize the "Generate Opening Still" UI yet**, but keep the bridge —
it is cheap (≈ 4.6 min, 14.7 GB) and it clearly beats T2V for the opening shot
and for environment continuity.

The next bottleneck is *not* still generation. It is identity propagation across
a reframe in the continuity chain. Two directions worth more than a UI:

1. **Investigate reframe identity propagation.** Shot 3 is where every run
   fails, including hand-made references. `ContinuityStrengthPolicy` already
   drops to 0.5 for reframes; whether that trade (composition freedom vs
   identity) can be improved is a concrete, bounded question.
2. **A local still model (Z-Image or similar) would not fix this either.** It
   would produce a nicer opening still, but the identity would still be lost at
   shot 3. Worth noting before committing to that path — the previous audit
   recommended it, and this experiment narrows where its benefit actually lies
   (a better shot 1, not a more consistent film).

If a "Generate Opening Still" feature is built later, two findings must be
carried into it:

- the input must be **aspect-filled, never padded** — padded regions never
  become scene;
- the extraction should sample **early-middle frames (~25 %)**, not late ones.

---

## 10. Review files

All under `~/Library/Application Support/LTXVideoGenerator/Videos`, copied with
`cp -n`; nothing overwritten. 32 `CHARBRIDGE_*` files, verified present:

- `CHARBRIDGE_A_bridge_aspectfit_5s_768x512_20260811_125505.mp4`
- `CHARBRIDGE_B_bridge_aspectfill_5s_768x512_20260811_125505.mp4`
- `CHARBRIDGE_best_opening_still_768x512_20260811_125505.png` ← selected still
- `CHARBRIDGE_input_aspectfit_768x512_…png`, `CHARBRIDGE_input_aspectfill_768x512_…png`
- `CHARBRIDGE_A_frame{25,50,65,75,85,95,Final}_…png`
- `CHARBRIDGE_B_frame{25,50,65,75,85,95,Final}_…png`
- `CHARBRIDGE_CONTROL_A_t2v_final_768x512_20260811_134654.mp4`
- `CHARBRIDGE_C_bridge_ref_final_768x512_20260811_134654.mp4`
- `CHARBRIDGE_A_shot0{1..4}_…png`, `CHARBRIDGE_C_shot0{1..5}_…png`
- `CHARBRIDGE_C_openingframe_…png`, `CHARBRIDGE_AC_compare_…png`

---

## 11. Verification

No production source was changed — evaluation and documentation only.

```
git status         clean at 0918365 before this file
git diff --check   PASS
swift run LTXTests 1123 passed, 0 failed (baseline, unchanged)
```

Production Queue untouched (`ProductionQueueCoordinator`,
`ProductionQueueService`, `ProductionQueueStore`, `FilmJobDecider`). Opening
Reference semantics untouched — the still was fed through the existing path.

---

# Reframe Identity Propagation — Change-Focused I2V Prompt Delta

**Date:** 2026-08-11 (follow-up)
**Baseline HEAD:** `5bc720a`, worktree clean
**Classification (reframe): PASS WITH LIMITATION — but not for the reason expected**

Everything in the sections above is retained unchanged. This section adds a
controlled delta and **corrects one attribution in it**.

## R1. Correction to the earlier conclusion

The earlier section said identity was "lost at the shot-3 reframe" and inferred
that reframe continuity was the ceiling. Reading the persisted project shows two
facts that change the diagnosis.

**R1.1 — The Director wrote the wrong character into every prompt.**
`CB BRIDGE C`'s auto-created Character Bible is:

```
name: "Character1"
defaultCostume: "Beige trench coat, dark jeans, boots"
appearance: { hair: "", faceDescription: "", ... }   // all empty
referenceAssets: []
```

The brief never named the Adventurer Heroine, and **the Opening Reference image
is not analysed into the Character Bible**. So all five compiled prompts began:

> `CHARACTER 1: Character1. Current costume: Beige trench coat, dark jeans, boots.`

The beige trench coat that "appeared" from shot 3 onward is not drift. It is
what the prompt asked for, in every shot, including shot 1.

**R1.2 — Shot 3 did not run at the reframe strength.**
`settingsSnapshot.imageStrength = 0.8` for shots 2, 3 and 4 — the Standard
value. `ContinuityStrengthPolicy` never classified shot 3 as a reframe, so the
0.5 reframe profile was never exercised in that run.

**R1.3 — Identity actually dissolved inside shot 1.** Sampling shot 1 at
0/10/20/30/40/60/80/99 % shows a continuous slide: full Adventurer Heroine at
0 %, cape lengthening by 20 %, navy vest gone by ~40 %, and a small distant
figure in a plain cream coat by 60 %. Shot 3 did not break identity; it was the
first close-up after identity had already gone.

**R1.4 — The continuity frame handed to shot 3 contains no identity.** It is a
wide courtyard in which the character is a ~30 × 80 px figure seen from behind:
no face, no hair detail, no costume detail. A close-up generated from it *must*
invent a face.

## R2. Source guidance (attribution)

The change-focused hypothesis came from external prompt-design material, not
from our own measurements:

- **Article author's workflow** — the linked `scenario_i2v.md` states: *"Unless
  the user explicitly specifies outfit or location changes, ALL scenes must
  feature the same character, outfit, and location as the provided image"*, and
  that *"Camera angles, movements, expressions, and actions may vary between
  scenes."* It does **not** explicitly say "do not re-describe the image"; that
  is an inference from its structure.
- **Official ComfyUI LTX2 text-gen node** (`comfy_extras/nodes_textgen.py`) is
  explicit: *"Describe only changes from the image: Don't reiterate established
  visual details. Inaccurate descriptions may cause scene cuts."*

That second clause is a direct prediction about condition A, and it is worth
separating from what we measured. Everything below is **our result on our
LTX-2.3 MLX stack**, not a guaranteed property of the model.

## R3. Design

Four conditions, one variable at a time, all through the same backend with fixed
settings. Not run through the GUI — §9 of the request, and because the previous
A/C comparison was confounded by per-take seeds and differing shot counts.

| | Prompt | Source frame | Strength |
| --- | --- | --- | --- |
| **A** | production shot-3 prompt (verbatim) | shot-3 continuity frame | 0.8 |
| **B** | change-focused | shot-3 continuity frame | 0.8 |
| **C** | change-focused | shot-3 continuity frame | 0.5 |
| **D** | change-focused | **Opening Reference still** | 0.8 |

`A → B` isolates **prompt strategy**. `B → C` isolates **conditioning
strength**. `B → D` isolates **whether the source frame contains identity**.

Held identical everywhere: seed **1721937161**, 768 × 512, 121 frames, 24 fps,
25 steps, CFG 3.0, `ltx23-mlx-av-q4`, `gemma-3-12b-it-4bit`, tiling auto,
`--no-audio`, empty negative prompt (production used none).

**Deviation from the request, stated plainly.** §8 specified strength 0.5 for
A/B on the assumption that shot 3 ran at the reframe profile. It ran at 0.8
(R1.2), so A/B were run at 0.8 to reproduce production exactly, and 0.5 became
condition C. §6/§7 asked for the shot-3 continuity frame as the only source;
that frame contains no identity (R1.4), so answering the actual question of §48
required condition D as well.

### Prompts

**A (verbatim from `promptSnapshot`):**

> CHARACTER 1: Character1. Current costume: Beige trench coat, dark jeans,
> boots. Location: Stone courtyard, time: Late afternoon, weather: Clear,
> lighting: Warm, long shadows. The camera close-up shot, eye-level angle,
> static camera. A close-up focuses on the woman's face as she looks over her
> shoulder, eyes scanning the empty courtyard behind her. Lighting: Warm, long
> shadows. Audio: Wind rustling leaves.

**Classification: A3 — Mixed, leaning appearance-heavy.** Roughly the first half
reconstructs costume, location, weather and lighting that the image already
carries; the second half is genuine delta (camera scale, head turn, eye action).

**B/C/D (change-focused):**

> The same subject from the input frame remains visually consistent. The camera
> moves closer into a close-up as she turns her head to look back over her
> shoulder, her eyes scanning the empty courtyard behind her. Her existing
> appearance, clothing, hairstyle, the surrounding architecture, the warm low
> evening light and the long shadows all continue unchanged. No new person
> enters the frame. No wardrobe change. No scene change. Audio: Wind rustling
> leaves.

**Semantic A→B difference:** the costume dictation and the environment/lighting
reconstruction are replaced by one compact continuity statement; the delta
(camera closer, head turn, gaze) is preserved verbatim in intent. No Face Lock
language, no expanded negative prompt.

## R4. Results

Each run: ~270 s, peak **14.70 GB**.

| Criterion (0–3) | A | B | C | D |
| --- | --- | --- | --- | --- |
| Face continuity | 0 | 0 | 0 | **3** |
| Hair continuity | 0 | 1 | 1 | **3** |
| Clothing continuity | 0 | 1 | 1 | **3** |
| Overall protagonist identity | 0 | 1 | 1 | **3** |
| Body / silhouette | 1 | 1 | 1 | **3** |
| Environment continuity | 3 | 3 | 3 | **3** |
| Requested reframe achieved | 3 | 3 | 3 | **3** |
| Camera freedom | 3 | 3 | 3 | **3** |
| Artifact cleanliness | 3 | 3 | 3 | **3** |
| Narrative beat achieved | 3 | 3 | 3 | **3** |

- **A** produced exactly its dictated costume: a Western woman with wavy auburn
  hair in a **beige trench coat**, dark red top, jeans and belt. The prompt got
  what it asked for.
- **B** invented a different woman — Asian features, dark braided hair, patterned
  cream jacket. Not the reference, but notably **not the wrong costume either**:
  removing the dictation removed the contradiction.
- **C** (strength 0.5) behaved like B. Lowering strength neither restored
  identity nor visibly increased camera freedom — both already achieved the
  full wide → close-up reframe.
- **D** preserved the Adventurer Heroine through the entire wide → close-up
  reframe: brown hair with side bangs, navy collar with gold trim, cream cape,
  and a face that matches the reference. It executed the exact shot-3 beat —
  close-up, looking back over the shoulder — **with identity intact**.

### Drift timing

| | first hair drift | first clothing drift | first different-person |
| --- | --- | --- | --- |
| A | ~20 % | ~20 % | ~20 % (first frame a person is resolvable) |
| B | ~20 % | ~20 % | ~20 % |
| C | ~20 % | ~20 % | ~20 % |
| D | **none through 99 %** | none | **none** |

In A/B/C the "drift" is not drift at all — it is the first moment a face becomes
resolvable, and it is invented from nothing. The camera transition and the
identity decision coincide because the identity never existed in the source.

## R5. Diagnostic (§19)

**Mechanism: B — loss of source conditioning, with A as a contributing amplifier.**

The evidence is a clean dissociation. Prompt strategy changed *what* was
invented (A's dictated trench coat vs B's free invention) but not *whether*
invention happened. Source content changed whether invention happened at all
(D vs B, identical prompt, seed and strength). Strength changed neither.

So on this stack the dominant variable is **whether the conditioning frame
contains resolvable identity at the scale the next shot needs** — not the prompt
and not the reframe itself. The ComfyUI guidance is still borne out in its
narrower claim: an inaccurate description (A's costume) does steer the result
away from the image.

## R6. Reframe classification

**PASS WITH LIMITATION — identity survives a reframe when the source frame
carries identity; change-focused prompting alone does not rescue a source that
does not.**

Against the request's cases this is closest to **CASE 3 for A/B/C** (prompt
semantics insufficient; the bottleneck is deeper) combined with a **new finding
from D**: the reframe itself is not the problem. §14's expectation — that higher
strength would trade camera freedom for identity — was **not** observed: 0.8 and
0.5 produced the same reframe and the same (absent) identity.

The original Temporal Bridge classification is unchanged: **PASS WITH
LIMITATION**.

---

# Bridge Prompt Strategy Delta

## R7. Existing bridge prompt classification

Recovered verbatim (§2 above). **Appearance-heavy**: 112 words containing 13
distinct appearance-reconstruction tokens — hair colour, ponytail, side bangs,
sailor vest, long-sleeve shirt, blue bow, gold emblem, cream hooded cape,
leather belt, brass pocket watch, pleated skirt, knee-high socks, buckled boots.
A meaningful delta therefore existed, so Bridge B2 was run.

## R8. Bridge B2

Identical to the successful aspect-fill bridge in every respect — same
`front_fill_768x512.png`, seed 12345, 768 × 512, 121 frames, strength 1.0, 30
steps, CFG 3.0, tiling aggressive, and the **same negative prompt** — with only
the positive prompt rewritten to describe the transformation rather than the
character. No cinematic suffix (§25). 270.8 s, 14.70 GB.

**Result: WORSE.**

| Criterion (0–3) | Bridge (existing) @25 % | Bridge B2 (best) |
| --- | --- | --- |
| Reference-sheet removal | **3** | **0** |
| Face similarity | 2 | 2 |
| Hair similarity | 3 | 2 |
| Clothing similarity | 2 | 1 |
| Overall protagonist | 2 | 1 |
| Scene quality | 3 | 2 |
| Cinematic framing | 3 | 1 |
| Pose naturalness | 2 | 2 |
| Artifact cleanliness | 3 | 1 |
| Opening Reference usability | **3** | **0** |

The failure is specific and instructive: B2 rendered the character standing
**inside a literal reference-sheet panel** — a white board carrying faint
annotation-label blocks, mounted in front of the courtyard — for the entire
clip. The sheet layout was not dissolved; it was promoted to a physical prop in
the scene. Costume also drifted further (pleated skirt → blue jeans, sailor vest
→ harness).

**Usable-frame window:** existing bridge ≈ 20–30 % (and scene-valid to the end);
B2 **none**.

**Bridge delta classification: WORSE.**

The reason is coherent with R5 rather than contradicting it. For a *continuation*
the image is the truth and should not be re-described. For the **bridge** the
input is a reference sheet that we explicitly want destroyed, so "keep everything
consistent with the input image" is the wrong instruction — it preserves the
sheet. Change-focused prompting is a policy for CONTINUE shots, not for the
bridge.

No Bridge C was run: §27 forbids beautifying a failed B.

## R9. Vision-LLM audit (§32) — no implementation

**YES, with a caveat.** The app already has a working local vision pathway:
`OllamaCharacterSheetVisionEnvironmentClient` enumerates vision-capable models
via `/api/tags` capabilities (falling back to `/api/show`), and
`CharacterSheetAnalysis` posts image bytes to `/api/generate` and parses
structured output. It is proven in production — the Adventurer Heroine's
Character Bible was populated this way (`analysisProvider: ollama`,
`analysisModel: agents-a1:32k`), extracting hair, complexion, build, costume,
accessories, expressions and detected views.

Locally, `agents-a1:32k` and `qwen3.6-claw-fast:latest` both report
`capabilities: [tools, thinking, completion, vision]`.

So a future Change-Focused I2V Director could inspect a continuity frame and
emit only the delta. **The caveat is that R1.1 shows the more valuable use
first:** the Opening Reference image is currently never analysed, which is why
the Director invented "Beige trench coat, dark jeans, boots" for a movie whose
opening frame showed a navy-uniformed adventurer. Vision-analysing the opening
reference into the Character Bible would remove an actively wrong instruction
from every shot.

## R10. Decision matrix (§45), ranked by evidence

1. **C — give important reframe shots a fresh visual anchor.** Strongest
   evidence: D differs from B only in having a source that carries identity, and
   it is the only condition that preserved the character. Any mechanism that
   supplies an identity-bearing frame at a scale change should work.
2. **A′ — analyse the Opening Reference into the Character Bible** (a variant of
   A, and cheaper). R1.1 shows the Director currently contradicts the reference
   image in every prompt. This is a bug-shaped problem with a bounded fix.
3. **A — change-focused Director policy for CONTINUE/I2V.** Supported but
   second-order: it removed a harmful contradiction (A→B) without restoring
   identity. Worth doing, and it must be scoped to CONTINUE shots only — R8
   shows it is actively harmful for the bridge.
4. **D — productize the Temporal Bridge for those key images.** It already
   produces a usable identity-bearing still; it becomes valuable once (1) exists.
5. **E — Z-image / local still model.** Unchanged from the previous audit and
   still not urgent: it would produce nicer key images, but D shows the existing
   bridge already produces one good enough to hold identity through a reframe.
6. **B — accept the tradeoff and limit reframes.** Not supported: there is no
   identity-vs-camera tradeoff to accept. 0.5 and 0.8 both reframed fully, and D
   reframed fully *and* kept identity.

**F (no further work) is not the right call** — R1.1 is a concrete defect.

## R11. Review files

Under `~/Library/Application Support/LTXVideoGenerator/Videos`, `cp -n`, nothing
overwritten. **33 `REFRAME_*` and 42 `CHARBRIDGE_*` files**, all verified:

- `REFRAME_A_productprompt_s0.8_768x512_20260811_142646.mp4`
- `REFRAME_B_changefocus_s0.8_768x512_20260811_142646.mp4`
- `REFRAME_C_changefocus_s0.5_768x512_20260811_142646.mp4`
- `REFRAME_D_changefocus_identitysrc_s0.8_768x512_20260811_142646.mp4`
- `REFRAME_{A,B,C,D}_frame{0,20,40,60,80,99}pct_…png`
- `REFRAME_source_shot3_continuity_…png`, `REFRAME_source_openingstill_…png`
- `REFRAME_face_compare_…png`, `REFRAME_AB_row_…png`, `REFRAME_CD_row_…png`
- `CHARBRIDGE_B2_changefocus_5s_768x512_…mp4` + 8 frames + row

Additional generation time: 5 renders × ~270 s ≈ **22.5 minutes**.

---

# Opening Reference Vision Appearance Sync + CONTINUE Change-Focused Policy

**Date:** 2026-08-11 (implementation)
**Baseline HEAD:** `8366d1e`
**Classification: PASS WITH LIMITATION — root cause fixed, source-information loss remains**

The two previous sections diagnosed the problem. This one implements the fix and
measures it in the real product.

## S1. Root cause, in source

`StoryboardDirector.swift:552`:

```swift
var bible = characterBible
if bible.characters.isEmpty {
    for (name, outfit) in (draft.initialState?.characterOutfit ?? [:]) {
        bible.characters.append(CharacterBibleEntry(name: name, defaultCostume: outfit))
    }
}
```

The LLM Director invents `characterOutfit` from the brief text. For `CB BRIDGE C`
that was `{"Character1": "Beige trench coat, dark jeans, boots"}`.
`PromptCompiler.compile(characters:)` then emits
`Current costume: <that>` into **every** shot via
`CharacterPromptPipeline.recompile`.

And the ordering made it unavoidable: in `StoryboardView.create()` the Director
ran **first**, and the Opening Reference was imported **after**. The plan could
not have seen the image.

## S2. What was built

| File | Role |
| --- | --- |
| `Models/OpeningReferenceAppearance.swift` | what the image shows + `EffectiveAppearanceResolver` precedence |
| `Services/OpeningReferenceAppearanceAnalyzer.swift` | narrow vision prompt, schema, tolerant parsing |
| `Services/OpeningReferenceAppearanceSession.swift` | reuses the existing model selection + Ollama provider |
| `Services/OpeningReferenceSync.swift` | seeding, merging, staleness |
| `Services/ContinuationPromptPolicy.swift` | CONTINUE = change-focused |

Changed: `FilmProject` (one optional field), `PromptCompiler` (style switch),
`StoryboardView` (ordering), `OpeningReferenceSection` (status line).

**No second vision backend.** Model selection reuses
`CharacterSheetVisionEnvironmentService`; the request reuses
`OllamaCharacterSheetVisionProvider`. Loopback only — nothing leaves the machine.

### Ordering, now enforced by construction

```
choose image → import managed asset → analyse → seed Bible → Director → apply → recompile → save → queue
```

The Director is handed a Bible that already matches the image, so it has nothing
to contradict; anything it still produces is superseded afterwards.

### Precedence

1. explicit user-authored appearance
2. what the Opening Reference visibly shows
3. the Director's auto-generated guess
4. no claim

`EffectiveAppearanceResolver.isUserAuthored` treats an entry as the user's when
it carries reference assets, locked traits, or any prose the Director never
writes. The Director's seeding path sets only `name` + `defaultCostume`, so a
placeholder is recognisable and may be superseded; anything richer is not.

### Failure and ambiguity

`unavailable` / `failed` / `ambiguous` all apply **nothing**. Vision missing is
not an error and never blocks a movie — it simply produces no evidence.
`subjectCount > 1` is `ambiguous` on purpose: guessing which person is the
protagonist would write the wrong costume into every prompt, which is the bug
this exists to prevent.

### Cache / invalidation

`OpeningReferenceAppearance.sourceRelativePath` records which managed asset was
analysed. `OpeningReferenceSync.invalidateIfStale` drops derived state when the
path no longer matches, so **Replace** cannot leave the previous costume behind
and **Clear** removes it.

### Queue compatibility

`ProductionQueueCoordinator`, `ProductionQueueService`, `ProductionQueueStore`
and `FilmJobDecider` are **untouched**. Analysis happens at create time and is
persisted on the project before the job is enqueued, so a job waiting behind
another resolves exactly the same appearance. Queue tests still pass unchanged.

## S3. CONTINUE change-focused policy

`ContinuationPromptPolicy.style(for:)` — `continue` → change-focused;
`cut`, `auto`, unset → descriptive (unchanged). `auto` stays descriptive because
the run coordinator may resolve it to a cut at generation time.

A CONTINUE prompt gets one compact statement —
*"The same subject and the existing visual state continue from the input frame."* —
plus only fields that actually **differ** between the state entering the shot
and the state after its explicit changes. A real wardrobe change is still
described ("now wears …"); an unchanged one is not restated.

No "Face Lock", no "identity guaranteed", no expanded negative prompt.

**The Temporal Bridge is deliberately excluded.** It is not a Shot and never
passes through this pipeline. Applying continue-semantics to it preserved the
character sheet as a physical panel in the scene (D-073) — transform and
continue are opposite instructions.

## S4. Before / after, from the real projects

**Old (`CB BRIDGE C`)** — Bible:

```
name: "Character1", defaultCostume: "Beige trench coat, dark jeans, boots",
appearance: all empty, referenceAssets: []
```

Every shot prompt began
`CHARACTER 1: Character1. Current costume: Beige trench coat, dark jeans, boots.`

**New (`VB NEW`)** — vision output (`agents-a1:32k`), verbatim:

```json
{ "status": "analysed", "subjectCount": 1, "faceVisible": true,
  "hairDescription": "brown, shoulder-length",
  "clothingDescription": "white blouse with blue vest and bow tie, dark skirt",
  "outerwear": "light-colored cape",
  "accessories": "belt, small bag/prop on hip",
  "silhouetteDescription": "slender figure standing upright",
  "distinctiveTraits": "wearing a cape over school-style uniform" }
```

Bible after sync:

```
defaultCostume: "white blouse with blue vest and bow tie, dark skirt, light-colored cape"
hair: "brown, shoulder-length"
accessories: "belt, small bag/prop on hip"
```

Compiled prompts:

- **Shot 1 (cut)** — `CHARACTER 1: Character1. Hair: brown, shoulder-length. … Current costume: white blouse with blue vest and bow tie, dark skirt, light-colored cape. …` — descriptive policy retained, now describing the **right** character.
- **Shots 2–4 (continue)** — `The same subject and the existing visual state continue from the input frame. Location: … The camera medium-close-up shot … slow push-in camera. Character1 looks back over her left shoulder towards the camera. …`

**No occurrence of "Beige trench coat" anywhere in the new project.**

## S5. Real E2E

`VB NEW`, Standard 768×512, 121 frames/shot, 25 steps, LTX-2.3 Distilled Q4,
gemma-3-12b-it-4bit, Director Auto → Local AI, continuity 0.8/0.5 unchanged,
opening reference = `CHARBRIDGE_best_opening_still_768x512_20260811_125505.png`
(the same still the failing run used). 4 shots, 20.06 s, 15:09→15:28.

### Shot 1 drift — the old failure point

| | 0 % | 20 % | 40 % | 60 % | 80 % | 99 % |
| --- | --- | --- | --- | --- | --- | --- |
| **Old** | full costume | cape lengthening | **navy vest gone** | distant cream coat | tiny figure | tiny figure |
| **New** | full costume | intact | intact | intact | intact | **intact** |

**No drift in shot 1.** The costume, hair and silhouette hold for the whole
shot. This is the single clearest result of the change.

### Per-shot scores (0–3)

| | Face | Hair | Clothing | Identity | Silhouette | Environment | Camera | Narrative |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Shot 1 | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| Shot 2 | 2 | 3 | 3 | 3 | 3 | 3 | 3 | 3 |
| Shot 3 | 1 | 2 | 2 | 2 | 2 | 3 | 3 | 3 |
| Shot 4 | 1 | 2 | 2 | 2 | 2 | 3 | 3 | 3 |

First clothing drift: **shot 3** (navy sailor vest → blue-grey dress).
First clear different-person impression: **shot 3**.
Old run, for comparison: first clothing drift **inside shot 1 (~40 %)**, clear
different person by **shot 3** with a *beige trench coat*.

### Inherited source-frame quality — the remaining bottleneck

| Shot | Source frame | Subject | Face | Costume |
| --- | --- | --- | --- | --- |
| 2 | last frame of shot 1 | large, front-on | **visible** | **fully visible** |
| 3 | last frame of shot 2 | medium, **from behind** | **not visible** | visible |
| 4 | last frame of shot 3 | medium, profile | partly | visible |

This maps exactly onto the scores. Shot 2 inherited a face and kept it. Shot 3
inherited a back view — the costume survived (it was visible) and the face was
re-invented (it was not). Identity survives precisely as far as the source frame
carries it, which is D-072 reproduced in production rather than in a harness.

## S6. Acceptance

**Phase 1 — PASS.** Vision analysis runs, runs *before* the Director, persists
safely, supersedes auto-generated guesses, preserves user-authored data,
invalidates on Replace/Clear, decodes legacy projects, and degrades safely when
vision is unavailable.

**Phase 2 — PASS.** CONTINUE uses the change-focused policy; CUT and T2V are
unchanged; unchanged costume is not restated; explicit transitions still appear;
camera/action/expression deltas are preserved; the Bridge is untouched.

**Real E2E — PASS WITH LIMITATION.**

- (A) Shot 1 no longer drifts toward an invented costume — **yes, eliminated**.
- (B) Identity survives materially longer — **yes**, first drift moved from
  inside shot 1 to shot 3.
- (C) Inherited source frames carry far more identity — **yes**, shot 2's source
  is now a clear front-on view instead of a distant figure.
- (D) A later meaningful reframe preserves the character — **partially**: the
  costume family survives; the face does not when the source shows her back.
- (E) The remaining bottleneck is clearly **source-information loss**, not prompt
  contradiction.

### Known limitation, stated plainly

CONTINUE prompts still carry the Director's own `Location: … lighting: …` text
from `baseCompiledPrompt`. Only the *character* block is change-focused. Removing
scene text as well would mean rewriting shot-level prompt generation, which §26
placed out of scope. It did not cause identity drift in this run.

## S7. Next step

Per §45 stop condition: the upstream contradiction is fixed and the residual
failure is source-information loss, so **prompt tuning stops here**. The
evidence now points at one architecture: when a shot needs a scale change that
the inherited frame cannot support — typically a close-up after a back view —
give it a fresh identity-bearing anchor rather than a lower strength or a longer
prompt. The Temporal Bridge already produces exactly such an anchor.
