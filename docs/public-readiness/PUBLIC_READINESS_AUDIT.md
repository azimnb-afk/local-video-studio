# GitHub Public Readiness — Phase 1, Phase 2, and Phase 3

**Phase 2 audit date:** 2026-08-12
**Phase 3 audit date:** 2026-08-12
**Sanitized snapshot base:** `6f2bdf6` on `director-extensions`
**Phase 3 baseline:** `ada82a4` on `director-extensions` (the Phase 2 checkpoint; working tree was clean before Phase 3 started)
**Scope:** Phase 1/2 were public-snapshot cleanup. Phase 3 is documentation and public-packaging only — README, installation docs, and license/notice documentation — with no change to generation behavior, Director, Auto Movie, Storyboard, Prompt Compiler, presets, Continuity, Selected Take precedence, Identity Refresh, ImageConditioning, diagnostics, or Production Queue. No LTX generation, model download, cloud request, remote mutation, public-repository creation, push, history rewrite, or private-history deletion was performed in any phase.

## Readiness decision

**Ready for clean-history GitHub source publication.** The sanitized, now-documented tracked snapshot (README, installation, licensing, and public docs corrected and cross-referenced against actual source) is safe to use as the initial content of a new clean-history public repository. Zero source-publication blockers remain.

**Signed-binary-distribution readiness is judged separately and is Not Ready** — see the SHOULD FIX list below (Keychain migration, release identity/signing decisions, and the unresolved model-license "Needs external verification" items) before publishing a signed `.dmg` at any scale beyond personal/internal use.

This decision applies to the tracked snapshot, not to this private development repository's historical commits. The development history is intentionally not part of the proposed public repository.

## Public history strategy

When publication is approved, export the tracked files from the accepted sanitized checkpoint and initialize a new repository from that snapshot:

```text
private development repository (history remains private)
    -> sanitized accepted HEAD
    -> tracked public files only
    -> new clean Git repository
    -> initial public release commit
```

Do not push this repository's existing history to the public remote. This phase did not run `git filter-repo`, `git filter-branch`, `git rebase --root`, a history rewrite, a remote change, or a push.

## Resolved Phase 1 blockers

### Personal and internal records

- Removed the tracked internal implementation, acceptance, forensic, environment, and handoff record collection.
- Removed the tracked issue-response draft collection.
- Replaced the one remaining product-facing reference to removed internal documentation with a self-contained statement.
- Re-audited the remaining tracked text for the former developer home path: no match remains. The remaining documentation is public-facing material plus this readiness record.

### Release ownership and signing

- Debug and Release now use the neutral development bundle identifier `com.example.ltxvideogenerator`. A distributor must supply its own final bundle identity before shipping a signed build.
- Release signing is automatic with an empty `DEVELOPMENT_TEAM`; no original Apple team or certificate is embedded in the project.
- Legacy packaging and secret helpers now require maintainer-supplied environment values for signing, notarization, team, and target repository. They neither choose an owner nor create a tag or push.
- The existing release workflow no longer names a particular signing identity; it reads that identity from a repository secret. It was not run or published in this phase.
- Documentation-site links, release links, funding entry, and source clone example no longer point to a specific upstream owner. Required MIT copyright attribution in `LICENSE` is intentionally retained.

### Repository-owned media fixtures

- Replaced the former machine-local video baseline dependency with three small, repository-owned synthetic MP4 fixtures under `Tests/LTXTests/Fixtures/`.
- The fixtures are FFmpeg test patterns and generated sine audio only; they contain no LTX output, model weights, user media, or real people.
- Fixture provenance, stream intent, and generation method are documented in `Tests/LTXTests/Fixtures/README.md`.
- `.gitignore` explicitly permits those test MP4 files while continuing to ignore generated media elsewhere.
- Tests resolve fixtures relative to the checkout, so no developer-maintained temporary baseline directory is required. The optional benchmark script also uses a neutral temporary output directory name.

