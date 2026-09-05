# Local Video Studio for Mac

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-orange.svg)](https://support.apple.com/en-us/HT211814)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/badge/Release-v0.9.0--preview.18-purple.svg)](RELEASE_NOTES_v0.9.0-preview.18.md)

**Create longer AI video sequences locally on Apple Silicon.**

ハイスペックなGPU PCなしで、Apple Silicon Mac上で長いAI動画シーケンスを手軽にローカル生成。
Auto Movieのshot-to-shot continuityとローカルモデルの自由度を活用して、連続した映像作品を制作できます。

> **Independent Project Disclaimer**: Local Video Studio is an independent open-source community project and is not affiliated with, sponsored by, or endorsed by Lightricks Ltd., Google LLC, or Apple Inc.
>
> **Software License vs. Model Licenses**: The MIT license in this repository covers the Swift and Python application source code only. **No model weights are bundled in this repository or source release.** LTX-2.3, Gemma text encoders, and user-supplied third-party models are separate works downloaded independently by the user from Hugging Face and remain subject to their respective licenses and usage terms. See [MODEL_LICENSES.md](MODEL_LICENSES.md) and [License](#license).

---

## What It Does

Local Video Studio for Mac is a native desktop studio designed for on-device AI video generation powered by Apple Silicon (MLX). It enables creators to produce **longer, more consistent multi-shot video sequences** without needing a high-end discrete GPU PC or paying for cloud generation APIs.

Rather than trying to generate an entire film in a single unwieldy diffusion pass, Local Video Studio uses an **Auto Movie workflow**: it plans a sequence of connected shots, renders each shot locally, and automatically passes the **final frame of the previous shot** as the starting visual anchor for the next shot. This builds longer video sequences while significantly improving visual continuity across takes.

Runs local generation on Apple Silicon unified memory with no required cloud generation API.

---

## Key Pillars

1. **Longer Video Sequences**: Generate connected multi-shot stories sequentially via Auto Movie instead of being limited to isolated few-second clips.
2. **Visual Continuity**: Automatically conditions each new shot on the final frame of the previous selected take to help reduce visual drift across the sequence.
3. **Local Freedom**: Run on Apple Silicon unified memory with no cloud generation fees, complete data privacy, and full freedom to bring compatible local models.

---

## Features

- **Native macOS Interface**: Built in SwiftUI with native performance, real-time generation previews, and background job queuing.
- **Auto Movie Shot-to-Shot Continuity**: Creates connected multi-shot sequences where each new shot continues directly from the previous shot's final frame to improve visual consistency.
- **Local AI Director Planning**: Connects to local LLM providers (Ollama / Local AI) with dual-protocol negotiation (Structured JSON + Text Protocol fallback) and live phase/elapsed-time progress tracking.
- **Safe Generation & Planning Cancellation**: Sub-second cancellation for both running generation processes and Director planning tasks, safely advancing queued jobs.
- **Storage Health Preflight Guards**: Automatically checks destination volume capacity before generation, model downloads, or final assembly to reduce storage-related failures.
- **Storyboard Workflow**: Build multi-shot films shot-by-shot with full manual control over prompts, takes, and camera direction.
- **Compatible Local Model Freedom**: Run official supported models (LTX-2.3 Distilled Q4 / Unified), user-configured custom LTX-2 MLX models, or existing local model folders directly without redownloading.
- **Selected Take Precedence**: Generate multiple takes per shot and mark your preferred version for downstream continuity and Final Assembly.
- **Source Orientation Presets**: Automatically adapts generation resolutions (16:9 landscape vs 9:16 portrait) based on input source image aspect ratios.
- **Motion Tempo Control**: Contextual motion pacing instructions preserved across multi-shot sequences.
- **Multilingual Input & Strict English Render Prompts**:
  - **Original Brief vs. Render Prompt**: Preserves original user language in project briefs while ensuring descriptive render prompts are clean, renderer-safe English.
  - **Apple On-Device Translation**: Translates non-English descriptions locally on macOS without cloud APIs or network calls.
  - **Dialogue Separation**: Retains user dialogue verbatim in its original language.
  - **Fail-Closed Safety**: Rejects un-translatable descriptive non-English text to prevent renderer hallucination.
- **Enhanced Prompt Sanitizer**: Strips chat-template special tokens (`<end_of_turn>`, `<|eot_id|>`, `</s>`, etc.) and constrains local LLM semantic over-expansion.
- **Immutable Queued Snapshots**: Freezes model configurations into queued generation jobs, ensuring queue items execute with their original model even if UI selections change.
- **Integrated Audio Pipeline**:
  - **Native Synchronized Audio**: Per-shot natural sound effects generated directly by the underlying model.
  - **No-BGM Policy v2**: Prompt-level suppression of unwanted background music to keep speech/SFX clean.
  - **Final Audio Layer**: Global BGM and Ambience track mixing via local `ffmpeg`.
- **Production Queue**: Asynchronous background generation queue with take management, cancellation, and retry capabilities.
- **Video Archive & History**: Centralized library to inspect, play back, export, and manage generated takes and project assemblies.

---

## Supported Models

| Model | Architecture | Backend | Status | Target Hardware |
|:---|:---|:---|:---|:---|
| **LTX-2.3 Distilled Q4** (Default) | LTX-2.3 AV | `mlx-video-with-audio` | Supported (Official) | 32 GB+ Unified Memory |
| **LTX-2 Unified** | LTX-2 AV | `mlx-video-with-audio` | Supported (Official) | 48–64 GB Unified Memory |
| **LTX-2.3 Unified** | LTX-2.3 AV | `mlx-video-with-audio` | Supported (Beta) | 48–64 GB Unified Memory |
| **Custom LTX-2 MLX Model** | LTX-2 Derived | `ltx-2-mlx` | Supported (User-Configurable) | 24–32 GB Unified Memory |
| **LTX-2.5 (Experimental)** | LTX-2.5 GGUF (Distilled) | `ltx-2-mlx` (app-managed runtime) | Experimental | 32 GB+ Unified Memory |

*Note: Custom LTX-2 MLX models can be configured in Preferences > Models & Features and run via the isolated `ltx-2-mlx` backend using either Hugging Face repositories or existing local directories.*

*LTX-2.5 is experimental and may currently be significantly slower to generate than LTX-2.3. LTX-2.3 remains the stable, default model for everyday use. See [LTX-2.5 Experimental Setup](#ltx-25-experimental-setup) below.*

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
3. Click **Generate** to create a single-shot video clip.

### 4. Try One Shot
1. Switch to **One Shot**.
2. Select an image, choose a motion tempo and camera direction, and click **Plan & Generate**. Multilingual briefs are automatically translated to clean English render prompts on-device.

### 5. Create an Auto Movie
1. Switch to **Auto Movie**.
2. Set an **Opening Reference image** and enter a brief narrative (e.g., "A detective investigates an abandoned train platform in the rain").
3. Click **Plan Movie** to review the Local AI Director's shot beats.
4. Click **Generate Movie** to render shots sequentially to the Production Queue with automatic shot-to-shot visual continuity.

---

## LTX-2.5 Experimental Setup

LTX-2.5 support is **experimental** and off the stable path by default. LTX-2.3 remains the recommended model for everyday use — try LTX-2.5 once your Python setup above is working.

The runtime (the isolated Python environment that runs the model) and the model weights (the GGUF file you generate from) are two separate things you set up independently:

1. Open **Preferences** (⌘,) → **Models & Features**.
2. Under the LTX-2.5 section, click **Install Runtime**. This creates an isolated, app-managed Python environment just for LTX-2.5 — it does not touch your Python setup from step 2 above. Installation is explicit; the app never downloads it silently.
3. Once the runtime shows **Ready**, add an **LTX-2.5 Custom Model Profile** pointing at a folder containing both an LTX-2.5 Distilled GGUF file (for example, from a `Distilled-GGUF` folder downloaded from Hugging Face) **and** a Video VAE decoder file (`vae_decoder.safetensors`, or the official combined VAE file matching `*video-vae-conv*`) placed directly in the same folder. The GGUF file alone is not enough — video output requires the Video VAE decoder, and the app will report the profile as not ready until it is present. You can save up to 5 model profiles.
4. Select **LTX-2.5 (Experimental)** as the model on the Generate, One Shot, Auto Movie, or Storyboard screen and generate as usual.
5. Runtime and model status are shown separately in Models & Features (**Runtime Not Installed / Ready / Update Required / Broken**, and per-profile model readiness), so you can tell which one needs attention if generation is blocked.

LTX-2.5 may currently be significantly slower to generate than LTX-2.3, and its GGUF files are large — an internal SSD with sufficient free space is recommended.

---

## Auto Movie Workflow

Auto Movie is designed to build **one continuous, connected sequence**:

1. **Opening Reference Grounding**: Drop a starting image (or use prompt-only mode). The first shot begins from this visual state.
2. **Director Beat Planning**: The Local AI Director breaks the story into sequential beats. Live progress shows current planning phase and elapsed time.
3. **Sequential Shot-to-Shot Continuity**:
   - **Shot 1**: Synthesizes the opening scene from your prompt or opening reference still.
   - **Shot 2+**: Automatically extracts the **actual final frame** from the preceding selected take and uses it as the starting visual anchor for the next shot.
4. **Final Assembly**: Automatically concatenates selected takes into a single movie file with audio crossfades via `ffmpeg`.

*Note: For scenes requiring large camera resets, location jumps, or different environments, create separate Auto Movie or One Shot projects and combine them in your preferred video editor.*

---

## Director Modes

- **Auto**: Automatically selects the best available director provider.
- **Local AI**: Connects to localhost Ollama (`qwen3.6`, `gemma3`, `llama3`, `qwen2.5`). Employs Structured JSON with automatic Text Protocol negotiation, live progress tracking, and safe cancellation.
- **Basic (Deterministic)**: Template-based director with Apple on-device translation ensuring reliable shot planning without requiring an external LLM server.

---

## Generation Workflows

- **Direct Generate**: Rapid single-prompt text-to-video or image-to-video generation.
- **One Shot**: Guided single-scene generation with camera motion and style presets.
- **Storyboard**: Granular multi-shot project builder with manual prompt editing, take branching, and individual shot regeneration.
- **Auto Movie**: Automated narrative shot planning, sequential previous-frame continuity, and batch rendering into a complete sequence.

---

## Model Setup

Models are managed transparently:
- **Video Weights**: Downloaded on first generation into `~/.cache/huggingface/hub/`. Downloads can be paused and resumed.
- **Text Encoders**: Selected in Preferences (Default: `Gemma 12B bf16` / `Gemma 4B bf16` / `Gemma 12B 4-bit`). Explicit **Download** button in the UI ensures the text encoder is cached before generation starts.
- **Custom Local Models**: Configure existing local weights directly via folder selection in Preferences > Models & Features > Custom LTX-2 MLX Model.
- **No Background Telemetry**: Models are fetched directly from official Hugging Face repositories only upon explicit user action.

---

## Production Queue

All generation requests are dispatched to a resilient background queue:
- **Immutable Job Snapshots**: Every queued request retains its frozen model ID and custom path, even if you switch the active model in the UI during rendering.
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

- **Visual Continuity is Model-Dependent**: Strict previous-frame conditioning anchors each shot's opening image to the previous take's final frame to reduce visual drift, but diffusion models do not provide deterministic biometric identity locking.
- **Continuous Sequence Focus**: Auto Movie is designed to build a single continuous sequence. Strong previous-frame conditioning can make large camera/scene transitions harder within one Auto Movie sequence. For distinct scenes or location jumps, create separate sequences and combine them in a video editor.
- **Storage Preflight Scope**: Storage preflight checks help reduce storage-related failures before generation, model downloads, or assembly start. However, external applications writing to the same disk can still affect available capacity during long rendering runs.
- **No-BGM is Best-Effort with Built-in Audio**: Negative prompting strongly suppresses BGM in the prompt plumbing, but acoustic output is model-dependent and music suppression cannot be guaranteed by the diffusion weights. For guaranteed music-free output, turn **Built-in Audio OFF** and use **Final Audio** or external diegetic audio tracks.
- **Apple On-Device Translation Availability**: Native programmatic platform translation requires supported macOS versions (macOS 26.0+); on unsupported or earlier macOS releases, non-English descriptive inputs fail-closed safely rather than leaking raw Japanese to the renderer.
- **External Dependency**: `ffmpeg` is required for multi-shot assembly and frame extraction and must be installed separately by the user (`brew install ffmpeg`).
- **Hardware & Memory Requirements**: Local video synthesis fully utilizes GPU and unified memory. Performance and available model options vary depending on your Mac's hardware configuration and memory size.

---

## Privacy & Local-First Architecture

- **Local-First Processing**: Video generation, text embedding, Local Director LLM, Apple on-device translation, and final movie assembly execute locally on your Mac with no required cloud generation API.
- **Zero Telemetry**: No analytics, crash telemetry, or tracking pings are embedded in the codebase.
- **Secure Credential Storage**: Optional ElevenLabs API keys are stored securely in macOS Keychain with isolated namespaces for Personal and Dev apps.
- **Optional Cloud APIs**: ElevenLabs voiceover and music are strictly opt-in and only invoked if you explicitly provide an API key.

---

## Development Status

- **Current Version**: `v0.9.0-preview.18` (Public Preview)
- **Branch**: `director-extensions`

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
