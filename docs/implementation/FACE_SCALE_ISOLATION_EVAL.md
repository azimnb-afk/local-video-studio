# Source Face Scale / Framing Isolation Evaluation

Date: 2026-08-11

Starting HEAD: `3799b31`

Classification: **PASS — ASPECT-PRESERVING INPUT IS THE STRONGER LEVER**

> Production follow-up: the mandatory exact Condition A repeat used the same
> input bytes and complete generation state. A2 was byte-for-byte identical to
> A1 and again contained no geometric melt (**REPEAT PASS**). The app now applies
> centered aspect-preserving scale-to-fill/crop at the common backend I2V
> boundary. A real Auto Movie with the untouched original 1672x941 image used
> the same `(131, 0, 1410, 940)` content window and avoided Historical H's severe
> f64/f84 collapse. See `OPENING_REFERENCE_ASPECT_FIX_EVAL.md`.

## Question and freeze

The retained historical Shot 1 failed inside raw generation, with its strongest
face collapse at frame 84 / 3.500 s. This calibration asks whether substantially
more facial information in the source prevents, delays or reduces that
transient. Production Auto Movie, Opening Reference, Vision Sync, Character
Anchor, Adaptive Identity Refresh, Director, PromptCompiler, Queue, Assembly and
camera policy remained frozen. Exactly two new LTX generations ran sequentially.
No model weight was downloaded and no cloud service was used.

## Historical control H

- Exact source:
  `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E/Assets/OpeningReference/opening-reference-2575EA16-CEC2-4C28-9588-0D02B34B74CA.png`
- Source SHA-256: `ba2d31efcf3683e4b7ae1f0eb68c42c8d5bd336658364f87e7e158922518679a`
- Original dimensions: 1672x941
- Historical preprocessing: direct non-aspect-preserving Lanczos resize to
  768x512
- Historical backend face: about 38.0x38.0 px / 0.368% of frame
- Raw:
  `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/1D7BAF27-063B-401A-9B2D-3E0C106943CF.mp4`
- Raw SHA-256: `4f17d646ef7cf30e32f45ca32ca2a694fc78b04041d63a3a52f061feb2b31f78`
- Readable video: 117 frames / 4.875 s at 24 fps

H was not regenerated. It remains historical visual evidence.

## Controlled sources

Both sources are deterministic pixel crops of the same immutable original,
created as final 768x512 PNGs before the backend. The backend therefore receives
768x512 and performs an effective 1:1 resize. Neither source has blank padding
or a non-uniform aspect stretch.

### Condition A — aspect-preserved full framing

- File: `FACEMELT_SCALE_A_full_768x512_20260811.png`
- SHA-256: `5c165656a4891be10bf9a78b9d150d66d3263261c52de1328e2a70bfc6d7eac8`
- Original crop: x=131, y=0, width=1410, height=940 (exactly 3:2)
- Resize: uniform Lanczos 1410x940 -> 768x512, scale approximately 0.54468
  on both axes
- Face: 40.2x40.2 px / 0.411%
- Framing: full body, flag and battlefield, close to the original composition
- Orientation: front/three-quarter, face and ponytail clear
- Clothing/environment: full costume including boots; ruined battlefield and
  soldiers visible

### Condition B — aspect-preserved medium framing

- File: `FACEMELT_SCALE_B_medium_768x512_20260811.png`
- SHA-256: `ac33d8d22023f731ea287e633afe264781ad36f47fa9aeb0b7afc8fb608ecef9`
- Original crop: x=400, y=100, width=768, height=512 (exactly 3:2)
- Resize: none; retained source pixels are already 768x512
- Face: 77.1x77.1 px / 1.510%
- Framing: medium, head through upper thighs, with flag and battlefield
- Orientation: same front/three-quarter source pose
- Clothing/environment: face, hair, torso costume, belt, flag and battlefield
  clear; boots are outside the crop

B supplies 1.92x the face width and 3.67x the face area of A. The intended
variable is source framing / face-information density, not isolated face pixels.

## Fixed generation state

Both generations used the exact persisted historical prompt without a rewrite.
Its UTF-8 length is 1,834 bytes and SHA-256 is
`a92b387f59242105ea76872bf2846fa37352b67bd00e15a8905f4d6d82d0c318`.
The verbatim text is in `ORIGINAL_FACE_MELT_FORENSIC.md` under “Exact generation
state.” It includes the original `wide shot`, `slow push-in` and `arc slightly
left to right` camera wording plus wind, ponytail, flag, soldier, ember, grip,
weight, chin and gaze actions.

