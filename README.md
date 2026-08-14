# Local Video Studio for Mac — AutoMovie Edition

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-orange.svg)](https://support.apple.com/en-us/HT211814)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/badge/Release-v0.9.0--preview.1-purple.svg)](RELEASE_NOTES_v0.9.0-preview.1.md)

Apple Silicon Macで、画像1枚＋短い指示からローカルAI動画を生成。
LTX-2.3、Custom MLX Models、Auto Movie、Local AI Director対応。

> **Independent Project Disclaimer**: Local Video Studio is an independent open-source community project and is not affiliated with, sponsored by, or endorsed by Lightricks Ltd., Google LLC, or Apple Inc.
>
> **Software License vs. Model Licenses**: The MIT license in this repository covers the Swift and Python application source code only. **No model weights are bundled in this repository or source release.** LTX-2.3, Gemma text encoders, and user-supplied third-party models are separate works downloaded independently by the user from Hugging Face and remain subject to their respective licenses and usage terms. See [MODEL_LICENSES.md](MODEL_LICENSES.md) and [License](#license).

---

## What It Does

Local Video Studio for Mac is a native macOS desktop studio for on-device AI video generation powered by Apple Silicon (MLX). It transforms single reference images and concise text prompts into multi-shot cinematic sequences with synchronized audio, persistent character continuity, and automated shot direction.

Generation runs **locally on your Mac** via Apple Silicon unified memory—no remote server GPU subscription required.

---

## Features

- **Native macOS Interface**: Built in SwiftUI with native performance, real-time generation previews, and background job queuing.
- **Auto Movie Director**: Turn a single prompt or opening reference image into a multi-beat cinematic story. Plans camera angles, shot scales, and action pacing.
- **Local AI Director**: Connects to local LLM providers (Ollama / Local AI) to negotiate structured multi-shot scripts on-device.
- **Storyboard Workflow**: Build multi-shot films shot-by-shot with full manual control over prompts, takes, and camera direction.
- **Shot Continuity (Last-Frame I2V)**: Seamlessly carries the selected take's final frame into subsequent shots as an image conditioning anchor with adaptive strength.
- **Character & Scene Consistency**: Opening Reference analysis extracts environment, lighting, subject state, and visible clothing evidence to ground scene continuity across takes.
- **Selected Take Precedence**: Generate multiple takes per shot and mark your preferred version for downstream continuity and Final Assembly.
- **Source Orientation Presets**: Automatically adapts generation resolutions (16:9 landscape vs 9:16 portrait) based on input source image aspect ratios.
- **Motion Tempo Control**: Contextual motion pacing instructions preserved across multi-shot sequences.
- **Integrated Audio Pipeline**:
  - **Native Synchronized Audio**: Per-shot natural sound effects generated directly by the underlying model.
  - **No-BGM Policy v2**: Prompt-level suppression of unwanted background music to keep speech/SFX clean.
  - **Final Audio Layer**: Global BGM and Ambience track mixing via local `ffmpeg`.
- **Production Queue**: Asynchronous background generation queue with take management, cancellation, and retry capabilities.
- **Video Archive & History**: Centralized library to inspect, play back, export, and manage generated takes and project assemblies.
- **Custom LTX-2 MLX Support**: Configure arbitrary compatible fine-tuned models locally via the secondary `ltx-2-mlx` backend without code modification.

---

## Supported Models

| Model | Architecture | Backend | Status | Target Hardware |
|:---|:---|:---|:---|:---|
| **LTX-2.3 Distilled Q4** (Default) | LTX-2.3 AV | `mlx-video-with-audio` | Supported (Official) | 32 GB+ Unified Memory |
| **LTX-2 Unified** | LTX-2 AV | `mlx-video-with-audio` | Supported (Official) | 48–64 GB Unified Memory |
| **LTX-2.3 Unified** | LTX-2.3 AV | `mlx-video-with-audio` | Supported (Beta) | 48–64 GB Unified Memory |
| **Custom LTX-2 MLX Model** | LTX-2 Derived | `ltx-2-mlx` | Supported (User-Configurable) | 24–32 GB Unified Memory |

*Note: Custom LTX-2 MLX models can be configured in Preferences > Models & Features and run via the isolated `ltx-2-mlx` backend.*

---

## Requirements

| Component | Minimum Specification | Tested / Recommended Baseline |
|:---|:---|:---|
| **Operating System** | macOS 14.0 (Sonoma) or later | macOS 14.x / 15.x |
| **Processor** | Apple Silicon (M1 Pro / M2 / M3 / M4) | Apple M4 Pro or Apple Silicon Max/Ultra |
| **Unified Memory** | 32 GB (Q4 models) / 48 GB (Full models) | 48 GB+ Unified Memory |
| **Python** | Python 3.11+ | Python 3.11 / 3.12 / 3.14 |
| **`ffmpeg` / `ffprobe`** | Required for Final Assembly & frame extraction | Installed via Homebrew (`brew install ffmpeg`) |
| **Disk Space** | ~30 GB free for default model + encoder cache | Fast internal SSD |

---

## Quick Start

### 1. Build and Launch

#### Option A: Install Personal App (Recommended for daily use)
```bash
./scripts/install-personal-app.sh --open
```
Installs the Release application to `~/Applications/Local Video Studio.app` with isolated state (`com.localvideostudio.personal`).

#### Option B: Build Development App
```bash
./scripts/build-dev-app.sh --open
```
Builds the Debug application with isolated development state (`com.localvideostudio.dev`).

### 2. Set Up Python & Dependencies
1. Open **Preferences** (⌘,) in the app.
2. Click **Auto Detect** to configure your Python environment.
3. Click **Install Missing Packages** or run in your terminal:
   ```bash
   pip install "mlx-video-with-audio==0.1.36"
   ```
4. Ensure `ffmpeg` is available: `brew install ffmpeg`.

### 3. Direct Generate
1. Switch to **Direct Generate** in the sidebar.
2. Enter a prompt or drop a source image.
3. Click **Generate** to create your first single-shot video.

### 4. Try One Shot
1. Switch to **One Shot**.
2. Select an image, choose a motion tempo and camera direction, and click **Plan & Generate**.

### 5. Create an Auto Movie
1. Switch to **Auto Movie**.
2. Set an **Opening Reference image** and enter a brief narrative (e.g., "A detective investigates an abandoned train platform in the rain").
3. Click **Plan Movie** to inspect the Local AI Director's beat plan.
4. Click **Generate Movie** to render shots sequentially to the Production Queue.

---

## Auto Movie Workflow

1. **Opening Reference Grounding**: Drop a starting image. The vision engine analyzes scene environment, lighting, subject state, visible clothing, and key objects.
2. **Director Beat Planning**: The Local AI Director formats structured JSON shot beats consistent with the opening visual state.
3. **CUT / CONTINUE Strategy**:
   - **CONTINUE**: Automatically passes the last frame of the previous shot as the starting image for continuous action.
   - **CUT**: Transitions camera angles or locations without image conditioning.
4. **Assembly**: Automatically combines selected takes into a single continuous film with audio crossfades via `ffmpeg`.

---

## Director Modes

- **Auto**: Automatically selects the best available director provider.
- **Local AI**: Connects to localhost Ollama (`gemma3`, `llama3`, `qwen2.5`) with structured JSON protocol negotiation.
- **Basic (Deterministic)**: Rule-based fallback director ensuring reliable shot planning without requiring an external LLM server.

---

## Generation Workflows

- **Direct Generate**: Rapid single-prompt text-to-video or image-to-video generation.
- **One Shot**: Guided single-scene generation with camera motion and style presets.
- **Storyboard**: Granular multi-shot project builder with manual prompt editing, take branching, and individual shot regeneration.
- **Auto Movie / Hybrid**: Automated narrative scriptwriting, character grounding, and multi-shot batch rendering.

---

## Model Setup

Models are managed transparently:
- **Video Weights**: Downloaded on first generation into `~/.cache/huggingface/hub/`. Downloads can be paused and resumed.
- **Text Encoders**: Selected in Preferences (Default: `Gemma 12B bf16` / `Gemma 4B bf16` / `Gemma 12B 4-bit`). Explicit **Download** button in the UI ensures the text encoder is cached before generation starts.
- **No Background Telemetry**: Models are fetched directly from official Hugging Face repositories only upon explicit user action.

---

## Production Queue

All generation requests are dispatched to a resilient background queue:
- **Non-blocking UI**: Continue writing prompts and planning storyboards while generations render.
- **Job Status & Cancellation**: Inspect live rendering progress, execution time, and memory usage.
- **Persistent Archive**: Finished jobs automatically populate the project archive.

---

## Audio Pipeline

- **Synchronized Natural Audio**: LTX unified audio-video models generate organic SFX and ambient audio matching scene motion.
- **No-BGM Policy v2**: Prompt-level negative constraints suppress unwanted background music generation during video synthesis.
- **Final Audio Layer**: Mix custom BGM files (with loop and volume controls) and atmospheric ambience tracks directly into the final film assembly.
- **Optional Cloud Audio**: Optional ElevenLabs integration for high-quality voiceover TTS and AI-generated music.

---

## Portrait Images & Aspect Ratios

- **Orientation-Aware Presets**: When an input image is loaded, the app detects aspect orientation and automatically configures portrait dimensions (e.g. 512x768 / 9:16) or landscape dimensions (e.g. 768x512 / 16:9).

---

## Known Issues & Limitations

- **No-BGM is Prompt-Based**: Negative prompting strongly suppresses BGM, but acoustic output is model-dependent and music suppression cannot be 100% mathematically guaranteed by the diffusion weights.
- **Motion Tempo Continuity**: Motion tempo shapes prompt dynamics across shots, but true physical momentum continuation remains bounded by Last-Frame I2V conditioning.
- **Identity Consistency vs Face Lock**: Character Bible grounding maintains costume and appearance consistency, but diffusion models do not provide deterministic biometric Face Lock.
- **External Dependency**: `ffmpeg` is required for multi-shot assembly and must be installed separately by the user.
- **Hardware Intensive**: Local generation fully utilizes GPU and unified memory. Close heavy applications during multi-shot rendering.

---

## Privacy & Local-First Architecture

- **100% Local Inference**: Video generation, text embedding, Local Director LLM, and final movie assembly execute completely on your Mac.
- **Zero Telemetry**: No analytics, crash telemetry, or tracking pings are embedded in the codebase.
- **Secure Credential Storage**: Optional ElevenLabs API keys are stored securely in macOS Keychain with isolated namespaces for Personal and Dev apps.
- **Optional Cloud APIs**: ElevenLabs voiceover and music are strictly opt-in and only invoked if you explicitly provide an API key.

---

## Development Status

- **Current Version**: `v0.9.0-preview.1` (Public Preview Release Candidate)
- **Status**: Feature Frozen for Preview Hardening.

---

## Credits & Attribution

- **Upstream Project**: Based on [james-see/ltx-video-mac](https://github.com/james-see/ltx-video-mac) (MIT License, Copyright (c) 2025 James Campbell).
- **Core MLX Video**: [mlx-video-with-audio](https://pypi.org/project/mlx-video-with-audio/) and [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video).
- **Apple MLX Framework**: [Apple Machine Learning Research](https://github.com/ml-explore/mlx).
- **Model Architectures**: [Lightricks](https://www.lightricks.com/) (LTX-2 / LTX-2.3) and [Google](https://ai.google.dev/gemma) (Gemma).
- **Secondary Backend**: [dgrauet/ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx).
- **Swift-Python Bridge**: [PythonKit](https://github.com/pvieito/PythonKit) (pvieito).

---

## License & Disclaimers

- **Application Source Code**: Licensed under the **MIT License** — see [LICENSE](LICENSE).
- **Third-Party Software**: For third-party software dependencies and their licenses, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Model Weights & Terms**: Model weights are **not bundled** with this application. LTX-2.3 is provided separately by Lightricks and is subject to the applicable LTX model license. Gemma components are subject to the Gemma Terms of Use and applicable Prohibited Use Policy. Local Video Studio supports user-supplied third-party models compatible with the `ltx-2-mlx` backend; these weights are not bundled or recommended by this project and remain subject to their respective licenses and usage terms. Users are responsible for reviewing and complying with all applicable terms. See [MODEL_LICENSES.md](MODEL_LICENSES.md).
- **Independent Project**: Local Video Studio is an independent community project and is not affiliated with, sponsored by, or endorsed by Lightricks Ltd., Google LLC, or Apple Inc.
