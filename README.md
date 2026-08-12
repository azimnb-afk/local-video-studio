# LTX Video Generator for Mac

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2FM2%2FM3%2FM4-orange.svg)](https://support.apple.com/en-us/HT211814)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A native macOS application for AI video generation on Apple Silicon. It drives the LTX-2 model family through [MLX](https://github.com/ml-explore/mlx) via a local Python backend (`mlx-video-with-audio`), and adds a full production layer on top: multi-shot Storyboard and Auto Movie planning, shot continuity, character consistency tracking, a generation queue, and optional audio (built-in, local TTS, or cloud TTS/music).

**Software license vs. model license — these are different things.** The MIT license in this repository covers the Swift/Python source code in this repository only. It does **not** cover the LTX-2 video weights, the Gemma text-encoder weights, or any other model you download separately from Hugging Face. See [Licensing](#licensing) below and [MODEL_LICENSES.md](MODEL_LICENSES.md) before you rely on this project for anything beyond personal experimentation.

**This app is not fully offline.** Generation itself runs locally, but first-run model downloads pull several GB–tens of GB from Hugging Face, Python package installation needs network access, and two *optional* audio features call a cloud API. See [Local vs. Cloud](#local-vs-cloud) below.

## What It Is

LTX Video Generator is a SwiftUI front end that shells out to a Python subprocess (`mlx-video-with-audio`) to run LTX-2 video generation models on-device via MLX. On top of that base generation call, it adds:

- A production/workflow layer (Storyboard, Auto Movie, shot queue, History)
- Continuity between shots via image conditioning (see [Shot Continuity](#shot-continuity-last-frame-i2v))
- Character-consistency tracking between an opening reference image and later shots (see [Character Consistency](#character-consistency-opening-reference--character-sheet))
- Optional prompt rewriting, voiceover, and background music

It is not a hosted service — there is no LTX Video Generator backend server. Every video-generation call runs as a local subprocess on your Mac; the only network calls are model/package downloads and the two explicitly-optional cloud audio features.

## Key Features

- **Native macOS App** — SwiftUI, Apple Silicon native via MLX
- **Text-to-Video and Image-to-Video** — generate from a prompt, or animate a source image
- **Built-in Audio** — the official models generate synchronized audio with the video automatically
- **Director / Auto Movie** — describe a longer narrative and get an auto-planned multi-shot sequence; you can preview and edit the generated shot plan (prompts and continuity) before generating
- **Storyboard** — build a multi-shot project shot-by-shot, with manual control over each shot's prompt and source image
- **Shot Continuity (Last Frame I2V)** — carries the previous shot's last frame forward as the next shot's conditioning image (see below — this is not motion or audio continuation)
- **Character Consistency tracking** — compares an opening reference / character sheet against later shots and reports a match/partial/conflict/unknown verdict per attribute; this is a diagnostic indicator, not an enforced guarantee (see below)
- **Selected Take workflow** — generate multiple takes per shot, mark one as the take used going forward; the selected take (not simply the most recent one) is what downstream continuity and final assembly use
- **Production Queue** — queue multiple shots/generations with real-time progress
- **Generation & Runtime Diagnostics** — surfaces which backend path, model, and runtime state a generation actually used, for troubleshooting
- **Final Assembly** — concatenates a project's shots into one output video via `ffmpeg` (see [Requirements](#requirements) — `ffmpeg` is not bundled)
- **History** — browse, preview, and manage generated videos and takes
- **Presets & Parameters** — resolution, frame count, steps, guidance scale, seed, VAE tiling, and saved presets
- **Optional Prompt Enhancement** — off by default; see [Prompt Enhancement](#prompt-enhancement--important-disclosure) — read this before enabling it
- **Optional Voiceover** — MLX-Audio (local) or ElevenLabs (cloud, requires your own API key)
- **Optional Background Music** — ElevenLabs Music API (cloud, requires your own API key), 54 genre presets
- **Add Audio to Existing Videos** — attach voiceover/music to a previously generated video from History

## Requirements

| Requirement | Supported | Tested in this repository |
|:---|:---|:---|
| macOS | 14.0 or later | — |
| Processor | Apple Silicon (M1 or later) | — |
| Python | 3.11 or later (required by `mlx-video-with-audio`) | 3.14.5 (the version this codebase's Python integration was exercised against) |
| `ffmpeg` / `ffprobe` | Required for Final Assembly, shot-continuity frame extraction, and media duration probing. **Not bundled** — install separately (e.g. `brew install ffmpeg`). The app looks for it at `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`. | — |
| Unified memory | See the per-model table below | — |
| Disk space | 20–50GB per video model, plus 7–24GB for the text encoder, in `~/.cache/huggingface/` | — |

"Supported" is what the code targets or requires; "Tested" is what has actually been run against this codebase. Where a row has no "Tested" entry, treat "Supported" as the vendor/package's own stated requirement, not an independent benchmark by this project.

### Memory by model

The application declares its own per-model minimum/recommended unified-memory figures (from the model registry in source); these are the app's own stated guidance, not independently re-benchmarked for this documentation pass. Actual usage also depends on your chosen text encoder, resolution, and frame count.

| Model | Minimum | Recommended |
|:---|:---|:---|
| LTX-2.3 Distilled Q4 (default) | 32GB | 32GB |
| LTX-2 Unified | 48GB | 64GB |
| LTX-2.3 Unified (Beta) | 48GB | 64GB |

Add roughly 7–24GB more if you use a larger text-encoder preset (see [Text Encoders](#text-encoders) below) — the encoder and video model are both resident in memory during generation.

## Installation

### 1. Get the App

Obtain a release built by the repository maintainer, or build from source (see [Building from Source](#building-from-source)).

### 2. Configure Python

1. Open **LTX Video Generator** → **Preferences** (⌘,)
2. Click **Auto Detect** to locate a Python 3.11+ installation (Homebrew, pyenv, conda, and system Python are searched), or set the path manually
3. Click **Validate Setup** — this checks, in a subprocess, that the configured Python can import the `mlx_video` entry point and LTX text-encoder module that `mlx-video-with-audio` provides. It does not check for `torch`, `diffusers`, or other transitive dependencies of that package; those are that package's own concern.

### 3. Install the Python Backend

If **Validate Setup** reports missing packages, either:

- Click **Install Missing Packages** in Preferences (runs `pip` for you), or
- Install manually:

```bash
python3 -m pip install "mlx-video-with-audio==0.1.36"
```

The app's own minimum pinned version is `0.1.36`. No normal first-run or generation check runs `pip` automatically — installation is always an explicit, visible user action.

### 4. Install ffmpeg

```bash
brew install ffmpeg
```

Required for Final Assembly (combining shots into one video), shot-continuity frame extraction, and media probing. Not required for a single-shot generation with no audio post-processing.

### 5. First Generation — Model Download

The first generation with a given model downloads it from Hugging Face into `~/.cache/huggingface/hub/`. This is a one-time, explicit download triggered by starting a generation — the app does not download models in the background. Expect roughly 20–50 minutes depending on the model and your connection; progress is shown in the app, and an interrupted download resumes.

**Official video models** (all include built-in synchronized audio):

| Model | Repository | Approx. size | Default |
|:---|:---|:---|:---|
| LTX-2.3 Distilled Q4 (Beta) | [`notapalindrome/ltx23-mlx-av-q4`](https://huggingface.co/notapalindrome/ltx23-mlx-av-q4) | ~22GB | Yes |
| LTX-2 Unified | [`notapalindrome/ltx2-mlx-av`](https://huggingface.co/notapalindrome/ltx2-mlx-av) | ~42GB | No |
| LTX-2.3 Unified (Beta) | [`notapalindrome/ltx23-mlx-av`](https://huggingface.co/notapalindrome/ltx23-mlx-av) | ~48GB | No |

"Beta" reflects the upstream/community status of those checkpoints, not a stability guarantee from this project. See [MODEL_LICENSES.md](MODEL_LICENSES.md) — the license status of these three specific repositories is not uniformly resolved; check it before relying on them beyond personal use.

### Text Encoders

Independent of the video model, you choose a text encoder that turns your prompt into embeddings:

| Preset | Repository | Approx. size | Notes |
|:---|:---|:---|:---|
| Gemma 12B bf16 (default) | `mlx-community/gemma-3-12b-it-bf16` | ~24GB | Highest quality |
| Gemma 4B bf16 | `mlx-community/gemma-3-4b-it-bf16` | ~10GB | Balanced |
| Gemma 12B 4-bit | `mlx-community/gemma-3-12b-it-4bit` | ~7GB | Lowest RAM among the presets |
| Custom | user-specified Hugging Face repo | varies | Advanced use |

These are the standard, unmodified Gemma models under Google's Gemma license — do not confuse this with the optional prompt-enhancement model described next, which is a different, third-party model.

## Prompt Enhancement — Important Disclosure

The app has an **optional, off-by-default** "Enable Gemma Prompt Enhancement" toggle (Settings → Generation). When you enable it, an LLM rewrites your prompt into a more detailed, LTX-optimized version before generation, and you can preview the rewrite before committing to it. If enhancement fails for any reason, generation automatically falls back to your original prompt.

**Read this before enabling it:** the prompt-enhancement feature does not use the Gemma text-encoder model above. It unconditionally uses a specific third-party fine-tune, [`TheCluster/amoral-gemma-3-12B-v2-mlx-4bit`](https://huggingface.co/TheCluster/amoral-gemma-3-12B-v2-mlx-4bit) (~7GB first-run download), whose own model card describes it as a variant of Gemma 3 12B with reduced refusal/content-filtering behavior relative to the base instruction-tuned model. There is currently no in-app toggle to use the standard Gemma model for this feature instead — enabling prompt enhancement at all means this specific model is what rewrites your prompt. See [Known Limitations](#known-limitations) and [MODEL_LICENSES.md](MODEL_LICENSES.md).

This is disclosed here so you can make an informed decision before enabling the feature — it is not necessary for core text-to-video or image-to-video generation, which uses only the text encoder selected above.

## Usage

1. Enter a prompt (or build a multi-shot project via Storyboard/Auto Movie)
2. Choose a preset or set parameters manually
3. Click **Generate** (or **Add to Queue**)
4. Watch progress in the Queue sidebar
5. Find results in History, or your configured output directory (default: Application Support)

For copy-paste-ready prompt examples, see [EXAMPLES.md](EXAMPLES.md). For a full walkthrough, see [docs/usage.md](docs/usage.md).

### Shot Continuity (Last Frame I2V)

When a multi-shot project (Storyboard or Auto Movie) generates shot *N+1*, the app extracts the **last frame** of shot *N*'s selected take and uses it as the **conditioning starting image** for shot *N+1* (an image-to-video conditioning bridge), with a continuity-strength value chosen automatically based on how much the scene changes between shots.

This is the current, official continuity mechanism. It is a still-image handoff between shots, not motion carried forward and not audio carried forward — each shot's audio (if any) is independent. Do not read this as "video-tail continuation" or "motion context" between shots.

### Character Consistency (Opening Reference / Character Sheet)

For hybrid/character-driven projects, you can set an **Opening Reference** image (and optionally a **Character Sheet**) that establishes a character's appearance. As later shots are planned or generated, the app compares extracted attributes (clothing, accessories, notable features) against the reference and shows a verdict per shot: match, partial, conflict, or unknown.

This is a diagnostic aid, not an enforced constraint on the model — the underlying video model is not guaranteed to reproduce a character identically across shots, and the comparison itself can report `unknown` when an attribute can't be confidently extracted. Do not read "match" as a guarantee of pixel- or identity-level consistency.

## Local vs. Cloud

| Capability | Local or Cloud | Notes |
|:---|:---|:---|
| Video generation (LTX-2 via MLX) | Local | Runs as a subprocess on your Mac; no video/prompt data leaves your machine for this step |
| Prompt Enhancement | Local | Runs a local MLX model subprocess (see disclosure above) |
| Voiceover — MLX-Audio | Local | Free, no API key |
| Voiceover — ElevenLabs | **Cloud, optional** | Requires your own ElevenLabs API key; your narration text and generated audio go to ElevenLabs' API |
| Background Music | **Cloud, optional** | Requires your own ElevenLabs API key; uses the ElevenLabs Music API |
| Model / package downloads | Network, one-time | Hugging Face Hub and PyPI; explicit user-triggered action, not background telemetry |

The ElevenLabs API key is currently stored in `UserDefaults` (not macOS Keychain). It is user-provided, optional, and not required for local generation, but this storage mechanism is a known hardening gap — see [Known Limitations](#known-limitations).

## Known Limitations

- **Character/identity consistency is not guaranteed.** The Character Consistency indicator is evaluative and can be wrong or `unknown`; it does not constrain what the underlying model actually generates.
- **Shot continuity is Last-Frame I2V, not motion or audio continuation.** Each shot's motion and audio are independent of neighboring shots.
- **Prompt Enhancement uses a third-party "reduced-filtering" model unconditionally when enabled**, not the standard Gemma text encoder. See [above](#prompt-enhancement--important-disclosure).
- **The ElevenLabs API key is stored in UserDefaults, not Keychain.** SHOULD FIX before a hardened distribution release — see [docs/public-readiness/PUBLIC_READINESS_AUDIT.md](docs/public-readiness/PUBLIC_READINESS_AUDIT.md).
- **`ffmpeg` is a separate, user-installed dependency** (not bundled); Final Assembly and continuity frame extraction do not work without it.
- **Two of the three official video-model Hugging Face repositories have no declared license/model card**, and the third's license tag conflicts with its own model-card text. See [MODEL_LICENSES.md](MODEL_LICENSES.md) — do not assume these weights are MIT-licensed.
- **Optional "lab" models (10Eros) and MiniMax H3 are not supported or verified by this project.** The 10Eros models exist behind an explicit, off-by-default Adult Content Mode toggle plus a disabled-by-default feature flag; they are marked `unverified` compatibility in the app's own model registry. MiniMax H3 is not integrated or supported by this app at all.
- **RAM figures are the app's own declared minimum/recommended values**, not independently benchmarked across the full parameter space (resolution, frame count, text encoder) in this documentation pass.

## Building from Source

```bash
# Clone the repository
git clone <PUBLIC_REPOSITORY_URL>
cd ltx-video-mac

# Open in Xcode and build/run normally (⌘R), or build unsigned from the CLI:
cd LTXVideoGenerator
xcodebuild -project LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`scripts/build-local.sh` and `scripts/build-release.sh` are **maintainer-only distribution packaging scripts** — they sign, notarize, and package a DMG, and require your own Apple Developer ID credentials (`CODE_SIGN_IDENTITY`, `APPLE_TEAM_ID`, a notary profile). They are not a plain local dev build; use the `xcodebuild` command above for that.

### Running the test suite

The root `Package.swift` defines an SPM-only test harness (the Xcode project remains the canonical `.app` build):

```bash
swift build
swift run LTXTests
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for the generation pipeline, model internals, and Python/Swift boundary. In short: SwiftUI app → subprocess → `mlx-video-with-audio` (Python, MLX) → LTX-2 transformer + VAE + vocoder → `ffmpeg` mux for any post-processing.

## Licensing

- **This repository's source code** (Swift, Python glue scripts, build scripts) is MIT-licensed — see [LICENSE](LICENSE).
- **Model weights are not covered by that license.** Every model you download (video models, text encoders, the prompt-enhancement model) is a separate work with its own license, governed by its own upstream terms — see [MODEL_LICENSES.md](MODEL_LICENSES.md) for what is and isn't currently verified.
- **Third-party software** this app depends on or bundles has its own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This codebase originated as a fork of [james-see/ltx-video-mac](https://github.com/james-see/ltx-video-mac) and has been substantially extended since.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md). Common starting points:

- **"Python not found"** — `brew install python@3.12` (or use pyenv), then **Auto Detect** in Preferences.
- **"Missing packages"** — `python3 -m pip install "mlx-video-with-audio==0.1.36"` to the same Python the app is configured to use.
- **Out of memory** — use a smaller resolution/frame count, 24 FPS, aggressive VAE tiling, and close other apps; see the per-model memory table above.

## Acknowledgments

- [Lightricks](https://www.lightricks.com/) for the original LTX-2 model
- [mlx-video-with-audio](https://pypi.org/project/mlx-video-with-audio/) for the unified audio-video MLX generation backend
- [MLX Community](https://huggingface.co/mlx-community) for MLX-converted weights
- [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video) for the original MLX video generation code
- [PythonKit](https://github.com/pvieito/PythonKit) for the Swift↔Python bridge
- [Hugging Face](https://huggingface.co/) for model hosting

## License

MIT License — see [LICENSE](LICENSE) for the full text. This covers the source code in this repository; see [Licensing](#licensing) above for model weights and third-party software.
