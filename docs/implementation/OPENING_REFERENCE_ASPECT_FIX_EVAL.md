# Opening Reference Aspect Fix Production Evaluation

Date: 2026-08-11

Starting HEAD: `dbcdbf0`

Classification: **PASS — OPENING REFERENCE ASPECT FIX PRODUCTION ACCEPTED**

## Evidence gate: exact Condition A repeat

Production was not changed until the prior aspect-preserved full-framing
Condition A had been repeated exactly once. The saved 768x512 input was reused;
no new crop or prompt was created.

- A1/A2 input:
  `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/FACEMELT_SCALE_A_full_768x512_20260811.png`
- Input SHA-256:
  `5c165656a4891be10bf9a78b9d150d66d3263261c52de1328e2a70bfc6d7eac8`
- Prompt SHA-256:
  `a92b387f59242105ea76872bf2846fa37352b67bd00e15a8905f4d6d82d0c318`
  (1,834 UTF-8 bytes)
- Fixed state: seed `462344237`, Q4 model, 4-bit Gemma encoder,
  768x512, 121 requested frames, 24 fps, requested 30 steps, image strength
  1.0 at frame 0, audio on and the same offline backend/environment
- A1: 21:13:41–21:18:27 JST, backend 285.0 s, wall 285.9 s,
  peak 15.20 GB, 117 readable frames
- A2: 21:47:21–21:52:00 JST, backend 278.3 s, wall 278.784 s,
  peak 15.20 GB, 117 readable frames
- A1/A2 output SHA-256:
  `c032f0c71b353863a1eae4de1af06ad346ec4ab0ad60660fe77ff871d5a3bd96`

A2 is not merely visually similar: the MP4 bytes and every decoded frame equal
A1 exactly. Dense direct inspection every four frames, including 0.8–2.3 s and
2.3–4.2 s, found the same mild identity departure and no geometric face melt.
The least source-faithful selected A2 frame is frame 64 / 2.667 s, but its
anatomy is clean. Historical H begins geometric failure at frame 64 / 2.667 s
and peaks at frame 84 / 3.500 s. A2 is materially closer to A1 than H.

**Repeat classification: REPEAT PASS.** This satisfied the mandatory gate for
production work.

## Root cause and insertion point

The installed `mlx-video-with-audio` 0.1.36 utility loaded RGB pixels and called
`PIL.Image.resize((width, height), LANCZOS)` whenever both dimensions were
provided. Arbitrary-aspect I2V inputs were therefore stretched separately in x
and y at both backend stages. The historical 1672x941 source became 768x512,
about 15.6% narrower relative to its height.

All official Generate, One Shot, Storyboard, Auto Movie/Hybrid, Opening
Reference, Character Anchor, inherited continuity and Adaptive Identity Refresh
sources ultimately cross `LTXBridge`. The smallest common correctness boundary
is therefore immediately before the bridge escapes the final backend image
path, after GenerationService has applied the final effective quality profile.
Source selection remains upstream and unchanged.

## Production implementation

`ImageConditioningPreparer` is a backend-facing, CPU-only image geometry
boundary:

- target size is the effective request width/height floored to the same 64-pixel
  units passed to MLX; no preset or 768x512 value is hard-coded;
- an exact-size source is reused byte-for-byte, so generated continuity frames
  and refresh anchors at the target canvas are composition no-ops;
- every other source uses deterministic aspect-preserving scale-to-fill followed
  by a centered integral crop and uniform resize;
- there is no stretch, letterbox, black/white padding, face-aware crop,
  subject-aware crop, Vision-guided crop or upscale policy;
- the canonical user/project asset remains untouched and remains the path used
  by Vision, prompt enhancement, project metadata and the persisted Take;
- only the path passed to `mlx_video.generate_av` resolves to a derived PNG;
- derived files are cached under
  `~/Library/Application Support/LTXVideoGenerator/ConditioningCache` using
  standardized source-path hash, content hash and target dimensions;
- a source-content or resolution change drops the old variant; Opening Reference
  Replace/Clear explicitly invalidates its cached variant.

For 1672x941 -> 768x512, the retained source rectangle is exactly
`x=131, y=0, width=1410, height=940`. This is the same content geometry as
experimental Condition A. Crop width/height and target width/height cross
multiply exactly, all four output corners contain source pixels, and the final
image is exactly 768x512. The app's CoreGraphics high-quality resampler produces
a different PNG hash from the calibration's Pillow Lanczos file, but the mean
absolute difference is only 1.49/1.28/1.12 RGB levels and the content window is
identical. The production prepared SHA-256 is
`27ff19a88c1c776e6f0fa40e09e20dab122676e39baa2a8a985fcc33ee3f0d70`.

The Production Queue is unchanged: preparation is part of one generation job,
does not spawn MLX and does not affect ordering or concurrency. Explicit
per-shot source > accepted refresh/continuity/opening rules > Character Anchor
> T2V precedence is unchanged. Adaptive Identity Refresh policy, assessment,
resolver, provenance, reuse and generated fallback code were not modified.

## Real Auto Movie production E2E

Project `A0058572-38A4-47C5-8E2F-79A0CBE92F86`, titled
`ASPECTFIX Production E2E`, was created through the canonical Debug app.
Local AI Director `qwen3.6-claw-fast:latest` planned four shots. The original was
selected through the native file picker without a manual crop.

- Canonical managed Opening Reference:
  `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/A0058572-38A4-47C5-8E2F-79A0CBE92F86/Assets/OpeningReference/opening-reference-B3E153FC-FE59-4401-9F9D-C011242B25E0.png`
