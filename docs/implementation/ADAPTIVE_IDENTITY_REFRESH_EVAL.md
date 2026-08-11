# Adaptive Identity Refresh — Evaluation

**Date:** 2026-08-11
**Original MVP baseline HEAD:** `87e7a9a`, worktree clean

**Reuse/acceptance starting HEAD:** `549e93b`, worktree clean

**Classification: PASS — ADAPTIVE IDENTITY REFRESH PRODUCTION ACCEPTED**

## 1. Question

When the next shot needs identity detail the inherited frame does not contain,
can supplying a better visual source repair the transition — and can that source
be produced automatically?

Two facts had to be proven before any production code (§74).

## 2. Gate #1 — does a better source fix the transition? **PASS**

Reproduced the exact failing transition from `VB NEW` shot 3. Everything held
identical (seed 551658229, 768×512, 121 frames, 25 steps, same prompt, same
model and encoder, strength 0.8); only the source image differed.

| | Face | Hair | Clothing | Identity | Environment | Framing | Camera | Beat | Artifacts |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **A** inherited back-view frame | 0 | 1 | 1 | 1 | 3 | 3 | 3 | 2 | 3 |
| **B** manual anchor (opening still) | **3** | **3** | **3** | **3** | 3 | 3 | 3 | **3** | 3 |

A produced a different woman in a blue-grey dress. B kept the Adventurer Heroine
— navy vest, gold emblem, blue bow, cream cape — and executed the same beat.

**FACT 1 proven.** The transition is repairable by source, not by prompt.

## 3. Gate #2 — can LTX produce that source automatically? **PASS**

Refresh bridge: opening-reference anchor + a *transformation* prompt asking the
subject to turn toward camera and the camera to settle into the target framing.
**49 frames** (valid 8n+1) — **122.0 s**, peak 14.70 GB, against 270 s for a full
shot. Candidates sampled at 20/30/40/50/65/80/99 %; the transformation completed
early, so late frames are not automatically best.

**Selected 80 %**: face clear, medium-close-up framing matching the target, full
costume, same courtyard. Scored 3 on every criterion in §27.

Target shot re-run from that generated anchor (condition **C**): Face 3, Hair 3,
Clothing 3, Identity 3, Framing 3, Scene 3 — all ≥ 2, and far closer to B than
to A. **Gate #2 PASS.**

One honest difference: B also nailed the *beat* (looked back toward camera) while
C turned further away, and B cost **zero** extra generation. Where the strongest
anchor is already scene-compatible, using it directly beats regenerating it.

**FACT 2 proven.**

## 4. MVP

| File | Role |
| --- | --- |
| `Models/IdentitySourceAssessment.swift` | visibility schema, `IdentityDetailRequirement`, `IdentityRefreshThresholds` |
| `Services/IdentitySourceAssessor.swift` | vision prompt/schema/parsing (reuses the existing loopback Ollama path) |
| `Services/IdentityRefreshPolicy.swift` | pure decision + `IdentityAnchorSelector` |
| `Services/IdentityAnchorGenerator.swift` | `IdentityAnchorGenerator` protocol + `LTXTemporalRefreshGenerator` |
| `Services/IdentityRefreshService.swift` | orchestration, persistence, staleness |

**Decision** is two independent questions, kept separately testable: does the
next shot need facial detail (from its shot scale), and does the inherited frame
contain it (from vision). Refresh only when yes-and-no. Triggering on framing
alone would waste a generation on shots that already work (D-072).

**Rules** (all in `IdentityRefreshThresholds`): close framing **and** one of —
face `none`, orientation `back`, scale `tiny`, or scale `small` with a non-clear
face.

**Precedence** (`TakeGenerationCoordinator`): explicit per-shot image → refresh
anchor → inherited continuity → opening reference → character anchor. The user's
own choice is never overridden.

**Anchor selection**: most recent refresh anchor, then the opening reference. A
raw character sheet is never selectable as a final scene anchor — only ever an
input to a transformation.

**Failure** never silently pretends normal continuity is equivalent: the shot
continues on its inherited frame and the reason is recorded in
`identityRefreshNote`.

