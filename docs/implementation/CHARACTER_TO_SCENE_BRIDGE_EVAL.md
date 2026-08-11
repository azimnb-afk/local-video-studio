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
