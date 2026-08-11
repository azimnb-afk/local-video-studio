# Character Sheet ↔ Opening Reference Consistency

**Date:** 2026-08-12
**Baseline HEAD:** `0c69c3f`
**Classification: PASS — CHARACTER/OPENING CONSISTENCY PRODUCTION ACCEPTED**

## 1. Problem

The app had two kinds of visual evidence and no way to say they were different
kinds. `EffectiveAppearanceResolver` knew three origins — `userAuthored`,
`openingReference`, `directorGenerated` — and **no Character Sheet role at all**.

A sheet-backed character was already protected by accident:
`isUserAuthored` returns true whenever `referenceAssets` is non-empty, so an
imported sheet outranks opening-reference evidence. What was missing was any
*report* of disagreement — a sheet saying brown ponytail / navy vest against an
opening image showing a black bob / red jacket produced silence.

## 2. Semantic roles

| Source | Role |
| --- | --- |
| Character Sheet | canonical identity — who the character *is* |
| Opening Reference | scene observation — how they look in *this* moment |
| Director | inference |

Precedence is unchanged and remains: explicit user-authored → Character Sheet
evidence → Opening Reference evidence → Director guess → no claim.

## 3. What was added

`Models/CharacterOpeningConsistency.swift` — verdict model plus
`CharacterOpeningConsistencyResolver`. Per-field verdicts are `match`,
`conflict` or **`unknown`**, and `unknown` is first-class: refusing to guess is
what keeps a partly visible frame from reading as a contradiction.

Overall status: `match` / `partial` / `conflict` / `insufficientEvidence`.

**No second Vision call.** Both sides of the comparison already exist — the
canonical side from Character Sheet analysis (`character.appearance.hair`,
`defaultCostume`, `accessories`), the observed side from
`OpeningReferenceAppearance`. The layer is pure and runs offline.

### Deliberately conservative

Comparison is vocabulary-based, not semantic. A conflict is reported **only**
when both sides name recognised values from the same mutually-exclusive set
(colour words, a few hairstyle words) and none of them agree. Near-shades are
treated as equivalent (`blonde`/`blond`, `grey`/`silver`, `brown`/`auburn`,
`cream`/`beige`/`white`, `navy`/`blue`). Everything else is `unknown`.

A false conflict would train the user to ignore the warning, which is worse
than staying quiet.

Several people in the opening frame ⇒ `insufficientEvidence`, never a guess at
which one the sheet describes. A multi-view sheet (front/side/back/close-up) is
one character, not a crowd.

## 4. What it does *not* do

- It never rewrites canonical identity.
- It never changes which image the first shot starts from. §12: if the user
  chose an Opening Reference, that image is still what LTX receives — a conflict
  produces a warning, not a substitution.
- It makes no biometric or same-person claim.
- CONTINUE prompts are untouched; Change-Focused behaviour is unchanged.

## 5. Persistence and invalidation

Stored on `FilmProject.characterOpeningConsistency`, recording which opening
image and which sheet asset it compared. `OpeningReferenceSync.invalidateIfStale`
drops it when the opening reference is replaced or cleared, or when the sheet
asset changes. Legacy projects decode with no verdict.

## 6. Initial UI

One line in the Opening Reference section — ✓ consistent / ? partial /
⚠ conflict — with per-field detail for anything not `unknown`, and, on conflict,
one sentence saying the sheet stays canonical while the image is still used as
the first frame. Generation is never blocked.

## 7. Verification

40 focused checks covering A–J of the brief, plus a real-data case: the verbatim
strings from the real Adventurer Heroine sheet analysis
(`"Dark, pulled back into a ponytail"`) against the real opening-still analysis
(`"Long hair, likely brown in color"`). Two independent model descriptions of
the same character return **partial**, with clothing colour `match` (navy/blue)
and hair colour `unknown` — not a conflict. That is the case the conservative
design exists for.

- `swift run LTXTests`: **1360 passed, 0 failed** (1316 + 44)
- `xcodebuild` Debug clean build: BUILD SUCCEEDED
- `git diff --check`: PASS

## 8. Limitation

The comparison recognises colour and a few hairstyle words. Descriptors outside
that vocabulary — "dark", "light", garment shapes — return `unknown` rather than
being interpreted. Widening the vocabulary without evidence would buy false
positives, so it stays narrow until a real miss is observed.

## 9. Precision and visibility follow-up (D-089)

The first production project, **旗の子**, exposed a false `Accessories`
conflict. Its Character Sheet described a blue flag with a gold emblem, while
the Opening Reference described a brown belt and golden boots. The previous
whole-field colour comparison treated blue and brown as contradictory despite
referring to different objects.

The resolver is now versioned (`resolverVersion = 2`) and compares accessory
colours only when the same recognised object occurs on both sides. Different or
unrecognised objects return `unknown`; `gold` and `golden` are equivalent.
Existing persisted verdicts from an older or missing resolver version are
recomputed locally from the existing Character Sheet and Opening Reference
analysis during project loading. This does not call Vision, start LTX, alter
the Opening Reference, or rewrite canonical Character Bible fields.

The compact informational verdict now appears above Planned Shots in Auto Movie,
rather than inside the lower Opening Reference section. It remains non-blocking:
the opening image continues to be the actual first-frame source even for a real
conflict.

The real persisted **旗の子** project recomputes to `partial`: hairstyle and
clothing colours match, while hair colour and accessories are honestly
`unknown`; it is no longer a false conflict.
