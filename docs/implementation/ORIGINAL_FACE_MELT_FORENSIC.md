# Original Face-Melt Forensic

Date: 2026-08-11

Starting HEAD: `7533de4`

Classification: **PASS — TRANSIENT RAW FAILURE IDENTIFIED**

> Follow-up calibration: two new sources used the same aspect-preserving 3:2
> preprocessing. Full-framing A retained a historical-sized face but eliminated
> the transient; tighter B also remained clean but forced a pull-back and
> invented omitted boot details. Current classification is that aspect-preserved
> input is the stronger observed lever, not that a hidden face crop is ready for
> production. A subsequent exact A repeat was byte-identical and remained clean.
> The common production I2V boundary now prepares arbitrary-aspect inputs with
> centered scale-to-fill/crop, and a real Auto Movie using this untouched
> 1672x941 source avoided the f64/f84 geometric melt. Mild identity drift remains;
> no face-aware crop or identity guarantee was added. See
> `FACE_SCALE_ISOLATION_EVAL.md` and
> `OPENING_REFERENCE_ASPECT_FIX_EVAL.md`.

## Executive finding

The user-observed melt in
`20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E_final.mp4` is already present in the
exact selected Shot 1 raw take. It is not an assembly transition, blend,
scaling or re-encode artifact. The strongest geometric deformation is raw
frame 84 at 3.500 s, mapped to Final frame 84 at 3.520996 s. This is 1.510 s
before the next shot's first video frame, so it is not a boundary event.

The previous calibration's condition A did not fail to reproduce the problem.
It was a non-regenerated copy of this exact raw MP4: both files have SHA-256
`4f17d646ef7cf30e32f45ca32ca2a694fc78b04041d63a3a52f061feb2b31f78`.
The six 0/20/40/60/80/99% full-frame samples skipped the worst interval between
the 60% and 80% samples, while the face occupied only about 45–53 pixels in
that region. The earlier severity conclusion was therefore a sampling and
review-scale miss, not a different generation condition.

No new LTX generation and no production source change were made.

## Evidence chain

### Final movie

- Path: `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E_final.mp4`
- SHA-256: `4a52313688df14cc5444afa7aab5f343d4627d2e44eed276688aaba059aec64a`
- Size / mtime: 4,102,936 bytes / 2026-08-11 20:02:30 +0900
- Video: H.264 High, yuv420p, 768x512, nominal 24 fps, 471 frames
- Audio: AAC-LC stereo, 48 kHz
- Container duration: 20.061333 s

### Exact shot and selected take

Project `20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E` records this assembly signature:

```text
77CD09EB-C513-4FDB-89C8-C07FC36CF7E5:/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/1D7BAF27-063B-401A-9B2D-3E0C106943CF.mp4
|EE453369-989B-4AFA-AB94-C83E5442B22C:/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/CDC73087-9777-4D48-B8B3-7B83C00F2B27.mp4
|165B24EC-0513-4AB9-B641-CCA165453D1E:/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/5B2C764D-2AC3-4E23-9400-A9F96CAD6123.mp4
|8A860D12-62B5-406F-9FBC-3DABE53A5364:/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/6E7A2002-2FEF-4628-B3D4-CD8C3D04B570.mp4
```

The affected item is Shot index 0, `Opening`, selected Take
`77CD09EB-C513-4FDB-89C8-C07FC36CF7E5`.

- Raw path: `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos/1D7BAF27-063B-401A-9B2D-3E0C106943CF.mp4`
- SHA-256: `4f17d646ef7cf30e32f45ca32ca2a694fc78b04041d63a3a52f061feb2b31f78`
- Size / mtime: 1,175,377 bytes / 2026-08-11 19:47:56 +0900
- Video: H.264 High, yuv420p, 768x512, 24 fps, 117 readable frames, 4.875 s
- Audio/container: AAC-LC stereo, 48 kHz, 5.010 s

