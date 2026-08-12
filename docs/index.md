---
layout: default
title: Home
nav_order: 1
description: "LTX Video Generator - Native macOS app for AI video generation"
permalink: /
---

# LTX Video Generator
{: .fs-9 }

Transform text into stunning AI-generated videos on your Mac.
{: .fs-6 .fw-300 }

[Install from source](installation){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }

---

## Native macOS Experience

LTX Video Generator is a beautiful, native macOS application built with SwiftUI. It runs the LTX-2 model natively on Apple Silicon using MLX (Apple's machine learning framework) for optimal performance.

### Key Features

- **Apple Silicon Native** - Uses MLX for optimal M1/M2/M3/M4 performance
- **Three LTX-2 Models** - LTX-2 Unified (~42GB), LTX-2.3 Unified Beta (~48GB), and LTX-2.3 Distilled Q4 Beta (~22GB, app default), all with built-in audio
- **Text-to-Video** - Generate videos from text descriptions
- **Image-to-Video** - Animate images into videos
- **Optional Prompt Enhancement** - Off by default; when enabled, unconditionally uses a third-party fine-tuned model chosen for reduced content-filtering behavior, not the standard text encoder — [read the disclosure](../README.md#prompt-enhancement--important-disclosure) before enabling it
- **Voiceover Narration** - Add TTS audio using ElevenLabs (cloud) or MLX-Audio (local)
- **Background Music** - 54 genre presets for AI-generated instrumental music via ElevenLabs
- **Auto Package Installer** - Missing Python packages detected and installed with one click
- **Generation Queue** - Queue multiple videos and track progress in real-time
- **Smart History** - Browse, preview, and manage all your generated videos
- **Flexible Presets** - Quick access to common configurations or customize every parameter

## Quick Start

1. **Build or obtain** a release from the repository maintainer
2. **Open Preferences** and click Auto Detect to find Python
3. **Install packages** if prompted (one-click install available)
4. **Generate** your first video! (model downloads on first run)

## System Requirements

| Requirement | Minimum | Recommended |
|:------------|:--------|:------------|
| macOS | 14.0+ | 15.0+ |
| Processor | Apple M1 | Apple M2 Pro/M3/M4 |
| Unified Memory | 32GB (app-default model) / 48GB (larger models) | 64GB+ |
| Storage | 100GB free | 150GB+ free |
| Python | 3.11+ | 3.11+ (3.14.5 exercised) |

{: .warning }
**First Run Download**: The LTX-2 Unified model (~42GB) downloads automatically on first generation. This is a one-time download cached in `~/.cache/huggingface/`.

## Sample Results

Generate videos like:
- "A river flowing through a misty forest at dawn"
- "The camera slowly pans across a futuristic cityscape"  
- "Golden leaves falling in slow motion against a blue sky"

---

## Getting Help

- [Installation Guide](installation) - Complete setup instructions
- [Usage Guide](usage) - Learn how to get the best results
- [Parameters Reference](parameters) - Understand all settings
- [Troubleshooting](troubleshooting) - Common issues and solutions
- [Architecture](architecture) - Technical details of the pipeline and models

## Contributing

LTX Video Generator is open source. Contributions, issues, and feature requests are welcome through this repository.
