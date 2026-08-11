# Dual Conditioning Capability Audit — Character Sheet + Shot 1 Key Image

**Date:** 2026-08-11
**Baseline:** `a881521` on `director-extensions`, worktree clean
**Question:** can Character Sheet (identity/appearance) and Shot 1 Key Image
(scene/composition/first frame) be fed to LTX-2.3 at the same time as
*conditioning with different semantic roles*?

**Classification: PARTIAL — REQUIRES NEW IC-LORA / MODEL WORK**

No real generation test was run, because the capability required to run a
meaningful one does not exist in the current backend. Section 13 of the request
asks for the gap to be classified instead, and section 34 says to stop once the
answer becomes "a new identity IC-LoRA would have to be trained". That is the
answer.

---

## 1. Current backend identity

| Item | Value |
| --- | --- |
| Package | `mlx-video-with-audio` **0.1.36** |
| Location | `/Users/azimnb/ltx-venv/lib/python3.14/site-packages/mlx_video` |
| Python | 3.14 (`/Users/azimnb/ltx-venv/bin/python3`) |
| MLX | 0.32.0 (mlx-metal 0.32.0) |
| Model | `notapalindrome/ltx23-mlx-av-q4`, 20 GB, `model_version 2.3.0`, 48 layers |
| PyTorch / diffusers | **not installed** |

The app calls `python -m mlx_video.generate_av` as a subprocess
(`LTXBridge.swift:362`).

---

## 2. Official LTX-2 upstream — the capability does exist

`ICLoraPipeline` in `packages/ltx-pipelines/src/ltx_pipelines/ic_lora.py`
exposes two *separate* conditioning inputs:

| Argument | Meaning | Handler |
| --- | --- | --- |
| `images` | `List of (path, frame_idx, strength)` — image/keyframe conditioning | `combined_image_conditionings()` |
| `video_conditioning` | `List of (path, strength)` — IC-LoRA reference conditioning | `append_ic_lora_reference_video_conditionings()` |

plus `conditioning_attention_strength` ("Scale factor for IC-LoRA conditioning
attention… 0.0 = ignore conditioning, 1.0 = full conditioning influence",
default 1.0).

So **Q1 is YES**: upstream supports first-frame conditioning and reference
conditioning simultaneously, through genuinely different code paths.

### 2.1 What "reference" actually does (section 6)

This is the part that matters, and it is *not* the same mechanism as the
first-frame path:

- Reference latents are **appended as extra tokens**, not written into an
  output frame position.
- They carry **negative temporal RoPE positions** — outside the generated
  timeline.
- They are given **timestep = 0** (clean, frozen) while target tokens use the
  current sigma, so they are never denoised.
- They are **trimmed before unpatchification**, so they do **not** appear in the
  output frames.
- Their influence is scaled by `conditioning_attention_strength`.
- They require an **IC-LoRA trained for that conditioning type**. The base model
  has no idea what a reference token means.

That is exactly the semantic separation this request is asking for. It is a
real architecture, not a re-labelling of keyframes.

### 2.2 IC-LoRA requirement (Q3)

**Required.** Upstream: "The specific IC-LoRA model should be provided via the
`loras` parameter", and `ICLoraPipeline` takes a `distilled_checkpoint_path` —
IC-LoRA use is tied to the distilled model.

### 2.3 Is there an identity IC-LoRA? (Q4)

**No.** Released LTX-2 control adapters are:

Union Control · Motion Track Control · Detailer · Pose Control · Camera Control
Suite (dolly/jib/static) · HDR IC-LoRA · DubIt

and for LTX-Video 0.9.x: depth, pose, canny, detailer.

None of these is a character identity / appearance / subject reference adapter.
Pose, depth, canny and motion adapters take a *structural* control signal; they
do not carry face, hair or clothing identity. The one identity-flavoured item,
DubIt, is about **speaker identity and lip movement for audio dubbing**, not
visual character appearance.

The HF model tree shows no identity/appearance/subject LoRA file either.

**This is the binding constraint of the whole audit.**

### 2.4 Single still as reference? (Q5)

`video_conditioning` is documented as `(path, strength)` tuples for reference
**videos**. Single-still support is not documented. Even if a still were
accepted mechanically, without an identity IC-LoRA there is nothing that would
read it as "this is who the character is".

---

## 3. Current MLX backend — the capability does not exist

**Q2: NO.** Evidence, from the installed source rather than from upstream:

### 3.1 There is exactly one image slot

`python -m mlx_video.generate_av --help` exposes only:

```
--image IMAGE                 Path to conditioning image for I2V
--image-strength STRENGTH     1.0 = full denoise, 0.0 = keep original
--image-frame-idx IDX         Frame index to condition (0 = first frame)
```

Introspecting the public entry point confirms it — of 24 parameters on
`generate_video_with_audio`, the only image-related ones are:

```
image = None
image_strength = 1.0
image_frame_idx = 0
```

There is no `--reference-image`, no `video_conditioning`, no
`conditioning_attention_strength`.

