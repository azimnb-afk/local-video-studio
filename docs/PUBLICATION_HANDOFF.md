# Publication Handoff & Release Procedure

This document provides the concise checklist and step-by-step procedure for the maintainer to publish **v0.9.0-preview.1** publicly to GitHub once human review is complete.

---

## Pre-Publication Human Review Checklist

1. [ ] **Model Terms Review**: Spot-check Hugging Face model cards for [Lightricks/LTX-2.3](https://huggingface.co/Lightricks/LTX-2.3), [MLXBits/10Eros](https://huggingface.co/MLXBits/ltx-2.3-10eros-v1.3-dmd-mlx-q4), and [Google Gemma](https://ai.google.dev/gemma/terms).
2. [ ] **Human Audio / Video Check**: Optionally generate a short test movie locally to visually verify motion dynamics and listen to natural audio.
3. [ ] **Distribution Format Decision**:
   - **Option A (Recommended for Preview)**: Source-only public repository on GitHub (developers build with Xcode or run tests with SPM).
   - **Option B (Signed Binary)**: Standalone `.dmg` distribution (requires Apple Developer ID certificate and `xcrun notarytool` notarization).

---

## Staged Public Repository Verification

The sanitized public staging repository has been prepared locally at:
`<STAGING_REPO_PATH>` (e.g. `../ltx-video-mac-automovie-public-preview`)

1. Inspect the staged files:
   ```bash
   cd <STAGING_REPO_PATH>
   git status
   git log -1
   ```
2. Verify that all 2,201 tests pass from the staged repository:
   ```bash
   swift build
   swift run LTXTests
   ```

---

## Step-by-Step GitHub Publication (Manual Maintainer Action)

Execute the following commands when you are ready to publish:

### 1. Create GitHub Repository
Create a new public repository on GitHub (e.g. named `ltx-video-mac-automovie` or `ltx-video-mac`).  
*Do not initialize with a README, .gitignore, or license on GitHub (these are already present in the staged repository).*

### 2. Add Remote and Push
```bash
cd <STAGING_REPO_PATH>

# Add your GitHub remote URL
git remote add origin https://github.com/<your-username>/<your-repo-name>.git

# Push main branch
git push -u origin main
```

### 3. Tag and Publish Release Candidate
```bash
# Create annotated tag
git tag -a v0.9.0-preview.1 -m "Release v0.9.0-preview.1 (Public Preview)"
git push origin v0.9.0-preview.1
```

### 4. Create GitHub Release
1. Open your repository on GitHub → **Releases** → **Draft a new release**.
2. Select tag `v0.9.0-preview.1`.
3. Set Release Title: `v0.9.0-preview.1 — First Public Preview`.
4. Copy the release description from `RELEASE_NOTES_v0.9.0-preview.1.md`.
5. If distributing a signed binary, attach the notarized `.dmg` / `.zip` archive.
6. Click **Publish release**.