- Seed: `462344237`
- Model: `notapalindrome/ltx23-mlx-av-q4`
- Text encoder: `mlx-community/gemma-3-12b-it-4bit`
- Backend: `mlx-video-with-audio` 0.1.36
- Resolution / requested frames / FPS: 768x512 / 121 / 24
- Image strength / conditioned frame: 1.0 / frame 0
- Requested steps: 30
- Effective distilled schedule: fixed stage 1 = 8, stage 2 = 3; `--steps`
  ignored by the installed unified classic sampler
- CFG request: 3; ignored by the distilled model because guidance is baked in
- Tiling / negative prompt / audio: Auto / empty / on
- Offline enforcement: `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`; existing
  model and encoder snapshots resolved locally

## Generation record

| Condition | Start / finish (JST) | Backend | Wall | Peak | Output |
|---|---|---:|---:|---:|---|
| A | 21:13:41 / 21:18:27 | 285.0 s | 285.9 s | 15.20 GB | `FACEMELT_SCALE_A_full_20260811_211111.mp4` |
| B | 21:18:27 / 21:23:10 | 282.3 s | 283.2 s | 15.20 GB | `FACEMELT_SCALE_B_medium_20260811_211111.mp4` |

A contains 117 readable video frames / 4.875 s. B contains 119 / 4.958333 s.
Both contain 5.010 s AAC audio. The different readable-frame count despite
identical requested temporal settings is another reason not to claim
byte-level same-seed determinism.

## Dense direct review

All readable frames were extracted. H, A and B were inspected every four frames
(0.1667 s) across the complete take. The 2.3–4.2 s region and early drift
windows were additionally inspected every two frames with magnified face crops.
Review was direct; no Vision score was treated as ground truth.

### Landmarks

| Condition | First identity drift | First geometric melt | Worst selected face | Recovery / stable state | Final state |
|---|---|---|---|---|---|
| H | f24 / 1.000 s | f64 / 2.667 s | f84 / 3.500 s | f96 / 4.000 s | plausible but different face |
| A | f24 / 1.000 s, mild | none observed | f64 / 2.667 s, identity departure only | no collapse; stable about f72 / 3.000 s | plausible, moderately drifted face |
| B | f28 / 1.167 s, mild pose/expression drift | none observed | f116 / 4.833 s, smallest face and blink/smile variation | no collapse; stable after turn about f72 / 3.000 s | plausible face at wide scale |

“Worst” for A and B does not mean melt. It is the least source-faithful selected
frame under dense review; anatomy remains plausible.

### Worst-frame rubric

Scores are 0–3, where 3 is strongest/cleanest. H uses frame 84; A frame 64; B
common-range frame 116.

| Metric | H | A | B |
|---|---:|---:|---:|
| Face identity | 0 | 2 | 2 |
| Face geometry | 0 | 3 | 3 |
| Hair continuity | 2 | 3 | 3 |
| Clothing continuity | 3 | 3 | 2 |
| Overall protagonist identity | 1 | 2 | 2 |
| Temporal stability | 0 | 2 | 3 |
| Camera / composition usefulness | 3 | 3 | 2 |
| Scene continuity | 3 | 3 | 3 |
| Artifact cleanliness | 1 | 3 | 3 |

H exhibits identity drift, geometric melt, hair-crossing reconstruction and
small-detail hallucination. A has smooth facial identity drift but no collapse,
double face, smear or material hair occlusion. B remains anatomically clean
through a head/gaze turn; no hair crossing or melt appears.

### Face-size progression

Apple Vision rectangles were used only as non-biometric observable geometry.

| Point | H | A | B |
|---|---:|---:|---:|
| Source/backend input | 38.0 px | 40.2 px | 77.1 px |
| frame 0 / 0.000 s | 38.2 px | 40.6 px | 76.9 px |
| frame 24 / 1.000 s | 42.0 px | 44.6 px | 64.2 px |
| frame 64 / 2.667 s | 45.5 px | 48.5 px | 45.2 px |
| selected worst | 49.2 px at 3.500 s | 48.5 px at 2.667 s | 37.3 px at 4.833 s |
| frame 96 / 4.000 s | 53.7 px | 52.8 px | 38.5 px |
| frame 116 / 4.833 s | 58.2 px | 57.6 px | 37.3 px |

