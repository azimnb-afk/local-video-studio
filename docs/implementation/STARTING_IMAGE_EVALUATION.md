# Starting Image Evaluation (CharacterBible Phase 5)

## Goal
The objective of CharacterBible Phase 5 is to empirically evaluate the real-world utility, visual continuity, and composition tradeoffs of using CharacterBible reference assets as single-frame Starting Images (`sourceImagePath`) in LTX-2.3 MLX video generation.

## Environment & Capabilities
- **Platform**: Apple Silicon Mac (macOS 14+)
- **Backend**: `mlx-video-with-audio` 0.1.36 (`/Users/azimnb/ltx-venv/bin/python3`)
- **Model**: `notapalindrome/ltx23-mlx-av-q4`
- **Text Encoder**: `mlx-community/gemma-3-12b-it-4bit`
- **Capability Boundary**: Single-frame temporal latent injection at index 0 (I2V first-frame conditioning). **No face-only identity encoder, identity adapter, or multi-view identity set exists.** Terms `Face Lock`, `Identity Lock`, and `Same Person Guaranteed` are strictly prohibited.

## Character & Reference Assets
- **Project**: `07FA8292-0C89-4545-9D27-F1F64942C108` ("Character Reference Extraction Phase 2 Actual")
- **Character**: `Adventurer Heroine` (ID: `7F76DC58-1349-40F4-9D1F-B29352D83605`)
- **Reference Assets Evaluated**:
  - `Front`: 287×774 PNG (`8962D90A-0D53-45AC-A0AC-092979F2F55A`)
  - `Face / Close-Up`: 344×499 PNG (`BDEB1F6C-98E4-4ECB-B132-6A9114F53F8B`)

## Controlled Experiment Settings
All 3 conditions used identical parameters with fixed seed `42` and audio `OFF`:
- **Prompt**: `"CHARACTER 1: Adventurer Heroine. Face: Smiling face with dark hair in ponytail. Hair: Dark, pulled back into a ponytail... A young fantasy adventurer woman stands in an ancient seaside ruin at sunset. She looks toward the camera, takes a few natural steps forward, then turns slightly toward the glowing horizon."`
- **Seed**: `42`
- **Resolution**: `768×512` (24 fps, 121 frames, 5.04 seconds)
- **Steps**: `15` (Quick Preview / Standard resolver)
- **Audio**: `OFF`

---

## Controlled Comparison Matrix

| Metric | Condition A (None) | Condition B (Front) | Condition C (Face) |
|---|---|---|---|
| **Generation Success** | PASS (5.04s MP4) | PASS (5.04s MP4) | PASS (5.04s MP4) |
| **Facial Visual Resemblance** | Medium (Textual match) | High (Strong visual match) | High (Closest facial match) |
| **Hair Continuity** | High (Ponytail preserved) | High (Bangs & ponytail) | High (Exact ponytail) |
| **Costume Continuity** | High (Navy vest, cape) | Very High (Exact belt/boots) | High (Upper body details) |
| **Appearance Stability** | High | High | High |
| **Composition Leakage** | Low (Natural scene) | **High** (Standing front pose) | **Extremely High** (Close-up pose) |
| **Background Leakage** | Low (Ruin wall) | **High** (Plain studio & text) | **High** (Plain studio background) |
| **Pose Leakage** | Low (Dynamic walk) | **High** (Frontal posture) | **High** (Static upper body) |
| **Camera Freedom** | **High** (Dynamic framing) | Low (Frontal lock) | Very Low (Close-up lock) |
| **Motion Naturalness** | **High** | Medium | Medium |
| **Overall Utility** | **High (Best overall)** | **Medium (Good for Shot 1)** | **Low / Advanced Only** |

---

## Controlled Conditions & Findings

### Test A — Condition A (None / Text-only Baseline)
- **Take ID**: Generated via `TakeGenerationCoordinator` with `startingImageReferenceAssetID = nil`.
- **Output**: `/tmp/phase5_eval/Condition_A_(None).mp4` (281,841 bytes, 768×512).
- **Findings**:
  - `PromptCompiler` textual guidance successfully established character costume (navy blue vest, white cape, leather belts) and hair (dark ponytail).
  - High camera and movement freedom: the video generated a natural walking motion against a textured wall/ruin environment.
  - Zero composition or studio background leakage.

### Test B — Condition B (Front Starting Image)
- **Take ID**: Generated with `startingImageReferenceAssetID = 8962D90A-0D53-45AC-A0AC-092979F2F55A`.
- **Output**: `/tmp/phase5_eval/Condition_B_(Front).mp4` (257,113 bytes, 768×512).
- **Findings**:
  - Significantly higher visual resemblance to the reference sheet (costume details, boots, belt pouches, cape emblem).
  - High composition leakage: Frame 0 anchors to the frontal standing pose from the reference PNG. Plain studio background and text artifacts (`erence Sheet --`) leak into the video.
  - Tall portrait reference (287×774) is stretched horizontally to fit landscape (768×512) resolution.

### Test C — Condition C (Face / Close-Up Starting Image)
- **Take ID**: Generated with `startingImageReferenceAssetID = BDEB1F6C-98E4-4ECB-B132-6A9114F53F8B`.
- **Output**: `/tmp/phase5_eval/Condition_C_(Face).mp4` (560,284 bytes, 768×512).
- **Findings**:
  - Highest facial resemblance to the reference image face.
  - Extreme composition leakage: Locks the entire 5-second video into a static close-up / upper-body portrait framing against a plain studio background.
  - Totally overrides the prompt's wide seaside ruin environment and camera movement.

---

## Core Product Insights & Tradeoffs

1. **The Starting Image Tradeoff**:
   - Using a reference asset as Starting Image **improves visual resemblance to the reference sheet**, but **restricts camera movement, pose, and background environment**.
2. **Aspect Ratio Distortion**:
   - Crop assets from Character Sheets are often tall portrait aspect ratios (e.g. 287×774 or 344×499). Rendering to landscape (768×512) causes horizontal stretching unless padding or portrait rendering is used.
3. **Text-only Bible (None) Superiority for Dynamic Shots**:
   - Textual CharacterBible prompts alone (`PromptCompiler`) provide strong costume and hair continuity while leaving full freedom for camera movement, wide angles, and complex scene lighting.

---

## Phase 6 Product Recommendations

| Strategy / Feature | Recommendation | Rationale |
|---|---|---|
| **Starting Image Default** | `None` (Recommended) | Preserves maximum camera freedom, scene lighting, and motion naturalness. |
| **Front Reference Usage** | `OPTIONAL` | Best choice when user explicitly wants Starting Image for Shot 1 anchor. |
| **Face / Close-Up Usage** | `ADVANCED` | Extreme composition leakage; must not be default or labeled as "Face Lock". |
| **Multi-Shot Strategy** | `Shot 1 Only` | Use Starting Image on Shot 1, then rely on Text-only Bible for Shots 2+. |
| **GUI Guidance Badge** | `REQUIRED` | Display warning: *"Starting Image locks initial pose & background. Select None for dynamic camera movement."* |

---

## Verification
- `swift build`: PASS
- `swift run LTXTests`: **600 passed / 0 failed**
- `xcodebuild clean build`: **BUILD SUCCEEDED**
- Worktree: clean (no git push)
