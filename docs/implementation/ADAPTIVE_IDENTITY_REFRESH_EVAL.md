# Adaptive Identity Refresh — Evaluation

**Date:** 2026-08-11
**Baseline HEAD:** `87e7a9a`, worktree clean
**Classification: PASS WITH LIMITATION — architecture proven, MVP shipped, trigger not yet observed firing in a real movie**

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

## 5. Real E2E — the limitation

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