### Unverified sample assets

- Removed both documentation images whose public redistribution provenance was not established during the audit. No replacement asset was introduced.
- No remaining tracked documentation sample image or large media asset was found. The only tracked binary media is the documented synthetic test fixture set (101,416 bytes total).

## Re-audit results

### Credentials and privacy

- A tracked-content scan for common credential and private-key indicators found no embedded credential value. This is a focused audit, not a substitute for a dedicated secret scanner before actual publication.
- The optional cloud-audio API key remains user-provided, default-off, and is not required for a build or normal local generation. Its current UserDefaults storage is a **SHOULD FIX** security-hardening item, not a sanitized-snapshot blocker: no credential is tracked and the feature is optional.
- No personal home-directory path, PID, DerivedData path, local project ID, internal acceptance log, handoff record, or forensic record was found in the remaining tracked text by the Phase 2 search.

### Project and dependency safety

- The Xcode project contains only relative source references and has no original developer signing-team requirement or personal absolute reference.
- PythonKit is pinned to the resolved revision in both the Xcode project and the app package manifest. The shared Xcode `Package.resolved` is tracked for reproducible package resolution.
- No model weights, app bundles, archives, DMGs, Python environments, or generated videos are tracked.

## Fresh tracked-files-only snapshot verification

An isolated temporary directory was created from the candidate tracked snapshot with a new local Git repository and a separate DerivedData path. It did not use the original checkout, its DerivedData, the original signing team, a model, or the former external media baseline. This was run once at the Phase 2 checkpoint and repeated at the Phase 3 checkpoint (documentation-only changes; no source file differs between the two runs).

| Gate | Phase 2 result | Phase 3 result |
| --- | --- | --- |
| `swift build` | PASS | PASS |
| `swift run LTXTests` | PASS — 1600 passed, 0 failed | PASS — 1600 passed, 0 failed |
| Xcode Debug `clean build` with `CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` | `BUILD SUCCEEDED` |
| `git diff --check` | — | PASS (no whitespace errors) |

The isolated Xcode build resolved the pinned PythonKit revision from its local package cache. A truly network-air-gapped first build still requires that dependency to be available through SwiftPM; this is an ordinary external source dependency, not a private-machine file dependency.

A documentation link-check confirmed every relative link and section anchor added or changed in Phase 3 (README.md, and docs/index.md, docs/installation.md, docs/usage.md, docs/parameters.md, docs/troubleshooting.md, docs/architecture.md) resolves to a file and heading that actually exists in the tracked snapshot.

## Phase 3 — README, Installation, Licensing & Public Documentation

**Scope:** audit the existing README and public `docs/` pages against actual source code, rewrite/correct them, and add third-party/model license documentation. Documentation and public packaging only — no generation-behavior change.

### README

Fully rewritten. The prior README described an earlier, materially smaller feature set (no Director, Auto Movie, Storyboard, Continuity, Character Consistency, Selected Take, Diagnostics, or Production Queue) and contained several inaccuracies corrected in this pass:

- Blanket "32GB minimum / 64GB recommended" RAM claim replaced with the app's own per-model figures from `ModelRegistry.swift` (32GB min/recommended for the default Q4 model; 48GB min / 64GB recommended for the two larger Unified models).
- The multi-package `pip install mlx mlx-vlm mlx-video-with-audio transformers safetensors huggingface_hub numpy opencv-python tqdm` instruction replaced with the single package the app actually requires and version-checks: `mlx-video-with-audio==0.1.36`. The app does not gate on `torch`, `diffusers`, or other transitive dependencies.
- `ffmpeg`/`ffprobe` added as a documented requirement — it was previously undocumented entirely, despite being required for Final Assembly, shot-continuity frame extraction, and media probing, and despite not being bundled with the app.
- Removed the embedded screenshot (`i.imgur.com`) and two example video links whose public-redistribution provenance was not established, consistent with the same standard Phase 1 already applied to other sample assets. No replacement asset was added.
- `git clone <repository-url>` changed to the requested `<PUBLIC_REPOSITORY_URL>` placeholder convention.
- Removed the "Building from Source" pointer to `./scripts/build-local.sh` as a plain dev build step — that script actually signs, notarizes, and packages a DMG, and hard-requires `CODE_SIGN_IDENTITY`/`APPLE_TEAM_ID`/a notary profile (a maintainer's own Apple Developer ID). Replaced with the unsigned `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` command this project's own Phase 1/2 verification already uses, and labeled `build-local.sh`/`build-release.sh` explicitly as maintainer-only distribution packaging scripts.
- No test-pass count is hardcoded (test counts change between runs; the README points to `swift run LTXTests` instead).
- Continuity is described only as Last-Frame I2V conditioning between shots, explicitly not motion or audio continuation.
- Character Consistency is described as an evaluative indicator (match/partial/conflict/unknown), not a guarantee — no "guaranteed consistency" language is used anywhere.
- MiniMax H3 is not described as supported anywhere in the rewritten docs.
- Adult/derived ("10Eros") lab models are mentioned only in Known Limitations and MODEL_LICENSES.md, as gated/unverified/off-by-default — not promoted as a feature.

### Significant finding: Prompt Enhancement discloses a third-party "reduced-filtering" model, unconditionally, with no code-level toggle

The most significant finding of Phase 3, going beyond what earlier phases flagged: when a user enables the single, off-by-default **"Enable Gemma Prompt Enhancement"** preference, `enhance_prompt_preview.py` unconditionally uses a hardcoded third-party fine-tune, `TheCluster/amoral-gemma-3-12B-v2-mlx-4bit`, discarding whatever model repository argument is actually passed to it. That script's own docstring states it "Always uses MLX uncensored Gemma"; its model card describes it as built to reduce refusal/content-filtering behavior relative to the base Gemma model. The script also contains a `_sanitize_prompt()` mechanism that placeholder-substitutes a fixed list of words (including several sexual/violent terms) before sending a prompt to that model, then restores them afterward.

This is un-gated: unlike the 10Eros lab video models (which require a disabled-by-default feature flag *and* an explicit "Adult Content Mode" toggle), Prompt Enhancement is a single, plainly-visible Preferences toggle with no additional consent step and no in-app disclosure of the model's "uncensored" nature or the word-substitution mechanism — the existing in-app help text mentions only the ~7GB download and automatic fallback-on-failure.

Two of the four already-tracked public `docs/` pages (`docs/installation.md`, `docs/usage.md`) had already been edited, apparently in a prior working pass, to describe an "**Use uncensored enhancer**" toggle as a separate opt-in control gating this behavior — **no such toggle exists in the current source** (`PreferencesView.swift`, `PromptInputView.swift`, `enhance_prompt_preview.py` were all checked; there is exactly one toggle, and it is unconditional). That description has been corrected in this phase to match actual behavior: enabling Prompt Enhancement at all uses this model, with no way to opt into a "standard" enhancer instead.

**This phase's decision:** disclose this honestly and neutrally in the public README, `docs/installation.md`, `docs/usage.md`, and `MODEL_LICENSES.md` (what the model is, that it's not the standard text encoder, and a link to its own model card), without reproducing the filtered-word list or promoting the feature. The underlying behavior itself — which model is used, and the absence of a "standard enhancer" option — was not changed; only the documentation was corrected to describe it accurately. **This is flagged as a SHOULD FIX for a maintainer decision** (see below) — whether the in-app Preferences disclosure text should also be strengthened, and whether an opt-in (rather than unconditional) design is wanted, are product decisions outside this documentation-only phase's scope.

### Installation

