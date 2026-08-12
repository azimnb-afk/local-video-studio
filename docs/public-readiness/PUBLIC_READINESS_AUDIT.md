# GitHub Public Readiness — Phase 1 Audit

**Audit date:** 2026-08-12  
**Audited commit:** `cbb867c` (`director-extensions`)  
**Scope:** repository audit and minimal safe cleanup only. No generation, model download, cloud request, history rewrite, release publication, or push was run.

## Executive summary

The tracked application source does not contain a discovered credential or a hard-coded personal home-directory path, and it is small enough for ordinary Git hosting. It is **not ready to be published as a new public repository** without a focused Phase 2. The blockers are release ownership/configuration, unredacted internal engineering records, unproven public image provenance, and a test suite that relies on untracked `/tmp` video fixtures.

The source build itself is healthy on the audited Mac, but that is not a clean-clone proof: the Xcode Swift dependency is floating and the full test suite uses local baseline media that is not in Git.

## Audit method

- Examined tracked files, ignored generated directories, current remote/tags, Xcode project references, scripts, feature flags, model registry, README and docs tree.
- Searched tracked text for credential-shaped material and personal absolute paths. Findings are described by file/category only; no credential values are recorded here.
- Checked reachable history for common token/private-key indicators without printing content.
- Inspected current and historical blob sizes, installed dependency metadata, and the two tracked documentation images.
- Performed static clean-clone analysis. A separate clean clone was deliberately not made because dependency resolution would require network access and this phase must not download models or alter remote state.

## Repository safety

### Secrets and credentials

- No credential-shaped value was found in current tracked content for the searched GitHub, Hugging Face, AWS, OpenAI-style, bearer-token, or private-key patterns.
- The history indicator scan found configuration *names* for Apple notarization and an ElevenLabs preference, but no matching token/private-key indicator. This is not a substitute for a dedicated secret scanner before publication.
- `scripts/setup-secrets.sh` is a credential-handling helper. It does not embed a credential, but it exports a signing certificate and uploads secrets to a hard-coded GitHub repository. It must not be presented as a normal contributor setup step.
- The optional ElevenLabs feature stores a user-provided API key in `UserDefaults`, rather than Keychain. The key is not in Git, but secure storage and privacy disclosure require a release decision.
- Debug-only Director logs can retain raw local LLM responses in a temporary application-support file. Release builds do not use that path; the public privacy/debugging policy should still document it.

### Personal information and absolute paths

- Production Swift source and Xcode file references have no audited `/Users/<person>/…` reference. Runtime uses `FileManager`, Application Support, and documented system locations appropriately.
- Tracked internal documentation contains the local username, full home paths, project UUIDs, output filenames, PIDs, local virtual-environment paths, and historical acceptance instructions. Concentrated examples include `docs/implementation/DECISION_LOG.md`, `FINAL_IMPLEMENTATION_REPORT.md`, `GUI_ACCEPTANCE_CHECKLIST.md`, `ORIGINAL_FACE_MELT_FORENSIC.md`, `FACE_SCALE_ISOLATION_EVAL.md`, `OPENING_REFERENCE_ASPECT_FIX_EVAL.md`, and `CHARACTER_REFERENCE_CAPABILITY_AUDIT.md`.
- Xcode Release settings, legacy `scripts/build-local.sh`, `scripts/setup-secrets.sh`, the release workflow, Jekyll configuration, and public docs contain a specific owner/repository, signing identity, team identifier, or funding handle. These are not secret values, but are not transferable public-repository defaults.

### Ignore rules and generated artifacts

- `build/`, `dist/`, DerivedData, SwiftPM build state, Xcode user state, Python environments, logs, and macOS metadata were already ignored.
- This phase added ignore rules for dotenv files, Apple API/private signing material, keychain files, model-weight extensions, generated video formats, `.app`, and `.xcarchive`. Existing tracked files are unaffected by ignore rules.
- The current Git tree has 211 tracked files; no tracked model weights, generated video, application bundle, archive, DMG, or Python environment was found. Largest tracked blobs are two documentation PNGs (about 1.39 MiB and 1.29 MiB). Reachable Git objects total about 12.6 MiB.

## Licensing and model distribution

### Project and upstream