The Final's first 117 decoded video-frame MD5 values exactly equal all 117 raw
decoded frame MD5 values. Final frame 0 starts at 0.020996 s and raw frame 0 at
0.000000 s; corresponding frame content is otherwise exact. The next shot's
first Final video frame is at 5.031006 s. `FinalAssemblyService` selected the
compatible-media stream-copy path: concat demuxer followed by `-c copy`, with
hard cuts and no xfade, overlap, filter, scale or video re-encode.

## Dense temporal map

Frames were reviewed every five frames across Shot 1, then every two frames in
the early and failure windows. Direct original-size review fixed the key frames.

| Raw time / frame | Final time / frame | Observation |
|---|---|---|
| 0.000 s / 0 | 0.020996 s / 0 | Opening composition is recognizable; I2V/VAE detail already differs slightly from the PNG. |
| 0.833333 s / 20 | 0.854329 s / 20 | Last selected frame before persistent observable identity drift. Face remains plausible. |
| 1.000000 s / 24 | 1.020996 s / 24 | First selected persistent identity drift: features narrow/change, but anatomy remains plausible. |
| 2.333333 s / 56 | 2.354329 s / 56 | Push-in has enlarged the face; identity has drifted, without the strongest geometric collapse yet. |
| 2.666667 s / 64 | 2.687663 s / 64 | Geometric melt begins: head inclines, hair crosses the face and mouth/eye geometry starts deforming. |
| 3.500000 s / 84 | 3.520996 s / 84 | Worst observed frame: strongest eye/cheek/mouth deformation and identity loss. |
| 3.583333 s / 86 | 3.604329 s / 86 | Immediately after worst; severe deformation remains but begins changing away from the peak. |
| 3.750000 s / 90 | 3.770996 s / 90 | Recovery begins toward a plausible facial structure. |
| 4.000000 s / 96 | 4.020996 s / 96 | Anatomically stable again, but as a visibly changed face rather than restored source identity. |
| 4.833333 s / 116 | 4.854329 s / 116 | Shot finishes with the same scene/costume and a larger, drifted face. |

The collapse is progressive over roughly the second half of the take, with a
short severe peak; it is not a single compression flash. Failure-shape labels:

- identity drift;
- geometric melt of eyes, cheeks and mouth;
- hair occlusion/reconstruction while the head inclines;
- small-face detail hallucination during enlargement.

There is no evidence of a temporal double exposure or assembly blend. The
navy/white costume, belt, boots and flag remain substantially coherent. The
ponytail remains recognizable, although hair crosses the face and its shape
evolves around the collapse.

## Exact source and backend preprocessing

Opening Reference:

`/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E/Assets/OpeningReference/opening-reference-2575EA16-CEC2-4C28-9588-0D02B34B74CA.png`

- Original filename: `ChatGPT Image 2026年8月11日 19_42_14.png`
- SHA-256: `ba2d31efcf3683e4b7ae1f0eb68c42c8d5bd336658364f87e7e158922518679a`
- Size / mtime: 2,307,882 bytes / 2026-08-11 19:42:15 +0900
- Dimensions: 1672x941, no orientation metadata
- Subject: one full-body woman, slightly turned toward camera, visible small face,
  dark ponytail, navy/white costume, belt, boots and large flag

The installed `mlx-video-with-audio` `0.1.36` path calls `load_image` twice:
384x256 for stage 1 and 768x512 for stage 2. When both dimensions are supplied,
`PIL.Image.resize((width, height), LANCZOS)` is used. There is no aspect-preserving
crop or pad. The 1.7768:1 source is hard-stretched to 1.5:1. At full resolution,
x scale is approximately 0.4593 and y scale 0.5441, making the result about
15.6% narrower relative to its height. `FACEMELT_BACKEND_INPUT_768x512.png` is a
deterministic reconstruction from the retained original and this installed code.

A non-biometric Apple Vision rectangle measurement made during this forensic
pass found an approximately 38x38-pixel face in the 768x512 backend input
(about 0.37% of frame area). Approximate detected progression in the raw take:

| Raw time | Approx. face box | Frame-area share |
|---:|---:|---:|
| 0.000 s | 38x38 px | 0.37% |
| 1.000 s | 42x42 px | 0.45% |
| 2.333 s | 45x45 px | 0.51% |
| 2.667 s | 46x46 px | 0.53% |
| 3.500 s | 49x49 px | 0.62% |
| 3.583 s | 51x51 px | 0.67% |
| 4.000 s | 54x54 px | 0.73% |
| 4.833 s | 58x58 px | 0.86% |

The push-in increases linear face size by roughly 53% and box area by roughly
2.3x. The melt coincides with face enlargement, a downward/inclining head
change and hair crossing the face. This is correlation, not proof that camera
motion or scale alone caused the failure. Lighting and costume remain much more
stable than facial identity.

## Exact generation state

- Generation completed: 2026-08-11 19:47:57 +0900
- Generation duration: 273.8199 s
- Model: `notapalindrome/ltx23-mlx-av-q4` (`ltx23_distilled_q4`, q4)
- Text encoder: `mlx-community/gemma-3-12b-it-4bit`
- Seed: `462344237`
- Profile: `H0` / High / `highQuality`
- Resolution: 768x512
- Requested/readable frames: 121 / 117
- FPS: 24
- Image strength: 1.0
- Image frame index: CLI default 0 (first frame)
- Requested steps in Take snapshot/CLI: 30
- Effective distilled sampler: fixed 8 stage-1 + 3 stage-2 denoise steps;
  the installed unified classic path explicitly ignores `--steps`
- CFG requested: 3
- Tiling: Auto
- Audio: enabled; AAC stereo 48 kHz in the output
- Negative prompt snapshot: empty

The complete persisted prompt is:

```text
CHARACTER 1: Unknown. Face: delicate features with soft expressions. Hair: dark black with a ponytail. Eyes: likely dark-colored (inferred from overall color scheme). Age impression: young adult. Build: slender but fit. Complexion: pale, possibly indicating a character designed for visual appeal rather than realism. Distinctive features: ponytail hairstyle. Current costume: Dark blue and white military outfit with gold accents, white pleated skirt, high-heeled boots, bronze shoulder armor, leather belts, flag emblem on back. Accessories: spear, shield. Continuity: Ensure consistent lighting across all poses. Maintain uniform color palette for clothing and accessories. Keep facial expressions coherent with character personality. Consistent style in armor details and flag design.. Location: Ruined battlefield center, time: Dusk, weather: Stormy, windy, lighting: Cool blue-gray ambient light with warm orange firelight reflections on armor; shafts of light from behind. The camera wide shot, eye-level angle, slow push-in camera. A wide shot establishes the ruined battlefield with smoke and distant fires. The knight commander stands center frame holding her flag. The camera begins a very slow push-in while arcing slightly left to right. Wind blows through the scene, causing her ponytail, uniform tails, and the heavy navy flag to billow realistically. Distant armored soldiers move slowly in the background. Glowing embers drift past the camera lens. She subtly tightens her grip on the flagpole, shifts her weight, raises her chin, and looks calmly at the camera. Lighting: Cool blue-gray ambient light with warm orange firelight reflections on armor; shafts of light from behind. Audio: Deep battlefield ambience, Distant fires crackling, Wind blowing across ruins, Heavy fabric flapping, Faint metallic armor sounds.
```

The Director action is the second half beginning with “A wide shot establishes…”:
slow push-in plus left-to-right arc; wind-driven ponytail, uniform and flag;
background soldier and ember motion; grip, weight, chin and gaze changes. This
is a high-motion prompt despite the main subject being asked to remain calm.

## Why calibration A understated the failure

Calibration A was created without generation and is byte-for-byte identical to
the failing raw take. Therefore source bytes, preprocessing, prompt, seed,
camera/action, model, encoder, strength, frame count, resolution, audio,
readable frames and backend output are all identical by definition. There are
no generation-variable differences to explain.