**Persistence**: managed asset under `Assets/IdentityRefresh/`, project-relative.
A retake upstream clears the anchor via `identityRefreshSourceTakeID`.

**Queue**: unchanged. Refresh is a stage *inside* the Auto Movie job, awaited
before the next shot is enqueued, rendering through the same serialized path. No
second global job, concurrency still one.

**Prompt policy**: the generator is a *transformation* and deliberately does not
use the CONTINUE change-focused statement — preserving the state is the opposite
of the goal (D-073).

## 5. First real E2E — the now-closed limitation

`IDR E2E`, Standard 768×512, 4 shots, Director Auto, same opening still.
Director planned wide → medium-wide → **close-up** → medium, which is exactly
the intended trigger shape.

**No refresh fired.** The policy evaluated shot 3 and declined. Running the same
assessment on that exact frame returns:

```
subjectScale: "medium", faceVisibility: "partial", subjectOrientation: "front"
```

No rule matches: the subject is front-facing at medium scale, which is genuinely
*not* the identity-poor case. The decision was correct, and it demonstrates the
no-false-positive half of §67 in production — but it means **the trigger path
has not been observed firing in a real movie**. It is proven by unit tests and
by the two gate experiments, not by production.

The movie completed and assembled with no regression; costume continuity held
across all four shots.

## 6. Acceptance

- **Detection** — partial. Correct decline demonstrated in production; correct
  trigger demonstrated in tests and controlled experiment only.
