# Local Video Studio v0.9.0 Preview 11

Local Video Studio for Mac `v0.9.0-preview.11` is a targeted hotfix release improving **Source Image handling**, **automatic portrait orientation on import**, and **MiniMax H3 portrait canvas support**.

---

## What's New & Improved

### 🖼️ Source Image Improvements

- **Automatic Orientation on Import**: Importing a portrait Source Image in normal Generate now automatically adapts the generation resolution to portrait orientation (e.g. 512×320 → 320×512, 768×512 → 512×768). Importing a landscape image performs the inverse adaptation.
- **Crop Warning UX**: Added clearer warning indicators when an explicitly chosen aspect ratio would heavily crop the Source Image.
- **Manual Override Freedom**: Custom resolutions and dimensions can still be manually adjusted after image import without automatic override loops.
- **Explicit I2V Capability Guards**: Added explicit Image-to-Video capability checks to prevent silent fallback to Text-to-Video when a model does not support image conditioning.

### 🎭 MiniMax H3 Portrait Generation

- **Source Image Orientation Preservation**: MiniMax H3 now preserves Source Image orientation on the actual generation canvas instead of forcing inputs into a 512×288 landscape frame.
- **Dedicated 288×512 Canvas**: Portrait Source Images generate at 288×512, while landscape generation remains at 512×288, significantly reducing unintended vertical cropping of portrait keyframes.
- **First-Frame FL2VA Continuity**: Verified continuous visual conditioning from Frame 0 through subsequent diffusion steps.

---

## Upgrading

Download `Local.Video.Studio-0.9.0-preview.11.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Your existing projects, custom models, and archive history will remain fully intact.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

This Preview build is not Developer ID signed or notarized. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