- Root `LICENSE` is MIT and attributes the existing project copyright to its recorded upstream author.
- `origin` points to `james-see/ltx-video-mac`; README, docs site configuration, release badges, and release links currently point there too. A public fork or successor must choose its own ownership, keep required MIT notices, and update links rather than imply that it is the upstream release channel.

### Dependency inventory

None of the following Python dependencies are vendored in the repository; they are installed in a user-selected Python environment. The recorded licenses are only what was locally available at audit time.

| Dependency | Role | Local metadata result | Public-release action |
| --- | --- | --- | --- |
| PythonKit | Swift bridge, fetched by SPM | Apache-2.0 | Commit a resolution and include required third-party notices for binary distribution. |
| mlx-video-with-audio 0.1.36 | LTX backend | MIT | Verify release artifact and upstream notice requirements. |
| MLX / mlx-lm / mlx-vlm | ML runtime / text / vision | MIT | Record version and notices in a third-party inventory. |
| huggingface_hub / transformers | model retrieval / tokenization | Apache-2.0 | Record versions and notices. |
| opencv-python | video helpers | Apache-2.0 | Verify packaged-wheel notices if distributed. |
| tqdm | progress reporting | MPL-2.0 AND MIT | Verify selected distribution terms. |
| mlx-audio, safetensors, numpy, Pillow | optional/local audio and support | license field unavailable locally | External license verification required. |
| FFmpeg / ffprobe | external executable at runtime | not bundled | Document installation and that licensing depends on the user-installed build. |

### Models

- The repository contains no model weights. Official LTX and optional derived models are external Hugging Face artifacts; the app records model-card URLs and performs user-controlled disk/license checks.
- The software MIT license does **not** license model weights. Before release, publish a model-license table with exact repository/revision, license link, download size, and whether explicit acknowledgement is required.
- Official descriptors track upstream rather than a pinned revision; derived descriptors are blocked until appropriately pinned and verified. That is a sound runtime policy but not a reproducible distribution manifest.

## Build reproducibility and runtime prerequisites

- The audited Xcode project targets macOS 14.0 and uses relative project file references; no personal absolute Xcode reference was found.
- `LTXVideoGenerator/Package.swift` and the Xcode project both use a floating PythonKit branch, and no `Package.resolved` is committed. The two declarations also name different branches (`master` vs `main`). A future build can resolve different source than this audit used.
- Python 3.11+, `mlx-video-with-audio==0.1.36`, external model/text-encoder assets, and FFmpeg/ffprobe are operational requirements. Root README and website instructions disagree with current setup behavior in several places.
- Normal tests use untracked `/tmp/ltx_baseline/*.mp4` media. Some suites skip their media assertions when absent, but `GenerationRuntimeDiagnosticsTests` treats its required real-MP4 fixture as a failure. Therefore a fresh clone cannot reliably reproduce the audited 1600-pass result.
- Release signing is also not portable: the project Release configuration and legacy automation contain a specific Developer ID/team/bundle identity.

## README and documentation audit

### Public-facing documentation

- README and Jekyll pages have a clear initial product description and Apple-Silicon framing, but still describe an earlier feature/configuration state. Examples include automatic model/package download language, stale model sizes/names, an old preset table, and release links for the upstream repository.
- The product is not universally local-only: optional ElevenLabs TTS/music sends selected user content to that cloud provider. Local LTX, local Ollama, and optional cloud audio need a precise privacy statement.
- Installation pages omit one current reproducible source-build path and do not fully reconcile Python, FFmpeg, model cache, model download consent, and optional services.
- Current public pages include claims such as an "uncensored" enhancer and adult-adjacent language that require explicit release policy review.

### Internal documentation and assets

- `docs/implementation/` and `docs/issue-comments/` are a useful engineering archive, but are not ready to be served as public product documentation. They contain local operational records, old branch/release claims, forensic notes, private-environment paths, and historical issue-response drafts.
- The two tracked documentation images have no provenance or license statement. One is a photorealistic identifiable person. Treat both as non-public until ownership/model-output provenance and publication rights are recorded.

## Feature flags, APIs, and safety posture

