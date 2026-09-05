# v0.9.0-preview.9 — MiniMax H3 (Experimental), Directed Auto Movie & Continuity

Local Video Studio for Mac `v0.9.0-preview.9` is a major preview release introducing **experimental on-device MiniMax H3 support** on Apple Silicon, alongside comprehensive improvements to **Auto Movie planning**, **continuity handling**, and **runtime stability**.

---

## What's New

### 🎬 MiniMax H3 (Experimental Specialized Second Renderer)
- **Experimental On-Device H3 Support**: Run MiniMax H3 natively on Apple Silicon Macs (48 GB+ unified memory recommended).
- **Dual Video Generation**: Supports Text-to-Video (T2V) and Image-to-Video (I2V) with high temporal fidelity.
- **Native Audio Diffusion**: Generates aligned sound and dialogue in a unified generation pass.
- **Keyframe & Continuation**: Supports Starting Image conditioning, Opening Reference grounding, and Last-Frame Continuation.
- **Chained Longer Generation**: Multi-window generation (`chain_windows`) for extended scenes.
- **Managed Local Runtime**: Bundled `mlx-serve` 26.8.9 runtime with automatic in-app installation, health monitoring, and graceful recovery.
- **Cross-Profile Safety**: System-wide generation lease ensures safe, serialized H3 execution without blocking standard LTX jobs.
- **Truthful Progress & Diagnostics**: Accurate elapsed time, phase tracking, bounded diagnostics, and responsive job cancellation.

### 🎥 Auto Movie & Continuity
- **Directed Shot Planning**: Semantic Shot Purpose (establishing, reveal, reaction, performance, action), adaptive shot duration, Action Arc, and End State tracking.
- **CUT vs CONTINUE Continuity**: Explicit distinction between seamless continuous takes and dynamic camera cuts.
- **Opening Reference & Character Anchors**: Grounded visual consistency across multi-shot sequences without prompt drift.
- **New Start Frame Support**: Ability to inject fresh visual baselines at scene boundaries.
- **Final Assembly**: Automated timeline assembly and seamless stitch preview.

### ⚡️ LTX & Custom Model Architecture
- **LTX-2.5 Improvements**: Hardened model resolution, enhanced diagnostics, and robust signal termination reporting.
- **Custom LTX Production Routing**: Direct descriptor resolution for up to 5 registered custom LTX profiles.
- **Managed Runtime Consistency**: Pinned `ltx-2-mlx` managed runtime outranks dormant legacy paths; eliminates false "Update Required" warnings after tab switching.

### 🛡 Stability & Security
- **Strict Profile Isolation**: Clean separation between Personal and Dev application storage.
- **Lifecycle & Error Handling**: Transparent diagnostics for subprocess terminations and network timeouts.

---

## Known Limitations

- **MiniMax H3 is Experimental**: While T2V is functional, **I2V (Starting Image / Opening Reference)** is strongly recommended for subject and scene consistency.
- **High Compute Demands**: H3 generation on local Apple Silicon requires substantial memory and compute time.
- **Hardware Tiering**: MiniMax H3 requires 48 GB+ unified memory for optimal execution; 32 GB Macs should use standard LTX-2.3 / LTX-2.5 models.

---

## Upgrading

Download the `.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Your existing projects, custom models, and archive history will remain fully intact.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

Like previous preview builds (`preview.1` through `preview.8`), this is an unsigned preview release. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
