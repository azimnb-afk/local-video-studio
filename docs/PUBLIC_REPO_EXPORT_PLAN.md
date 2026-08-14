# Public Repository Export Plan

This document defines the procedure for exporting the feature-frozen codebase from the private development workspace into a clean, public repository named **`ltx-video-mac-automovie`**.

---

## 1. Export Overview

- **Target Public Repository Name**: `ltx-video-mac-automovie`
- **Initial Public Release Tag**: `v0.9.0-preview.1`
- **Export Strategy**: Fresh single initial commit containing all approved tracked files. No private branch history, internal debugging transcripts, or experimental POC commits will be exported.

---

## 2. Inclusions (Files & Directories to Export)

All tracked production and test files currently under Git management:

```
├── .github/
│   └── workflows/              # CI test workflows
├── LTXVideoGenerator/          # Complete SwiftUI Application & Core framework
│   ├── LTXVideoGenerator/      # App entry point & resources
│   ├── LTXVideoGenerator.xcodeproj
│   └── Sources/                # Models, Services, Views, Python helpers
├── Tests/
│   └── LTXTests/               # Comprehensive deterministic test harness
├── docs/                       # Architecture, usage, release checklist, export plan
├── extras/                     # OpenClaw skill example and tools
├── scripts/                    # Verified helper scripts (benchmark, calibrations)
├── CHANGELOG.md
├── EXAMPLES.md
├── LICENSE                     # Original MIT License (James Campbell)
├── MODEL_LICENSES.md           # Model weight licenses & disclosures
├── Package.swift               # SPM test package definition
├── README.md                   # Public Preview documentation
├── RELEASE_NOTES_v0.9.0-preview.1.md
└── THIRD_PARTY_NOTICES.md      # Third-party dependencies inventory
```

---

## 3. Exclusions (Files & Directories to Exclude)

The following items **MUST NOT** be included in the public export:

### Build Artifacts & Caches
- `.build/`
- `DerivedData/`
- `build/`, `dist/`
- `*.pyc`, `__pycache__/`
- `.DS_Store`
- `*.log`, `*.tmp`

### Private & Untracked Development Artifacts
- `llm_test*.swift` (user-owned local REPL test scripts)
- `llm_test*.log`
- `tests_output.log`, `prompt_output.log`
- `AppIcon_new.aseprite` (source design asset, only compiled .appiconset exported)
- Private local test fixtures in `/tmp`

### Experimental Branches / Repositories
- `ltx-2-mlx-ltx25-poc` (unrelated research POC)
- Any unpublished experimental branch histories

---

## 4. Export Procedure (To be executed when ready to publish)

```bash
# 1. Create a clean temporary export directory
EXPORT_DIR=$(mktemp -d)/ltx-video-mac-automovie
mkdir -p "$EXPORT_DIR"

# 2. Archive only tracked Git files from the release branch
cd <PATH_TO_DEV_REPO>
git archive HEAD | tar -x -C "$EXPORT_DIR"

# 3. Initialize fresh Git repository
cd "$EXPORT_DIR"
git init
git branch -M main

# 4. Verify clean export state
git status
swift build
swift run LTXTests

# 5. Create initial public release commit
git add .
git commit -m "feat: initial public preview v0.9.0-preview.1

LTX Video Generator for Mac — AutoMovie Edition
- Apple Silicon native AI video generation via MLX
- LTX-2.3 & Custom MLX video diffusion
- Auto Movie & Local AI Director integration
- Storyboard, shot continuity, and production queue"

# 6. Tag the release candidate
git tag -a v0.9.0-preview.1 -m "Release v0.9.0-preview.1"
```

---

## 5. Security & License Verification Before Publishing

1. **Verify Original MIT Notice**: Confirm [LICENSE](../LICENSE) is present at root.
2. **Verify Third-Party Notices**: Confirm [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [MODEL_LICENSES.md](../MODEL_LICENSES.md) are present.
3. **Verify Zero Secrets**: Run an automated scanner (e.g. `gitleaks` or `trufflehog`) against the exported directory before pushing to any public remote.
