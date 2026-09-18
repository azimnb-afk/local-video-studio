# Model Registry Guide — Adding a Model Without Losing an Existing One

## The absolute product rule

**Generate画面から選択できないユーザー向けモデルは、ユーザーにとって存在しない。**

("A user-facing model a user cannot select from the Generate screen does not
exist, for that user, no matter what else is true about it.")

The inverse is equally binding and is the subject of the second incident
below: **a registered, user-facing model must never disappear from the
picker just because its runtime happens to be busy, stopped, or mid-load of
a sibling tier.** Runtime readiness is not a visibility switch — see
"VISIBLE vs SELECTABLE vs GENERATABLE_NOW" just below.

The model's weight files being present on disk, its `ModelDescriptor` being
registered in `ModelRegistry`, its backend/runtime mapping existing in code,
and Settings having a folder picker for it are all necessary — none of them
is sufficient on its own. What a user actually sees is
`ModelReadinessStore.pickerModels(selectedID:)`, which is
`ModelRegistry.selectableModels()` (every registered user-facing model,
always) joined with each model's current `ModelReadiness` for status/
selectability only. That function, not any lower layer, is what decides
whether a model is available to a user.

This document exists because the rule was violated twice:

1. Adding MiniMax H3 Reference made Standard and High Quality intermittently
   vanish from the Generate dropdown (shared-key readiness collision). See
   "Root cause: the incident this guide is named after" below.
2. A later, unrelated readiness-accuracy fix caused the picker's own
   population logic (`readyModels()`-based filtering) to correctly-but-
   wrongly exclude any H3 tier that wasn't the one currently loaded on the
   shared runtime. See "Second incident: visibility must not depend on
   runtime readiness" below.

## VISIBLE vs SELECTABLE vs GENERATABLE_NOW

Three separate questions, never collapse them:

| Question | Answered by | Controls |
|---|---|---|
| **VISIBLE** — can the user see this model in the picker at all? | "Is it a REGISTERED, user-facing model?" (`ModelRegistry.selectableModels()`) | Whether the row exists |
| **SELECTABLE** — can the user pick this model right now? | "Is it CONFIGURED?" (`ModelReadinessStatus.isConfigured`) | Whether the row is enabled/tappable |
| **GENERATABLE_NOW** — will Generate succeed immediately, with no extra step? | RUNTIME READINESS (`ModelReadinessStatus.canGenerate`) | The row's status label only — e.g. "使用可能 (Ready)" / "別モデル稼働中 (Wrong Model)" / "停止中 (Stopped)" |

Runtime readiness (server running/stopped/wrong-model/loading) must only
ever affect the third row — never the first two. Picking a not-currently-
loaded H3 tier is exactly what triggers the existing runtime start/switch
logic at Generate time (`MiniMaxH3RuntimeManager.ensureReady`); the picker's
job is to offer the choice, not to pre-judge it.

## Levels of "the model exists"

When reporting on a model addition, distinguish these levels explicitly.
Never collapse them into a single `MODEL_AVAILABLE = true`.

1. **FILE_PRESENT** — the weight files are on disk (or downloadable).
2. **REGISTERED** — a `ModelDescriptor` exists in `ModelRegistry.descriptors`
   for this model's ID.
3. **CONFIGURED** — the user (or a default) has pointed the app at the
   file/folder/endpoint this model needs.
4. **RUNTIME_COMPATIBLE** — the configured runtime/backend can actually load
   it (version, architecture, capability checks pass).
5. **VISIBLE_IN_GENERATE** — the model's row is present in
   `ModelRegistry.selectableModels()`, which is *unconditionally* what
   `ModelReadinessStore.pickerModels()` shows. Runtime readiness never
   affects this level — see "VISIBLE vs SELECTABLE vs GENERATABLE_NOW" above.
6. **SELECTABLE_IN_GENERATE** — the model's row in the picker is enabled,
   i.e. `ModelReadinessStatus.isConfigured == true` (the model has the local
   configuration — weights, model directory, runtime — needed to attempt a
   generation). This is *not* the same as "ready to run this instant": an H3
   tier whose shared server currently has a different tier loaded is still
   SELECTABLE_IN_GENERATE.
7. **GENERATABLE** — a real generation request for this model actually
   succeeds end-to-end. `ModelReadinessStatus.canGenerate` answers the
   narrower "GENERATABLE_NOW, no extra step" question used only for the
   row's status label — never for levels 5 or 6.

A model only counts as user-available once it has reached
**VISIBLE_IN_GENERATE + SELECTABLE_IN_GENERATE**. Reaching REGISTERED or
CONFIGURED and stopping there is not "model added" — it is "model half
added," and it is exactly the state that let the Reference regression ship
unnoticed for a while. Conversely, a model that is VISIBLE_IN_GENERATE and
SELECTABLE_IN_GENERATE but not currently GENERATABLE (e.g. its shared server
has a sibling tier loaded) is still correctly "added" — GENERATABLE_NOW is a
per-moment runtime fact, not a precondition for existing in the picker.

## Root cause: the incident this guide is named after

MiniMax H3 Standard, High Quality, and (later) Reference all share one
runtime endpoint but load different weights. Readiness for "is the H3 server
running the model this row needs" used to be recorded in **one shared pair of
UserDefaults keys** (`minimaxH3LastReadinessState` /
`minimaxH3LastReadinessModelID`) regardless of which H3 tier had just been
probed. Whichever tier's readiness was checked *last* — opening Settings,
running `DependencyHealthManager.refresh()`, or actually generating —
overwrote that one shared slot. Every *other* H3 tier's next readiness
evaluation then read a `recordedModelID` that didn't match its own `id`, was
classified `.serverModelMismatch`, and `canGenerate` flipped to `false` —
silently dropping that tier out of `readyModels()` and therefore out of the
Generate/One Shot picker, even though its `ModelDescriptor` was still fully
registered and its files were still on disk.

**Fix:** `MiniMaxH3Configuration.lastReadinessStateKey(for modelID:)` /
`lastReadinessDetailKey(for modelID:)` are now per-model-ID keys, not one
shared pair — see `Services/MiniMaxH3Runtime.swift`. Recording one H3 tier's
readiness can no longer be misread as another tier's. Regression coverage:
`Tests/LTXTests/RegistryTests.swift` ("Model readiness policy" GATE_1–4 and
"Duplicate model ID guard") and `Tests/LTXTests/OneShotModelPickerTests.swift`
(PICKER_4b) drive the real `ModelReadinessResolver`/`ModelRegistry` functions
with all three H3 tiers configured and Ready at once and assert none of them
evicts another.

If a future model family needs a similar "which model is this shared server
currently running" readiness signal, key it by model ID from the start.

## Second incident: visibility must not depend on runtime readiness

After the per-model-key fix above, a *separate* fix (2026-09-18) corrected a
different bug: `MiniMaxH3RuntimeManager.status(...)` used to collapse every
transport error (a real connection refusal, a timeout, an unrelated probe
failure) into the same "no server is listening" verdict. That made a
healthy-but-differently-loaded H3 server (a real, common state — all three
H3 tiers share one runtime/endpoint and only one tier's weights can be
resident at a time) misreport as "not running" instead of the true
"a server is healthy, but a different model is loaded" (`.serverModelMismatch`
/ Wrong Model). Fixing that classification was correct on its own.

But `ModelReadinessStore.pickerModels(selectedID:)` was built on
`readyModels()` — `ModelRegistry.selectableModels()` filtered down to
`canGenerate == true` (`.ready` or `.serverNotRunning`), plus the persisted
selection kept visible-but-disabled as a special case. Once the
classification fix made an unloaded H3 tier correctly report
`.serverModelMismatch` (`canGenerate == false`) instead of the old, wrongly
generous `.serverNotRunning` (`canGenerate == true`), that tier no longer
passed the `readyModels()` filter — and, not being the current selection
either, it vanished from the picker entirely. **The readiness-accuracy fix
was correct; the bug was that picker *visibility* was ever wired to
`canGenerate` in the first place.**

**Fix:** `ModelReadinessStore.pickerModels(selectedID:)` no longer starts
from `readyModels()`. It starts from `ModelRegistry.selectableModels()` — the
full registered, user-facing set, unconditionally — and joins each model
with its current `ModelReadiness` only to decide the row's status label
(`ModelReadiness.pickerRowLabel`) and whether it's enabled
(`ModelReadinessStatus.isConfigured`, not `canGenerate`). The composition
logic is extracted into `ModelReadinessStore.composePickerRows(registered:
states:selectedID:descriptor:)`, a `nonisolated static` pure function, so
tests can drive the *exact* production algorithm against fixture data
instead of a hand-reimplemented mirror — a mirror is exactly how this
regression went uncaught by the existing test suite the first time around.
Regression coverage: `Tests/LTXTests/OneShotModelPickerTests.swift`'s
`PICKER_VISIBILITY_1`–`8` suite (every combination of Ready / WrongModel /
Stopped across all three H3 tiers, a readiness refresh, an A→B→C→A selection
walk, and a fresh-store rebuild) and `PICKER_RUNTIME_STATE_REGRESSION_TEST`
(a 7×7 sweep of every `MiniMaxH3RuntimeState` pair asserting the visible ID
set never shrinks below the registered set).

If a future model family's runtime can report a not-ready state, it must
still be VISIBLE_IN_GENERATE. Only `ModelReadinessStatus.isConfigured`
(a genuine setup gap: missing weights, missing model directory, missing
runtime) may disable a row, and nothing may ever remove one.

## MODEL_ADDITION_GATE

A model-addition task is not complete — do not report
`MODEL_ADDITION_COMPLETE` or `OLD_MODELS_PRESERVED: PASS` — until every line
below is actually PASS, not assumed:

```
MODEL_ADDITION_GATE:
- Model files present:                 PASS/FAIL
- Registry entry:                      PASS/FAIL
- Runtime mapping:                     PASS/FAIL
- Settings visibility:                 PASS/FAIL
- Generate picker visibility:          PASS/FAIL   (VISIBLE_IN_GENERATE)
- Generate picker selectable:          PASS/FAIL   (SELECTABLE_IN_GENERATE)
- Existing models still visible:       PASS/FAIL
- Existing model IDs unchanged:        PASS/FAIL
- Visible IDs stable across every
  runtime/readiness state combination:  PASS/FAIL   (PICKER_RUNTIME_STATE_REGRESSION_TEST)
- Existing presets unchanged
  unless explicitly requested:         PASS/FAIL
```

"Existing models still visible" and "existing model IDs unchanged" must be
checked by actually inspecting `ModelRegistry.selectableModels()` (or the
picker rows it feeds) *before and after* the change — not by inspecting the
diff and reasoning that it "should" be additive. The regression class this
guards against (a shared/global piece of state one model's addition
overwrites for a sibling) is invisible in a source diff; it only shows up by
evaluating the actual registry output.

### Reporting `OLD_MODELS_PRESERVED`

`OLD_MODELS_PRESERVED: PASS` requires all three of:

1. The existing model IDs are still present in `ModelRegistry`.
2. They still appear in `selectableModels()` / the Generate picker's rows
   (VISIBLE_IN_GENERATE) — this must hold regardless of runtime readiness;
   see "VISIBLE vs SELECTABLE vs GENERATABLE_NOW" above.
3. They are enabled in the picker, i.e. `ModelReadinessStatus.isConfigured
   == true` (SELECTABLE_IN_GENERATE) — **not** `canGenerate == true`.
   `canGenerate` answers GENERATABLE_NOW, a per-moment runtime fact (e.g. an
   H3 tier whose shared server has a sibling tier loaded); it must never be
   used to decide whether a model counts as "preserved."

Weight files still existing on disk, or a `RuntimeCompatibility`/backend
mapping still existing in source, is not evidence for any of the three and
must not be cited as if it were.

## Preferred verification path: headless first, one UI smoke last

`ModelReadinessResolver.evaluate`/`evaluateAll` and
`ModelRegistry.selectableModels()` both take an injectable `UserDefaults`
(and `FileManager`/`hubDirectory` where relevant), so the exact logic the
Generate/One Shot pickers run on is directly unit-testable — no GUI, no
running app, no clicking. Drive those functions with a fixture `UserDefaults`
suite and an on-disk fixture folder.

Do not reimplement the picker's composition rules in a test. `ModelReadiness
Store.pickerModels(selectedID:)` is `@MainActor` and hard-wired to
`ModelRegistry.shared`/`UserDefaults.standard`, so it can't take a fixture
directly — but its actual algorithm is extracted into `ModelReadinessStore.
composePickerRows(registered:states:selectedID:descriptor:)`, a `nonisolated
static` pure function that *is* fixture-friendly. Call that directly (see
`OneShotModelPickerTests.pickerRows`, a thin pass-through, not a
reimplementation). A hand-reimplemented mirror is exactly how the second
incident above went uncaught: the test's own copy of the filtering rule kept
matching the *old* `pickerModels()` behavior after the real function changed,
so the tests kept passing against themselves instead of the code that ships.

A model addition's final acceptance still needs **at least one real UI
smoke**: open Generate (or One Shot), open the Model dropdown, and confirm
every existing tier plus the new one is listed and selectable. The headless
tests catch a regression on every future change without a click; the one
UI smoke is what actually proves the dropdown a user sees matches what the
tests assert about the underlying function.

## See also

- `docs/MINIMAX_H3_MANAGED_RUNTIME.md` — MiniMax H3-specific model/runtime
  detail, including the incident this guide documents.