- General user-facing flags (registry, auto quality, director, film projects, storyboard, adaptive refresh) default on.
- Derived models, adult models, low-RAM adapter, and local API default off. Adult-classified models additionally require Adult Content Mode and policy/verification gates. This is an appropriate conservative default.
- The local API has token authentication and is optional. Its OpenClaw documentation is developer-oriented and should be separated from normal end-user onboarding.
- Retained adult-model code and terminology are not a secret, but a public repository needs a concise content policy, default behavior, and an explicit explanation that no such weights are bundled.

## Findings

### BLOCKER

1. **Unredacted internal records are tracked.** Sanitize, remove from the public branch, or move the identified implementation/forensic/issue-comment documents to a private archive before publishing. They expose personal local environment details and may describe private acceptance assets.
2. **Release ownership is hard-coded.** The Release project settings, legacy local build script, secret helper, workflow, site configuration, funding, README badges, and release links still identify a specific upstream owner. A public successor must be explicitly re-owned and must not ship/sign/release under that identity.
3. **Fixture provenance is incomplete.** The two documentation images lack a recorded reusable license/provenance; the photorealistic-person image needs explicit publication clearance or replacement.
4. **Full test success is not clean-clone reproducible.** Required `/tmp` baseline MP4s are not tracked or generated deterministically by the test harness.

### SHOULD FIX BEFORE PUBLIC

1. Pin Swift dependencies and commit `Package.resolved`; reconcile the two PythonKit branch declarations.
2. Replace legacy signing/secret scripts and tag-triggered workflow with owner-neutral, opt-in release configuration after a deliberate release-owner decision. Do not configure credentials in source.
3. Rewrite public README/site installation material from current source of truth: supported macOS, Apple Silicon/memory, Python/FFmpeg setup, model-install consent, Auto Movie/Storyboard basics, local-vs-cloud behavior, and current limitations.
4. Add `THIRD_PARTY_NOTICES` / a dependency license inventory and a separate model-license table. Verify unknown local metadata against upstream sources.
5. Replace UserDefaults storage for optional cloud API credentials with Keychain or explicitly limit the released feature and document its privacy behavior.
6. Add a clear public policy for optional adult/derived models, local API, debug log retention, and cloud audio.
7. Make media tests self-contained using a small licensed/generated fixture or deterministic fixture generator; never depend on a developer's `/tmp`.

### NICE TO HAVE

1. Add CI build/test workflow after dependency pinning; do not add it in this audit phase.
2. Add a documented support matrix and troubleshooting decision tree.
3. Add reproducible screenshots with attribution and an explicit privacy note for generated content.
4. Split public reference docs from private engineering decision/evaluation records once the public document set is established.
5. Add release checklist coverage for license notices, model-card changes, credential scanning, and notarization ownership.

### ALREADY READY

- MIT project license is present.
- No audited current tracked secret, private key, model weight, generated video, DMG, app bundle, archive, or Python environment was found.
- Production source and Xcode file references do not use a personal absolute path; normal user storage is based on system-provided directories.
- `.gitignore` already covered major build/distribution artifacts and was strengthened during this audit.
- Model weights are external rather than silently committed to Git.
- Conservative feature defaults keep local API, derived/adult models, and low-RAM adapter opt-in.
- Current baseline verification remains documented as `swift build`, 1600 test assertions, and Xcode Debug clean build success.

## Changes made in Phase 1

- Added conservative ignore coverage for dotenv files, Apple signing/keychain material, local model weight files, generated media, app bundles, and Xcode archives.
- Added this audit report. No application, generation, continuity, diagnostic, preset, model-runtime, or release behavior was changed.

## Recommended Phase 2

**GitHub Public Readiness — Phase 2: Public Documentation & Cleanup**

Priority order:

1. Decide public repository/release ownership, then remove or parameterize inherited owner/team/release links and release automation.
2. Create a public-doc set and private-archive plan; sanitize or exclude internal implementation/forensic/issue-response records.
3. Resolve image provenance and replace any asset without publication rights.
4. Make tests self-contained and pin all Swift/Python dependency inputs.
5. Write owner-neutral README/install/privacy/model-license/third-party-notice documentation, then add CI and release automation in a later dedicated phase.

## Verification after audit changes

Run the standard local gates before committing: `swift build`, `swift run LTXTests`, canonical Xcode Debug `clean build`, and `git diff --check`.