`docs/installation.md` was already largely accurate (correct single-package pip instruction, correct Python 3.11+/3.14.5 Supported-vs-Tested framing, correct "no automatic pip" language) and was used as a partial source of truth for the README rewrite. Corrected: stale `dgrauet/ltx-2.3-mlx-distilled-q4` cache-path example (the app has never used that repository for its official catalog — the actual third model is `notapalindrome/ltx23-mlx-av-q4`), and the phantom "Use uncensored enhancer" toggle described above.

### Licensing

- `LICENSE` (MIT, Copyright 2025 James Campbell) was audited and left unmodified, per instruction.
- This codebase's `origin` remote is `github.com/james-see/ltx-video-mac`, the upstream project this repository forked from and substantially extended. A one-line fork-provenance attribution to that project was added to the README's Licensing section — **flagged here as a judgment call**: the instruction was not to write private/current-owner URLs as the *install* URL (which correctly remains the `<PUBLIC_REPOSITORY_URL>` placeholder), but crediting a real, distinct upstream open-source project as a factual attribution was judged to be in scope and expected practice for a fork. A maintainer may remove this line before publication if undesired.
- Software license vs. model license are kept strictly separate in all new documentation (`MODEL_LICENSES.md` vs. `LICENSE`/`THIRD_PARTY_NOTICES.md`).

### Third-Party Notices (`THIRD_PARTY_NOTICES.md`, new)