### 3.2 The only conditioning primitive is temporal latent replacement

`mlx_video/conditioning/latent.py` provides exactly one mechanism,
`VideoConditionByLatentIndex`:

> "This replaces the latent at the specified frame index with the conditioned
> latent and controls how much denoising is applied via the strength parameter."

`apply_conditioning()` walks the frame axis and, for conditioned positions,
substitutes the latent and sets `denoise_mask = 1.0 - strength`. The conditioned
latent **occupies a frame in the generated timeline and appears in the output**.

That is the opposite of the reference mechanism in 2.1. It is a keyframe, not a
context token.

### 3.3 No reference / IC-LoRA machinery anywhere

A search of the package for `ic_lora`, `iclora`, `video_conditioning`,
`reference_latent`, `reference_image`, `conditioning_attention` returns **no
matches** except one false positive:

`adain_filter_latent(latents, reference_latents, factor)` — Adaptive Instance
Normalization that aligns per-channel statistics between the stage-1 and stage-2
upsampling passes. It is a normalisation helper and has nothing to do with
reference conditioning.

### 3.4 LoRA exists in the package but not for LTX

`mlx_video/lora/` implements generic weight-space LoRA
(`delta = scale · strength · (lora_B @ lora_A)` applied to Linear layers). Two
problems:

1. It is **only imported by the WAN path** (`convert_wan.py`,
   `models/wan/loading.py`). `grep -i lora mlx_video/models/ltx/` returns
   nothing — the LTX model path has no LoRA support at all.
2. Weight-space LoRA is **not sufficient for IC-LoRA**. IC-LoRA needs the
   reference-token pathway (2.1) *in addition to* the weight delta. Loading the
   weights without the token plumbing would change the model's behaviour without
   ever giving it a reference to look at.

### 3.5 The transformer has no reference stream

`models/ltx/transformer.py` block signature:

```python
def __call__(self, video: Optional[TransformerArgs] = None,
                   audio: Optional[TransformerArgs] = None)
```

Two modality streams (video, audio) plus text cross-attention. There is no third
context stream.

### 3.6 Position grid cannot express reference coordinates

`create_video_position_grid()` builds coordinates with
`np.arange(0, num_frames)` — non-negative, contiguous, derived purely from
`(frames, h, w)`. There is no API to append tokens at negative temporal
positions, which is precisely what reference conditioning needs.

---

## 4. Current first-frame path (sections 10, Q6)

Traced end to end; it works and is unaffected by this audit.

```
Shot 1 Key Image
  → GenerationRequest.sourceImagePath        (Models/GenerationRequest.swift:180)
  → LTXBridge builds ["--image", path,
                      "--image-strength", <strength>]   (LTXBridge.swift:362)
  → generate_av: VAE-encode → stage1_image_latent
  → VideoConditionByLatentIndex(latent, frame_idx=0, strength)
  → apply_conditioning(...) replaces latent at frame 0,
    sets denoise_mask = 1.0 - strength there
  → noise added scaled by the mask; per-token timesteps scaled by the mask
  → repeated identically for stage 2
```

- **Frame index:** 0 (first frame), configurable via `--image-frame-idx`.
- **Semantics:** latent *replacement* at that frame, with partial re-noising
  governed by `denoise_mask = 1.0 - strength`.
- **It consumes the only image slot.** This is the crux: the Key Image already
  occupies the single conditioning input.

**Q6: yes**, Shot 1 Key Image can remain the true first frame — it already is.

---

## 5. Answer to the central question

| | |
| --- | --- |
| Can the current MLX backend take `--image` = Key Image **and** a separate reference = Character Sheet, with independent semantics? | **NO** |

Not partially — there is no second input, no reference primitive, no IC-LoRA
support in the LTX path, and no way to place tokens outside the generated
timeline.

### What is explicitly *not* a solution

Per sections 24 and 25 of the request, none of these would count and none was
attempted:

- Character Sheet at frame 0 + Key Image at frame N (multi-keyframe). The
  primitive `apply_conditioning(state, [list])` *would* accept several
  conditionings, so this is technically reachable with a small patch — but both
  images would be **frames in the output timeline**, which is the wrong
  semantics and would visibly show the character sheet.
- Side-by-side concatenation, collage, alpha blend, compositing the sheet into
  the key image.

---

## 6. Gap classification (section 13)

Two levels apply at once:

**LEVEL 3 — MLX backend lacks the IC-LoRA / reference architecture.**
Would require: reference-token append path, negative-temporal RoPE coordinates,
per-token timestep = 0 for reference tokens, trimming before unpatchification,
`conditioning_attention_strength`, LoRA loading wired into the LTX model path,
and an MLX conversion of the adapter weights.

**LEVEL 4 — the required IC-LoRA weights do not exist for identity use.**
No official character/appearance/subject IC-LoRA exists for LTX-2 or LTX-Video.

