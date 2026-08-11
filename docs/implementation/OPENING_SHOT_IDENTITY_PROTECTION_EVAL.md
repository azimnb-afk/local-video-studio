# Opening Shot Identity Protection — Controlled Calibration

Date: 2026-08-11
Starting HEAD: `5ed0f64`
Classification: **REJECTED — production implementation gate not passed**

> Follow-up attribution: calibration A was later proven byte-for-byte identical
> to the user-observed failing raw take. Dense review found a severe transient
> at raw 3.500 s that the six percentage samples skipped. The static-camera gate
> remains rejected, but A's severity was understated. See
> `ORIGINAL_FACE_MELT_FORENSIC.md`.

## Question and gate

This calibration asked whether an Auto Movie Shot 1 that starts from a clear
Opening Reference keeps identity better when its requested camera is made
identity-safe. Production code was frozen until a same-source, same-seed A/B
showed a clear improvement. It did not, so no Shot-1 policy, persistence field,
UI, Queue, or Adaptive Identity Refresh change was made.

## Pipeline audit

`TakeGenerationCoordinator` resolves Shot 1 source precedence as explicit
per-shot image, refresh/inherited continuity, Opening Reference, then Character
Anchor. A valid Opening Reference therefore wins over Character Anchor and is
passed as the sole `GenerationRequest.sourceImagePath`. It receives image
strength `1.0`, the same exact-first-frame behavior as a user-selected Starting
Image. The compiled prompt independently carries image-synchronised appearance,
scene, camera, body action and audio instructions.

Opening Reference Vision Sync prevents contradictory clothing text before
planning. It does not constrain identity through time inside Shot 1. Adaptive
Identity Refresh runs between later Auto Movie shots after a completed frame is
available; it is not an intra-Shot-1 mechanism and was not changed.

## Real failure-equivalent source

The newest completed Auto Movie at calibration time was project
`20909BBB-6C0F-4311-A3E3-06ABA0B4ED5E`. It used one scene-like Opening Reference
with a full-body woman, visible face, dark ponytail, navy/white military uniform,
boots and a large navy flag in a ruined battlefield. Local Vision had already
recorded one subject and `faceVisible=true`.

The real production Shot 1 requested a wide, eye-level, slow push-in plus a
left-to-right arc. Simultaneously it requested moving hair, uniform tails, flag,
background soldiers and embers, plus grip, weight, chin and gaze changes. The
completed take became control A without regeneration.

## Controlled A/B

Everything below was identical:

- Opening Reference and compiled appearance/scene/action/audio text
- seed `462344237`
- `notapalindrome/ltx23-mlx-av-q4`
- `mlx-community/gemma-3-12b-it-4bit`
- 768x512, 121 requested frames, 24 fps, audio on
- 30 requested inference steps, image strength 1.0, tiling Auto

Only camera wording changed.

**A — current production**

> The camera wide shot, eye-level angle, slow push-in camera. ... The camera
> begins a very slow push-in while arcing slightly left to right.

**B — protected calibration**

> The camera wide shot, eye-level angle, static camera. ... The camera remains
> locked-off and static with no push-in, arc, zoom, or reframing.

All subject, wind, cloth, flag, background and narrative actions remained
unchanged, isolating the proposed camera protection rather than replacing the
shot with a different beat.

B completed in 278.3 seconds with 15.33 GB reported peak memory. Cache resolution
completed immediately (14/14 and 12/12); no new model was downloaded. Process
inspection found one real `mlx_video.generate_av` child and no overlap.

Both muxed videos contain 117 readable video frames (4.875 s) despite the
121-frame request. Required drift samples therefore use actual indices
0/23/46/70/93/116 for approximately 0/20/40/60/80/99%.

## Visual result

Conservative direct review against the immutable Opening Reference:

| Position | A face / identity | B face / identity | Observation |
|---|---:|---:|---|
| 0% | 3 / 3 | 3 / 3 | Both start from the correct reference. |
| 20% | 2 / 2 | 1 / 1 | B develops the clearest facial morph and changed hair shape. |
| 40% | 2 / 2 | 2 / 2 | Both are usable but no B advantage. |
| 60% | 2 / 2 | 2 / 2 | Expression/face varies; clothing remains stable. |
| 80% | 2 / 2 | 2 / 2 | No material protected advantage. |
| 99% | 2 / 2 | 2 / 2 | Both finish scene-coherent; neither restores source-level facial detail. |

Hair and clothing remain stronger than face in both. A conservatively scores
Face 2, Hair 3, Clothing 3, Overall Identity 2, Scene 3, Camera 3, Narrative 3.
B scores Face 1, Hair 1 at its worst transient, Clothing 3, Overall Identity 1,
Scene 3, Camera 3, Narrative 2.

As a secondary check, the installed `agents-a1:32k` local Vision model received
the Opening Reference and required time samples. It reported no clear A drift
and flagged B's 20% frame as `faceConsistency=1`, `hairConsistency=1`,
`overallIdentity=1`, with clear facial morphing. This is consistent with direct
frame inspection. No image left the Mac.

The static text also did not create a truly locked composition: subject and flag
reframing remained visible. Prompt wording alone is therefore not reliable
camera control for this backend.

## Gate conclusion

**B is not better than A.** It is transiently worse. The tested hypothesis does
not justify a production risk detector or automatic Shot-1 prompt rewrite.

This result does not prove that camera motion can never contribute to identity
loss. It proves the proposed minimum intervention — replacing push-in/arc text
with static/no-reframe text while holding everything else fixed — neither
reliably suppresses camera evolution nor improves identity on this real case.
The reference also has a visible, medium-scale face rather than the extreme
tiny-face condition in the original hypothesis, and A did not reproduce a
catastrophic melt at the six required samples. More general production logic
would therefore be overfitted and unsupported.

No production Auto Movie E2E was run after B because the gate explicitly
forbids implementation and expensive downstream validation when B does not
improve the opening shot. No GUI check was required because source and UI were
unchanged.

## Review files

All are under
`~/Library/Application Support/LTXVideoGenerator/Videos` and were copied with
non-overwriting semantics:

- `OPENSHOTID_A_current_shot01_20260811_201500.mp4`
- `OPENSHOTID_B_protected_shot01_20260811_201500.mp4`
- `OPENSHOTID_A_drift_{000,020,040,060,080,099}pct_20260811_201500.png`
- `OPENSHOTID_B_drift_{000,020,040,060,080,099}pct_20260811_201500.png`
- `OPENSHOTID_A_drift_contact_20260811_201500.png`
- `OPENSHOTID_B_drift_contact_20260811_201500.png`

No review artifact was added to `history.json` or the repository.

## Recommended next evidence

Do not implement the current policy. If calibration resumes, use the exact
user-identified catastrophic frame/video or a verified truly tiny-face Opening
Reference, then change one controllable factor at a time. A backend-level camera
control that actually changes measured motion would be stronger evidence than
another natural-language `static` synonym.
