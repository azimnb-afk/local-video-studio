# Local Video Studio v0.9.0 Preview 14

Local Video Studio for Mac `v0.9.0-preview.14` is a maintenance release focusing on **Settings Panel Layout Improvements**, **Responsive Inspector Sizing**, and **UI Usability Refinements** in the Generate view.

---

## What's New & Improved

### 🛠️ Settings Panel Layout & Usability

- **Clipping Prevention**:
  - Fixed an issue where text labels, Steppers, and controls in the right-side Generate settings panel could be partially cut off.
  - All parameter labels, presets, and controls now begin at their proper leading edges without horizontal clipping.
- **Responsive Width Support**:
  - Replaced the fixed 300pt inspector width with a flexible responsive layout (`280pt`–`360pt`), ensuring clean display at supported window sizes.
  - Adjusted minimum window width constraints to prevent layout squishing on narrow displays.
- **Vertical Scrolling**:
  - Added native vertical scrolling for MiniMax H3 parameter panels, ensuring all settings and warnings remain accessible even in shorter windows.
- **Clean Resolution Tier Presentation**:
  - Streamlined Resolution Tier selector labels (`Tier 1 (512p)` / `Tier 2 (640p)`) with effective resolution and orientation details displayed clearly beneath.
- **Improved Stepper & Seed Controls**:
  - Reorganized custom duration, inference steps, and seed controls with explicit alignments for improved readability.

### ⏱️ Existing Core Features

- **MiniMax H3 Real Progress (from Preview 13)**:
  - Real DiT sampling-step telemetry (`Step X of N`), elapsed render time, approximate ETA, and multi-shot weighted Auto Movie progress remain fully active across all workflows.

---

## Upgrading

Download `Local.Video.Studio-0.9.0-preview.14.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Existing projects, custom models, and archive history are preserved across the upgrade.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

This Preview build is an ad-hoc signed release candidate. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