The actual differences were in observation:

1. A used frames 0/23/46/70/93/116. The worst was frame 84, between the 60%
   frame 70 and 80% frame 93.
2. By frame 93 the strongest geometric collapse had begun recovering.
3. At full-frame review, the relevant face occupied only about 45–53 pixels.
   The magnified dense face sheet exposes deformation that is easy to miss in a
   six-image all-scene contact sheet.
4. The local Vision request itself used the documented reference-plus-six-frame
   order and schema; no parser/envelope mismatch was found. Its score cannot
   compensate for missing temporal evidence and is not ground truth.

The prior finding that static camera wording did not beat A remains valid. The
statement that A did not contain a catastrophic transient does not.

## Determinism and next gate

The backend seeds MLX with `mx.random.seed(seed)`, but no historical exact rerun
of this condition proves byte-for-byte reproducibility across Metal execution,
library state and muxing. Calibration A was a copy, not a rerun; calibration B
changed the prompt. Exact-rerun determinism is therefore **unknown**. No rerun
was needed to attribute the existing failure and none was run.

Do not implement another prompt/camera heuristic from this evidence. The next
single controlled experiment should isolate **source face scale while retaining
scene compatibility**:

- A: this immutable original full-body source and exact failing generation state;
- B: a project-owned, aspect-preserving medium crop from the same source that
  keeps the battlefield/costume but provides a materially larger face;
- hold prompt, seed, model, encoder, dimensions, strength and audio constant;
- evaluate every 4–5 frames with magnified face crops, not six percentages.

Separately, the proven transient means future product work should investigate
frame-level face-quality detection or take rejection. Neither is justified for
production until its false-positive behavior is measured on real outputs.

## Review files

All files are under
`/Users/azimnb/Library/Application Support/LTXVideoGenerator/Videos` and were
copied without overwriting existing files:

- `FACEMELT_FINAL_dense.png`
- `FACEMELT_RAW_dense.png`
- `FACEMELT_FINAL_face_dense.png`
- `FACEMELT_RAW_face_dense.png`
- `FACEMELT_RAW_worst_window.png`
- `FACEMELT_FINAL_vs_RAW_matched.png` (top Final, bottom Raw; before/first/worst/after/stable)
- `FACEMELT_SOURCE_vs_RAW.png` (source, backend reconstruction and key Raw frames)
- `FACEMELT_BACKEND_INPUT_768x512.png`
- `FACEMELT_FINAL_{before_0.854s,first_1.021s,melt_onset_2.688s,worst_3.521s,after_3.604s,stable_4.021s}.png`
- `FACEMELT_RAW_{before_0.833s,first_1.000s,melt_onset_2.667s,worst_3.500s,after_3.583s,stable_4.000s}.png`

Generated media remains outside Git.

## Verification record

- Repository inspection: `git status`, `git branch --show-current`,
  `git log --oneline`, `git diff`, `git diff --cached`
- Project/media attribution: `jq`, `stat`, `shasum -a 256`, `ffprobe`
- Dense evidence: FFmpeg full-frame/face crops every five frames, focused crops
  every two frames and direct original-size inspection
- Final/raw decoded equality: FFmpeg `framemd5`, 117 versus 117 hashes, no diff
- Source preprocessing: installed `mlx_video` source audit plus deterministic
  PIL/Lanczos reconstruction
- Face scale: Apple Vision face rectangles used only for observable geometry,
  not identity recognition
- `swift run LTXTests`: **1269 passed, 0 failed**
- Full app rebuild: not run; production source is unchanged and this is a
  docs/evidence-only forensic pass
- `git diff --check`: required before checkpoint

Known limitation: no exact original rerun was made, so same-seed byte-level
determinism and the causal contribution of hard stretch, face scale, head pose
and hair occlusion remain unresolved. Attribution of the defect to the retained
raw take is conclusive.
