# LTX Continuity v1 — Acceptance

**Date:** 2026-08-12
**Classification: PASS — LTX CONTINUITY V1 PRODUCTION ACCEPTED**

Consolidation, not redesign. The system already worked; this names it, pins it
with regression tests, and accepts it against a real movie.

## 1. Actual architecture

```
Shot N selected Take
  → ContinuityFrameExtractor.extractLastFrame
  → Assets/Continuity/shot-NNN-from-<takeID>.png   (cached by source take)
  → Shot.continuityImageRelativePath + continuitySourceTakeID
  → TakeGenerationCoordinator.planTakes  → sourceImagePath
  → ImageConditioningPreparer            → aspect-correct canvas
  → GenerationRequest → LTX
```

Identity Refresh inserts between extraction and planning: it assesses the
inherited frame and, only when a close framing needs detail the frame lacks,
substitutes a scene-compatible anchor.

## 2. Source precedence (verbatim from `TakeGenerationCoordinator:86–130`)

1. explicit per-shot starting image — the user's choice, always wins
2. Identity Refresh anchor
3. inherited last frame
4. Opening Reference — **shot 1 only**
5. Character Anchor — **shot 1 only**
6. text-to-video

A missing *required* asset throws rather than silently falling back to T2V.

## 3. Strategy and strengths (unchanged)

| Source | Strength |
| --- | --- |
| explicit / opening reference | 1.0 |
| character anchor | `CharacterAnchorPolicy.openingImageStrength` |
| inherited frame / refresh anchor | 0.8 standard, 0.5 reframe |

## 4. Requested → Effective → Actual

`Models/LTXContinuity.swift` adds `LTXContinuitySource`,
`LTXContinuityStrategy`, `LTXContinuityResolution` and `LTXContinuityResolver`.

Deliberately a **pure classifier**: it mirrors the coordinator's precedence so
the order is stated once in a testable place, and adds no persisted field, so
there is no migration risk. Example provenance:

```
Requested Auto · Effective Last Frame · Source Previous shot's last frame ·
Actual Assets/Continuity/shot-002-from-abc.png
```

## 5. Real E2E — `LTXCONT V1`

Standard 768×512, 121 frames/shot, LTX-2.3 Distilled Q4, Director Auto, opening
reference attached. 4 shots, assembled, 18.06 s. 00:47 → 01:06.

| Shot | Mode | Scale | Source used | Strength |
| --- | --- | --- | --- | --- |
| 1 | cut | wide | Opening Reference | 1.0 |
| 2 | continue | medium-wide | inherited `shot-002-from-0F7FB6D4…` | 0.8 |
| 3 | continue | medium-close-up | inherited `shot-003-from-F9281B4C…` | 0.8 |
| 4 | **cut** | medium-wide | **none — text-to-video** | 1.0 |

Shot 4 is the important row. A **mid-movie cut inherited nothing**: no
continuity frame, no refresh anchor, no source image. Nothing leaked across the
cut, which is the §24 requirement, observed in production rather than only
asserted.

Queue serialised throughout; no stale LTX process before or after.

## 6. Tests

Five suites, 32 checks: precedence order, mid-movie cut inherits nothing,
requested/effective/actual provenance, retake invalidating both the inherited
frame and the dependent refresh anchor, and the aspect-preparation boundary
(exact-size source is a no-op; a 1672×941 source crops to the target aspect
without stretching).

`swift run LTXTests`: **1388 passed, 0 failed**.
`xcodebuild` Debug: BUILD SUCCEEDED.

## 7. Stated limitations

- **Last-frame I2V is not motion continuation.** A single still carries pose and
  appearance, not velocity or direction. Joins can restart motion.
- **Identity is not guaranteed.** It survives as far as the inherited frame
  carries it (D-076); Identity Refresh repairs the specific case where a close
  framing follows a frame with no usable face.
- Opening Reference and Character Anchor apply to shot 1 only, by design.
