# Public Release Candidate Checklist

This checklist defines the required verification steps before tagging or publishing a public release candidate (e.g. `v0.9.0-preview.1`).

---

## 1. Preflight Verification

- [ ] **Clean Tracked Worktree**: `git status --short` contains no unintended modifications or unreviewed staged files.
- [ ] **Deterministic Unit & Integration Tests**: `swift run LTXTests` passes with 0 failures.
- [ ] **Canonical Xcode Build**: `./scripts/build-dev-app.sh --clean` succeeds (`** BUILD SUCCEEDED **`) and yields the single canonical `.app` bundle.
- [ ] **Secrets Audit**: Repository-wide scan for API keys, bearer tokens, private credentials (`sk-`, `ghp_`, `xi-api-key`). No embedded secrets found.
- [ ] **Machine-Specific / Private Paths Audit**: No hardcoded developer paths (`/path/to/home`, `/private/tmp`, machine-specific absolute paths) in tracked source code or documentation.
- [ ] **License & Attribution Check**: Original MIT license header (`james-see/ltx-video-mac`) preserved. `THIRD_PARTY_NOTICES.md` and `MODEL_LICENSES.md` up to date.

---

## 2. Functional Smoke Testing

- [ ] **Direct Generate**: Single text-to-video prompt generates valid MP4 output with audio.
- [ ] **One Shot (I2V)**: Input image loaded, motion tempo configured, single take rendered.
- [ ] **Storyboard Workflow**: Multi-shot project created, shot prompts edited, takes generated, preferred takes selected.
- [ ] **Auto Movie Director**:
  - [ ] Opening Reference image analyzed (environment, lighting, subject, clothing extracted).
  - [ ] Local AI / Basic Director negotiates multi-shot beat plan.
  - [ ] Multi-shot sequence rendered sequentially via Production Queue.
  - [ ] CUT vs CONTINUE transitions execute correctly (Last-Frame I2V conditioning).
- [ ] **Backend Routing**:
  - [ ] LTX-2.3 routes to `mlx-video-with-audio`.
  - [ ] Custom LTX-2 MLX models route strictly to `ltx-2-mlx`.
  - [ ] No cross-backend silent substitution.
- [ ] **Aspect Ratio Presets**: Portrait source image auto-configures portrait resolution (e.g. 512x768).
- [ ] **Production Queue Navigation**: Sidebar navigation remains responsive while queue jobs execute.
- [ ] **Audio & Assembly**:
  - [ ] Shot-level No-BGM prompt policy applied.
  - [ ] Final Audio (BGM/Ambience) mixed via `ffmpeg`.
  - [ ] Final Assembly combines selected takes into continuous movie file.

---

## 3. Packaging & Metadata

- [ ] **App Version**: `MARKETING_VERSION` matches candidate version (e.g. `0.9.0`).
- [ ] **Build Number**: `CURRENT_PROJECT_VERSION` incremented monotonically (e.g. `9`).
- [ ] **App Display Name**: `LTX Video Generator`.
- [ ] **Bundle Identifier**: `com.example.ltxvideogenerator` preserved without regression.
- [ ] **Code Signing & Notarization**:
  - Unsigned/ad-hoc build for developer preview verified.
  - Distribution signing/notarization profile verified if building standalone `.dmg`.
- [ ] **Documentation Verification**:
  - `README.md` reflects current supported scope and known issues.
  - `RELEASE_NOTES_v0.9.0-preview.1.md` prepared.
  - `MODEL_LICENSES.md` and `THIRD_PARTY_NOTICES.md` present.

---

## 4. Public Repository Export Preparation

- [ ] **Export Manifest**: Review `docs/PUBLIC_REPO_EXPORT_PLAN.md`.
- [ ] **Exclusions Verified**: `.build`, DerivedData, scratch scripts, private testing logs excluded.
- [ ] **Clean Initial History**: Public repository initialized with clean single commit from approved tracked files.
- [ ] **No Remote Action**: Remote GitHub repository creation and publication remain UNCHECKED and unexecuted during local preparation.

---

## 5. Publication Gate (Human Action Required)

- [ ] Human review of license declarations and third-party notices.
- [ ] Human verification of developer signing identity and notarization credentials.
- [ ] Manual smoke test on target Apple Silicon hardware (e.g. M4 Pro / M3 Max).
- [ ] Create clean public git repository `ltx-video-mac-automovie`.
- [ ] Publish public GitHub release tag `v0.9.0-preview.1`.