- Canonical size/hash: 1672x941,
  `ba2d31efcf3683e4b7ae1f0eb68c42c8d5bd336658364f87e7e158922518679a`
- Prepared backend path:
  `/Users/azimnb/Library/Application Support/LTXVideoGenerator/ConditioningCache/4872a6d1c923c6a247569ff3cb472a4c4b6997b542a4d418d33eb8698e96bc3c-ba2d31efcf3683e4b7ae1f0eb68c42c8d5bd336658364f87e7e158922518679a-768x512.png`
- Prepared size/hash: 768x512,
  `27ff19a88c1c776e6f0fa40e09e20dab122676e39baa2a8a985fcc33ee3f0d70`
- Mode/crop: aspect-preserving fill/crop, `(131, 0, 1410, 940)`
- Cold preparation completed inside the same one-second timestamp as backend
  startup; later uses were cache hits. This is below timestamp resolution and
  negligible beside Shot 1's 290.748 s generation. No finer production timing
  is claimed because stdout timing was not retained by the GUI launch.

Opening Reference Vision analysis continued to use the canonical image and
recognized one visible subject, black ponytail, white/navy/gold costume, armor,
belt and brown boots. The GUI continued to show the original thumbnail and
`ASPECTFIX_original_1672x941.png`; it never displayed the internal crop as the
user asset.

Shot 1 settings were Standard / Q4 / Gemma 4-bit, 768x512, 121 requested frames,
24 fps, effective 25 steps, strength 1.0, audio on and seed `1473285226`. Its
compiled prompt retained a wide eye-level slow push-in, ruined battlefield,
wind-driven ponytail/uniform/flag, embers, grip and chin/gaze actions. The Take
persisted the canonical source path while `/tmp/ltx_generation.log` named the
prepared cache path as the actual backend input.

Shot 1 completed in 290.748 s and contains 117 readable H.264 frames / 4.875 s
plus 5.010 s AAC. All four shots completed sequentially and assembled into a
20.061333 s 768x512 H.264/AAC movie with 468 readable video frames. The GUI
reported `Completed movie ready` and 4/4 selected takes.

## Dense production visual result

Every fourth Shot 1 frame was inspected directly at magnified face scale across
the entire 4.875 s take. The required 0.8–2.3 s and 2.3–4.2 s windows are fully
covered. This is a human visual review; no automated face score is treated as
ground truth.

| Observation | Historical H | Production P |
|---|---|---|
| First identity drift | f24 / 1.000 s | mild, about f20–24 / 0.833–1.000 s |
| Geometric melt start | f64 / 2.667 s | none observed |
| Worst selected | f84 / 3.500 s, severe eyes/cheek/mouth collapse | f64 / 2.667 s, smooth identity departure only |
| Final identity | plausible but visibly changed after recovery | plausible, drifted but anatomically stable |
| Hair | crosses/reconstructs through failure | ponytail/bangs remain coherent |
| Clothing | mostly coherent | navy/white/gold costume, belt and boots remain coherent |
| Composition | useful push-in but with failure | useful wide-to-medium slow push-in; no B-style pull-back |

Production P is not a same-face guarantee. Facial details evolve toward a
different, smoother expression and identity. It does, however, avoid the severe
geometric failure, remain materially more stable than H at the worst interval,
retain the requested scene/action, and introduce no major composition or
wardrobe regression. This meets the stated production threshold.

## Verification

- `git diff --check`: PASS
- `swift build`: PASS
- `swift run LTXTests`: **1316 passed, 0 failed**
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO clean build`: **BUILD SUCCEEDED**
- Canonical executable:
  `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app/Contents/MacOS/LTXVideoGenerator`
- GUI render/assembly acceptance used PID 99253 from that exact canonical path;
  its executable mtime was 2026-08-11 22:06:39 +0900
- The final clean build updated the executable mtime to 2026-08-11 22:53:55
  +0900. The prior process was quit through the GUI and the full path was
  relaunched as PID 2052. After restart the project still showed 4/4 selected
  takes, `Completed movie ready`, the original filename/preview and locally
  analysed appearance.
- Other-mode coverage: Generate, One Shot, Storyboard and Auto Movie/Hybrid
  requests exercise the same preparer in tests; no extra expensive movies ran

## Review assets

All review files are under
`/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos` and are not
committed:

- `FACEMELT_ASPECT_A_REPEAT_20260811_214721.mp4`
- `FACEMELT_ASPECT_repeat_dense_20260811_214721.png`
- `FACEMELT_ASPECT_H_vs_A1_vs_A2_vs_B_20260811_214721.png`
- `ASPECTFIX_input_original_20260811_222120.png`
- `ASPECTFIX_input_prepared_20260811_222120.png`
- `ASPECTFIX_shot01_20260811_222626.mp4`
- `ASPECTFIX_dense_20260811_224327.png`
- `ASPECTFIX_H_vs_PROD_20260811_224327.png`
- `ASPECTFIX_final_20260811_224327.mp4`

## Limits and next work

This is a geometry-correctness fix, not identity conditioning, face-aware
cropping, face recognition, frame rejection or an identity guarantee. Mild
identity drift remains. The next evidence-driven work should evaluate temporal
identity conditioning or frame/take quality detection with false-positive
measurement. Do not add a hidden tight face crop: Condition B already showed
the pull-back and out-of-crop wardrobe hallucination cost.
