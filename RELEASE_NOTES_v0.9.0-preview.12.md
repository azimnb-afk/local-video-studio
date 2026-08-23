# Local Video Studio v0.9.0 Preview 12

Local Video Studio for Mac `v0.9.0-preview.12` introduces dedicated **MiniMax H3 Generation Presets**, unified **cross-workflow H3 integration** (Generate, One Shot, Auto Movie, Storyboard), an optimized **Auto Movie Discrete Duration Solver**, and **Long Continuity Safety Guidance**.

---

## What's New & Improved

### ⚡ MiniMax H3 Dedicated Presets

- **Quick Preset**:
  - Resolution: 512×288 (Landscape) / 288×512 (Portrait)
  - Duration: 3 sec (73 frames @ 24fps)
  - Steps: 8 steps
  - Ideal for fast visual previews and rapid story experimentation.
- **Standard Preset (Recommended)**:
  - Resolution: 512×288 (Landscape) / 288×512 (Portrait)
  - Duration: 4 sec (90 frames @ 24fps)
  - Steps: 10 steps
  - Proven optimal balance between detail retention, prompt adherence, and generation speed.
- **High Preset**:
  - Resolution: 640×384 (Landscape) / 384×640 (Portrait)
  - Duration: 4 sec (90 frames @ 24fps)
  - Steps: 12 steps
  - Higher resolution canvas for finished productions.
- **Custom Preset**:
  - Configurable resolution tiers (Tier 1: 512×288 / 288×512, Tier 2: 640×384 / 384×640)
  - Duration control (1.0 to 6.0 sec on legal 17k+5 frame ladder)
  - Step control (6 to 20 inference steps)

### 🎬 Unified Workflow Support

- **Generate & One Shot**: Full preset selector, live resolution summary, and starting image orientation adaptation for both text-to-video (T2VA) and first-frame image-to-video (FL2VA).
- **Storyboard & Auto Movie**: Multi-shot projects now fully inherit chosen H3 preset parameters across all individual shots and takes.
- **Director ON / OFF**: Supports both AI-directed automated storyboard structuring and direct prompt-segment planning with fail-closed capacity protection.

### ⏱️ Auto Movie Discrete Duration Solver

- **17k+5 Ladder Optimization**: Automatically solves for the optimal combination of legal H3 frame counts (22, 39, 56, 73, 90, 107, 124, 141) to closely match requested total movie durations (e.g. 12s Standard allocates 4 balanced shots [90, 73, 73, 56] = 12.17s, drastically reducing previous duration drift).
- **Practical Shot Count Protection**: Prevents micro-shot explosion by bounding shot counts to natural movie pacing while respecting preset safe per-shot limits.

### 🛡️ Long Continuity Safety Guidance

- **Chain Quality Warning**: Longer H3 clips and long CONTINUE chains may gradually lose fine detail. Local Video Studio now monitors consecutive continuation chains and displays non-blocking guidance when a chain exceeds 3 consecutive continuations (4+ shots), recommending a scene cut every 2–3 shots for maximum visual sharpness.

---

## Upgrading

Download `Local.Video.Studio-0.9.0-preview.12.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Existing projects, custom models, and archive history will remain fully intact.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

This Preview build is an ad-hoc signed release candidate. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