Covers PythonKit (Apache License 2.0 — confirmed from the upstream repository's `LICENSE.txt`), MLX (MIT, Apple Inc. — confirmed from the upstream repository's `LICENSE`), `mlx-video-with-audio` (MIT — confirmed via PyPI), and `ffmpeg`/`ffprobe` (external, user-installed, not bundled or distributed by this repository; license depends on the user's own build and is marked Needs external verification per-installation rather than asserted). `Blaizzy/mlx-video` is credited but its license was not independently confirmed and is marked Needs external verification.

### Model Licenses (`MODEL_LICENSES.md`, new)

All three official video-model repositories (`notapalindrome/ltx2-mlx-av`, `notapalindrome/ltx23-mlx-av`, `notapalindrome/ltx23-mlx-av-q4`) have unresolved licensing:

- `ltx2-mlx-av`'s Hugging Face license tag reads `mit`, but its own model-card text states it "inherits the LTX-Video license from Lightricks" — a direct conflict, marked Needs external verification rather than resolved by guessing.
- `ltx23-mlx-av` and `ltx23-mlx-av-q4` (the app's default model) have no model card and no license tag published at all.
- The underlying Lightricks LTX-2 Community License Agreement (confirmed from `huggingface.co/Lightricks/LTX-2/blob/main/LICENSE`) is a restrictive, non-permissive license with a commercial-revenue threshold and twenty enumerated prohibited uses; whether it actually governs the `notapalindrome` conversions was not resolved.
- The three Gemma text-encoder presets carry Google's Gemma Terms of Use (confirmed `license: gemma` tag on the `mlx-community` bf16-12B repo; the other two presets were not independently re-confirmed and are marked accordingly).
- The prompt-enhancement model declares Apache 2.0 on its own repository, with a noted open question about whether Gemma-derived obligations still apply — marked Needs external verification.
- The two gated 10Eros lab repositories carry a Hugging Face `ltx-2-license` tag and are marked "Not-For-All-Audiences" by Hugging Face's own classification; not further resolved, consistent with this project not promoting them.

### Public Docs

`docs/architecture.md`, `docs/troubleshooting.md`, `docs/usage.md`, and `docs/parameters.md` were audited against current source and corrected where they diverged: the stale `dgrauet/ltx-2.3-mlx-distilled-q4` repository name (appeared in three files), a stale ElevenLabs voice roster in `docs/parameters.md` that did not match `AudioService.swift`'s actual `defaultVoices` list at all, an incorrect ElevenLabs voice count in `docs/usage.md` (documented as 9, actually 16), a stale troubleshooting entry describing the app downloading `Lightricks/LTX-2` (~150GB) directly (no current code path does this — the app only ever downloads the three `notapalindrome` repositories), and the blanket 32GB/64GB RAM claims repeated in `docs/troubleshooting.md`, `docs/usage.md`, and `docs/parameters.md`, replaced with per-model framing pointing back to the README's table. `docs/parameters.md`'s per-resolution memory-usage table (e.g. "768×512 | ~28-32GB") and its per-Mac generation-time table were left unchanged — they are plausible operational guidance but were not independently re-benchmarked in this documentation pass, and are not contradicted by anything in source.

### Known Limitations (new, cross-referenced from README)

See the README's [Known Limitations](../../README.md#known-limitations) section — RAM figures are the app's own declared values rather than independently re-benchmarked; `ffmpeg` is a separate, unbundled, user-installed dependency; the ElevenLabs API key is stored in `UserDefaults`, not Keychain; two of three official model repositories have no declared license and the third's declared license conflicts with its own model-card text; Prompt Enhancement uses an unconditional third-party "reduced-filtering" model as described above; adult/derived lab models and MiniMax H3 are explicitly not supported or promoted.

### Explicitly unchanged (Phase 3)

This phase did not change LTX generation behavior, Director, Auto Movie, Storyboard, generation settings, presets, continuity, selected-take precedence, cut/continue semantics, Identity Refresh, ImageConditioning, generation or runtime diagnostics, Production Queue, model runtime behavior, or `LICENSE`. It did not create a GitHub repository, push, tag, run CI, notarize, or publish a DMG/Homebrew formula. It did not touch the ElevenLabs UserDefaults-vs-Keychain storage mechanism itself (SHOULD FIX #3 below remains open) or the underlying Prompt Enhancement model-selection behavior (only its documentation).

## Remaining public-readiness work

### BLOCKER — 0 (source-release readiness)

No blocker was found for creating a new clean-history public repository from the sanitized, now-documented tracked snapshot.

### SHOULD FIX before a **signed-binary distribution** release (not blockers for source publication)

1. Move optional cloud-audio credentials (ElevenLabs API key) from `UserDefaults` to Keychain, and add a concise in-app privacy disclosure. **Not done in Phase 3** — out of scope by explicit instruction; still open.
2. Strengthen the in-app Preferences disclosure for Prompt Enhancement to name the specific third-party model and its "reduced content-filtering" nature (currently the public docs disclose this; the in-app help text still only mentions the ~7GB download and failure-fallback behavior). Consider whether an opt-in "standard enhancer" path is wanted as a product decision.
3. Decide a maintainer-owned release identity, final bundle identifier, signing/notarization policy, and public repository URL before publishing a binary release.
4. Review optional adult/derived-model terminology and add a public content policy before promoting those features (unchanged from Phase 2 — still open).
5. Resolve the "Needs external verification" items in `MODEL_LICENSES.md` — particularly the conflicting `mit`-tag-vs-model-card-text situation on `notapalindrome/ltx2-mlx-av`, and the two undocumented `notapalindrome` repositories — before distributing signed binaries built on these weights at any scale beyond personal use.

### NICE TO HAVE

1. Add public CI after the public owner and dependency policy are decided.
2. Add attributed public screenshots only after provenance and publication rights are recorded.
3. Add a release checklist for secret scanning, dependency changes, model-card review, license notices, signing, and notarization.
4. Optional `CONTRIBUTING.md` for public external contributions.

## Explicitly unchanged

This cleanup did not change LTX generation behavior, Director, Auto Movie, Storyboard, generation settings, presets, continuity, selected-take precedence, cut/continue semantics, Identity Refresh, ImageConditioning, generation or runtime diagnostics, Production Queue, or model runtime behavior.

## Verification commands

Run after the final checkpoint:

```text
swift build
swift run LTXTests
xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj \\
  -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO clean build
git diff --check
```

LTX generation was not run.