- **Generator** — PASS (Gate #2).
- **Product MVP** — conditional ✓, explicit source wins ✓, managed persistence ✓,
  retake invalidation ✓, queue concurrency 1 ✓, failure path explicit ✓, real
  movie completes and assembles ✓.

## 7. Recommendation

1. **Keep the feature.** It is conservative, cheap when idle (one vision call
   only on close framings), and the repair is proven.
2. **Prefer direct reuse of a scene-compatible anchor before regenerating.**
   Gate #1's B matched Gate #2's C on identity, beat it on the beat, and cost
   nothing. The bridge should be the fallback for when no compatible anchor
   exists, not the first move.
3. **Observe the trigger in production before widening the rules.** The
   thresholds are deliberately narrow; loosening them without evidence would buy
   latency, not continuity.
4. A dedicated local still model behind `IdentityAnchorGenerator` remains a
   later swap, not a current need.

## 8. Cost

| Path | Added |
| --- | --- |
| No refresh (most shots) | one vision call, close framings only |
| Refresh | ~122 s bridge + extraction, against ~270 s per shot |

## 9. Verification

`swift run LTXTests`: **1249 passed, 0 failed** (1191 + 58).
`xcodebuild` Debug clean build (`CODE_SIGNING_ALLOWED=NO`): **BUILD SUCCEEDED**.
Production Queue untouched and still passing.

## 10. Existing scene-anchor reuse

The production sequence is now:

```
continuity frame -> visibility assessment -> refresh policy
    -> scene-compatible existing-anchor resolver
        -> reuse Opening Reference / prior generated anchor
        -> otherwise existing LTX refresh generator
```

The insertion point is immediately before the original generator call inside
`IdentityRefreshService`; there is no duplicate coordinator or queue. Candidate
types are the Opening Reference and prior generated refresh anchors. Character
Sheet/reference plates are excluded.

Identity sufficiency: assessed, no ambiguity, exactly one visible subject,
clear face/hair/costume, not back-facing or tiny. Scene compatibility: an earlier
state in the same project, shared cast when populated, same location or one
unbroken CONTINUE segment, and no explicit or structured location, time,
weather, wardrobe/outfit or transformation change. Camera and action changes
are intentionally ignored. Stale and missing candidates are rejected.

Source precedence remains explicit Shot Starting Image > adaptive anchor >
normal inherited continuity > opening-only sources. Persisted origin distinguishes
generated / reused Opening Reference / reused prior anchor. Optional fields keep
old JSON valid; a legacy missing origin means generated for staleness purposes.

## 11. Forced production true positive

Project: `8650AE3C-45A8-43A8-A96D-5315C3AFDC3D`

Queue job: `06DAE543-4BFA-479C-A119-35BCBB54B69B`

Plan: existing real opening Shot; Shot 2 medium-wide pull-back ending fully
back-facing; Shot 3 close-up look-back; Shot 4 medium resolve. All remain in the
Stone Courtyard with the same character UUID.

Actual Shot 2 continuity source:
`Assets/Continuity/shot-003-from-45702471-0B37-4347-96DD-1310771FC7F4.png`.
It is a real frame extracted by the production coordinator, not swapped after
assessment.

Shipping local-Vision result (`agents-a1:32k`):

```json
{
  "status": "assessed",
  "subjectPresent": true,
  "subjectCount": 1,
  "subjectScale": "medium",
  "faceVisibility": "none",
  "hairVisibility": "partial",
  "costumeVisibility": "clear",
  "subjectOrientation": "back",
  "ambiguityReason": ""
}
```

Target requirement: `faceCritical` from `close-up`. Exact policy result:
refresh required — inherited frame shows no face. Exact resolver result: reuse
Opening Reference — face, hair and costume clear; scene continuity compatible.
Selected project-relative path:
`Assets/OpeningReference/opening-reference-A358575C-D669-4F67-AF57-50B8970A7A66.png`.
The persisted Shot 3 take and actual `mlx_video.generate_av --image` used its
absolute managed-project URL.

Generator invocation evidence: no IdentityRefresh subprocess, no
`Assets/IdentityRefresh` output, generator spy count 0 in the integration test.
Additional LTX generations = 0. Shot 2 output mtime was 18:27:00; Shot 3 child
started 18:27:19. Extraction + local Vision + pure resolver cost 19 s total;
resolver itself is in-memory deterministic work. Saved LTX preparation latency
versus the prior generated anchor is approximately 122 s.

## 12. Source-only visual A/B

The direct control changed only the image source. Prompt, seed `1202830483`,
Q4 model, 4-bit encoder, 768x512, 121 frames, 25 requested steps and image
strength 0.5 matched production Shot 3.

| Criterion | inherited control | production reuse |
| --- | ---: | ---: |
| Face | 0 | **3** |
| Hair | 1 | **3** |
| Clothing | 1 | **3** |
| Overall identity | 1 | **3** |
| Requested framing | 3 | 3 |
| Narrative beat | 3 | 3 |
| Scene compatibility | 3 | 3 |
| Artifacts | 3 | 3 |

The control reframed and looked back correctly but invented a different woman
with a bun and light hooded outfit. Production kept the Adventurer Heroine's
brown ponytail, face, navy uniform details and cream cape while executing the
same close-up in the same courtyard.

## 13. Movie, queue and cost result

Shots 1–4 completed. Final Assembly produced 20.061 s, 768x512 H.264 with AAC
stereo. Queue state is Completed, progress 4/4. One-second sampling across the
remaining real production run measured maximum concurrent LTX children = 1;
the fixture occupied one global Production Queue job.

Three cost levels are now real:

| Path | Additional LTX work |
| --- | --- |
| Normal continuity | 0 generations |
| Refresh + reusable scene anchor | 0 generations |
| Refresh + no reusable anchor | 1 short preparation generation |

Known visual variance: Shot 4 introduced an unrequested secondary figure at the
doors. This is an ordinary render/beat artifact after the accepted transition,
not a resolver, queue, source-precedence or assembly failure.

## 14. Final verification and review media

- `swift build`: PASS
- `swift run LTXTests`: **1269 passed, 0 failed**
- `xcodebuild` Debug clean build, `CODE_SIGNING_ALLOWED=NO`: **BUILD SUCCEEDED**
- `git diff --check`: PASS
- Review media are non-overwriting `IDREFRESH_ACCEPT_*_20260811_183800` copies
  under Application Support's Videos directory. `history.json` was not edited.

The original false-positive protection and generated fallback remain covered;
the real run now proves the missing true-positive half. Architecture is frozen
at existing-anchor reuse before generated refresh.