**LEVEL 4 is binding.** Completing all of LEVEL 3 would yield a backend that can
apply depth/pose/canny/camera control from a reference video — and still could
not use a Character Sheet to steer who the person is. Building the plumbing
first would be wasted effort against this goal.

---

## 7. Upstream-vs-Mac status (section 14)

**UPSTREAM CAPABILITY EXISTS (mechanically) BUT CURRENT MAC BACKEND DOES NOT
EXPOSE IT — AND EVEN UPSTREAM HAS NO IDENTITY ADAPTER.**

The Mac backend was not switched to PyTorch and no such change is recommended:

- `ICLoraPipeline` requires the **22B distilled** checkpoint in PyTorch.
- The Mac runs a **Q4 MLX** conversion at 20 GB on 48 GB unified memory.
- An unquantised 22B PyTorch model plus VAE, Gemma text encoder and upsampler
  will not fit in 48 GB without aggressive offload, and the MPS path is not what
  Lightricks tests against.

Swapping backends to gain a capability that still lacks an identity adapter
would be a large regression in speed and memory for no gain on the actual goal.

---

## 8. Memory feasibility (section 15) — qualitative only

No benchmark was run, so no numbers are invented.

- **Reference tokens themselves: small.** One still reference at the 768×512
  profile adds roughly one latent frame of tokens (about 24×16 = 384 at
  spatial scale 32) against a 121-frame sequence. Sequence-length growth is a
  few percent; attention cost grows a little faster but stays modest.
- **Switching to the upstream PyTorch 22B distilled pipeline: large**, and the
  real obstacle. See section 7.

---

## 9. Real test status (sections 12, 16–20)

**Not run.** The A-vs-C comparison requires condition C (Key Image + Character
Sheet reference conditioning), which the backend cannot express. Running
condition A alone would only re-confirm the existing, already-validated
first-frame path, and running a faked C would violate sections 24–25.

Consequently there are no `DUALCOND_*` review videos, no face/hair/clothing
scores, no artifact scores, and no measured peak memory. Recording those from a
test that could not be run would be fabrication.

**Failure mode (section 21): I — pipeline/API unsupported.**

---

## 10. Answers

| # | Question | Answer |
| --- | --- | --- |
| Q1 | Official LTX-2: reference + first-frame at once? | **YES** — `images` + `video_conditioning` + `conditioning_attention_strength` |
| Q2 | Current Mac MLX backend supports both? | **NO** — one image slot, temporal replacement only |
| Q3 | Requires IC-LoRA? | **YES**, and the distilled checkpoint |
| Q4 | Existing IC-LoRA for character identity? | **NO** — only depth/pose/canny/detailer/union/motion/camera/HDR/DubIt |
| Q5 | Single Character Sheet still usable as reference? | Undocumented; moot without Q4 |
| Q6 | Shot 1 Key Image can stay the real first frame? | **YES** — that is today's path |
| Q7 | Sheet steers face/hair/clothes without wrecking composition? | **Untestable** on this stack |
| Q8 | Smallest work to bring it into the app? | See section 6 — LEVEL 3 plumbing *plus* LEVEL 4 adapter training |
| Q9 | Compatible with Opening Reference / Auto Movie / Continuity / Queue? | Would be additive; nothing in this audit changed them |
| Q10 | Productize, Temporal Bridge, or Z-Image? | See below |

### Q9 detail

Nothing was modified. Had the capability existed, it would slot in beside the
existing single-image path rather than replacing it: Continuity Chain and
Opening Reference both use `sourceImagePath` as the first frame, and a reference
input would be an additional field on `GenerationRequest` and
`ProductionJobSnapshot`. The Production Queue was **not touched** —
`ProductionQueueCoordinator`, `ProductionQueueService`, `ProductionQueueStore`
and `FilmJobDecider` are unchanged, and no compile dependency was found.

---

## 11. Recommendation (Q10)

**Do not productize dual conditioning, and do not start IC-LoRA training.**

Ranked next steps:

1. **Temporal Bridge (the deferred fallback) — try this next.** It needs no new
   model capability: it uses the single image slot that already exists, which is
   why it is reachable now. Worth a controlled real test on its own terms.
2. **Local still generation (Z-Image or similar) to build a scene-like Opening
   Reference that already contains the right character.** This is the most
   direct fit for the existing architecture: the app's Opening Reference path
   is already validated, and the identity problem moves to a still-image model
   where identity conditioning is a solved, available capability. This is
   probably the highest-value direction.
3. **Watch upstream for a character/identity IC-LoRA.** If Lightricks releases
   one, revisit — at that point the LEVEL 3 MLX work becomes worth scoping.

Training a custom identity IC-LoRA is out of scope per section 34 and is a poor
trade here: it would need a dataset, training infrastructure the Mac does not
have, and an MLX conversion of the result.

---

## 12. Verification

No production source was changed by this audit — it is documentation only.

```
git status        clean at a881521 before this file was added
swift build       unchanged (no source touched)
swift run LTXTests 1123 passed, 0 failed (baseline, unchanged)
```

Production Queue behaviour is unchanged.
