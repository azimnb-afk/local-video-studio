# GitHub Public Readiness — Phase 1 and Phase 2

**Phase 2 audit date:** 2026-08-12
**Sanitized snapshot base:** `6f2bdf6` on `director-extensions`
**Scope:** public-snapshot cleanup only. No LTX generation, model download, cloud request, remote mutation, public-repository creation, push, history rewrite, or private-history deletion was performed.

## Readiness decision

**Ready for Phase 3 — the sanitized working snapshot is safe to use as the initial content of a new clean-history public repository, after the Phase 2 checkpoint is created.**

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

An isolated temporary directory was created from the candidate tracked snapshot with a new local Git repository and a separate DerivedData path. It did not use the original checkout, its DerivedData, the original signing team, a model, or the former external media baseline.

| Gate | Result |
| --- | --- |
| `swift build` | PASS |
| `swift run LTXTests` | PASS — 1600 passed, 0 failed |
| Xcode Debug `clean build` with `CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |

The isolated Xcode build resolved the pinned PythonKit revision from its local package cache. A truly network-air-gapped first build still requires that dependency to be available through SwiftPM; this is an ordinary external source dependency, not a private-machine file dependency.

## Remaining public-readiness work

### BLOCKER — 0

No blocker was found in the sanitized tracked snapshot for creating a new clean-history public repository.

### SHOULD FIX before a distribution release

1. Phase 3: rewrite README and installation material from the current source of truth, including model download consent, Python/FFmpeg setup, optional cloud audio, and current capabilities.
2. Add third-party software notices and a model-license table with exact repositories, revisions, terms, and acknowledgement requirements.
3. Move optional cloud-audio credentials from UserDefaults to Keychain and add a concise privacy disclosure.
4. Decide a maintainer-owned release identity, final bundle identifier, signing/notarization policy, and public repository URL before publishing a binary release.
5. Review optional adult/derived-model terminology and add a public content policy before promoting those features.

### NICE TO HAVE

1. Add public CI after the public owner and dependency policy are decided.
2. Add attributed public screenshots only after provenance and publication rights are recorded.
3. Add a release checklist for secret scanning, dependency changes, model-card review, license notices, signing, and notarization.

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
