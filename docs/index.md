---
layout: default
title: Home
nav_order: 1
description: "Local Video Studio - Native macOS app for AI video generation"
permalink: /
---

# Local Video Studio
{: .fs-9 }

Transform text and reference images into stunning AI-generated videos on your Mac.
{: .fs-6 .fw-300 }

[Install from source](installation){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }

---

## Native macOS Experience

Local Video Studio is a native macOS application built with SwiftUI. It runs LTX-2.3 and custom MLX models natively on Apple Silicon using MLX for optimal performance.

### Key Features

- **Apple Silicon Native** - Uses MLX for optimal M1/M2/M3/M4 performance
- **Supported Video Models** - LTX-2.3 Distilled Q4 (app default), LTX-2 Unified, and user-configurable custom MLX models
- **Auto Movie & Local AI Director** - Multi-shot automated story planning and character continuity
- **Text-to-Video & Image-to-Video** - Generate and animate videos from prompts or reference images
- **Voiceover & Audio** - Synchronized native audio, No-BGM suppression policy, and final BGM/Ambience mixing
- **Production Queue** - Queue multiple shots/takes and track progress in real-time
- **Video Archive & History** - Browse, preview, and manage all your generated takes
- **Orientation Presets** - Automatic landscape and portrait aspect ratio adaptivity

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

Local Video Studio is open source. Contributions, issues, and feature requests are welcome through this repository.