H and A have closely matched trajectories: both start near 40 px and grow to
about 58 px. Only H collapses. Providing an already-correct aspect input with a
minimal 3:2 crop coincides with a material improvement at essentially the same
face scale.

B does not keep a larger face through the failure window. It starts at 77 px,
then the unchanged wide-shot prompt drives a strong pull-back: 46 px at 2.333 s,
40 px at H's worst time and 37 px near the end. It remains stable, but its
generated camera path is not a persistent medium framing.

## Pose, hair, camera and clothing

- H: as the push-in enlarges the face, the head inclines/downturns and hair
  crosses the cheek around 2.667–3.583 s; reconstruction fails.
- A: similar growth and frontal/slightly downward pose, but bangs and ponytail
  stay clear. Identity drifts smoothly without geometric failure.
- B: head/gaze turns left around the middle and returns; the face stays clean.
  Hair remains separated from facial geometry.
- B camera tradeoff: the video begins tight, then pulls out strongly to satisfy
  the prompt's wide establishing shot. This is opposite the requested slow
  push-in behavior.
- B wardrobe tradeoff: because the crop omits boots, the pull-out invents white
  socks and black ankle boots instead of the source's brown knee-high armor.
  A retains the full costume.

## Decision

This is matrix **CASE 2**. A materially beats H while B supplies little
additional benefit on the geometric-melt outcome: both score 3 for worst face
geometry and neither collapses. B gives smoother facial stability, but also
forces a different camera evolution and loses unseen wardrobe information.

The evidence does **not** justify “larger face crop fixes identity.” The stronger
observed lever is an already-correct, aspect-preserved backend input. This is a
causal indication, not proof: H is historical rather than a simultaneous exact
repeat, A removes small lateral margins to reach 3:2, and same-seed determinism
is not established.

Do not implement automatic Opening Identity Crop. A hidden conditioning crop is
not visually hidden from this backend: LTX starts tighter, then performs a large
compensating reframe and hallucinates omitted costume details. The user's
Opening Reference semantics would change even if its UI image stayed untouched.

The next gate was one **exact repeat of condition A**. That repeat completed and
was byte-for-byte identical to A1; dense review again found no melt. This closed
the repeatability gate and authorized the narrowly scoped production geometry
fix documented in `OPENING_REFERENCE_ASPECT_FIX_EVAL.md`. Frame/take rejection
logic remains frozen.

## Review files

All are under
`/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos`:

- `FACEMELT_SCALE_A_full_768x512_20260811.png`
- `FACEMELT_SCALE_B_medium_768x512_20260811.png`
- `FACEMELT_SCALE_source_compare_20260811_211111.png`
- `FACEMELT_SCALE_A_full_20260811_211111.mp4`
- `FACEMELT_SCALE_B_medium_20260811_211111.mp4`
- `FACEMELT_SCALE_{H,A,B}_dense_20260811_211111.png`
- `FACEMELT_SCALE_{H,A,B}_dense_full_20260811_211111.png`
- `FACEMELT_SCALE_HAB_matched_20260811_211111.png` (rows H/A/B; columns
  frames 0/24/64/84/96/116)
- `FACEMELT_SCALE_worst_compare_20260811_211111.png` (columns H/A/B; full and
  magnified face)

Generated PNG/MP4 evidence is not committed.

## Verification record and limitations

- `ffprobe`: A 117 readable frames, B 119; 768x512 H.264 and AAC in both
- Dense direct review: every four frames complete, every two in focused windows
- Apple Vision: face rectangles only; no biometric recognition
- `swift run LTXTests`: **1269 passed, 0 failed**
- `git diff --check`: **passed**
- Full Xcode build: optional and not planned because production/Swift source is
  unchanged
- GUI acceptance: not claimed; no UI change exists

Known limitation at the time of this calibration was that same-seed byte-level
and visual determinism had not been proven. The exact follow-up A repeat removed
that limitation for this saved condition by producing the same MP4 bytes. This
still does not establish global determinism across environments, nor does
aspect correction provide an identity guarantee.
