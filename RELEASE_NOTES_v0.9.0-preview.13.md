# Local Video Studio v0.9.0 Preview 13

Local Video Studio for Mac `v0.9.0-preview.13` introduces **Real MiniMax H3 Generation Progress**, **Continuous Multi-Shot Auto Movie Progress**, and **Real-Time Sampling Telemetry Integration** across all creation workflows.

---

## What's New & Improved

### ⏱️ MiniMax H3 Real Generation Progress

- **Real Sampling-Step Telemetry**:
  - Replaces the previous indeterminate activity bar during sampling with a real, determinate left-to-right progress bar driven directly by runtime events.
  - Displays live sampling step count (`Step X of N`) matching actual model execution.
  - Real-time progress percentage reflects true generation phase progression.
- **Elapsed Time & Approximate ETA**:
  - Displays second-by-second elapsed time (`Elapsed MM:SS`) during active rendering.
  - Provides approximate remaining time based on measured step timings.
  - ETA is strictly supplemental information and does not determine or artificially drive progress percentages.
- **Full Lifecycle Progress Coverage**:
  - Seamlessly progresses through input/keyframe conditioning, text encoding, DiT sampling steps, video decoding, audio decoding, and muxing.
  - 100% progress is shown only after output video files are verified and successfully registered to history/archive.

### 🎬 Auto Movie Overall Progress

- **Continuous Multi-Shot Progress**:
  - Overall movie progress accounts for the entire sequence and no longer resets to zero between shots.
  - Uses workload-aware weighting based on per-shot frame count and inference steps to distribute overall progress accurately.
  - Final movie assembly is explicitly tracked before reaching full completion.

### 🛠️ Unified Workflow Support

- **Cross-Workflow Availability**:
  - Real H3 step-based progress is fully integrated into **Generate**, **One Shot**, **Auto Movie**, and **Storyboard Take** workflows.
  - Preserves dedicated H3 presets (Quick, Standard, High, Custom), discrete duration allocation, and continuity safety guidance introduced in Preview 12.

---

## Upgrading

Download `Local.Video.Studio-0.9.0-preview.13.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Existing projects, custom models, and archive history are preserved across the upgrade.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

This Preview build is an ad-hoc signed release candidate. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
