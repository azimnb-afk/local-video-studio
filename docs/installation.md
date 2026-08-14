---
layout: default
title: Installation
nav_order: 2
---

# Installation Guide
{: .no_toc }

Complete setup instructions for Local Video Studio.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Download the App

1. Obtain a release published by the repository maintainer
2. Download the latest `.dmg` file or build from source
3. Open the DMG and drag **Local Video Studio** to your Applications folder
4. Open the app normally. A released DMG will be Developer ID signed and
   notarized; a `-local-test.dmg` is for the developer's own Mac only.

## Configure Python

Local Video Studio uses an external isolated Python environment. The exercised
production combination is Python 3.14.5 with `mlx-video-with-audio` 0.1.36;
the backend package requires Python 3.11 or newer.

### Step 1: Open Preferences

1. Launch **Local Video Studio**
2. Open **Preferences** (⌘,)
3. Click **Auto Detect** to find your Python installation

The app will search common locations including Homebrew, pyenv, conda, and system Python.

### Step 2: Validate Setup

Click **Validate Setup** to check the actual MLX video entry point and LTX
text-encoder imports supplied by `mlx-video-with-audio` 0.1.36. The app does
not require `torch` or `diffusers` for this backend.

### Step 3: Install Missing Packages

If packages are missing, you have two options:

**Option A: One-Click Install (Recommended)**

Click the visible **Install Missing Packages** button in Preferences. No normal
first-run or generation check runs `pip` automatically.

**Option B: Manual Install**

```bash
python3 -m pip install "mlx-video-with-audio==0.1.36"
```

{: .note }
If using a virtual environment, make sure to activate it first, or point the app to the venv's Python executable.

## First Run - Model Download

{: .warning }
**Important**: Models and encoders are external Hugging Face cache assets. Any
download is an explicit user-controlled setup action; generation readiness does
not silently begin a multi-gigabyte download.

### What to Expect

**Video model:**
1. Start a generation with any prompt
2. Progress shows "Downloading model..." with percentage
3. Download takes 30-60 minutes depending on connection speed
4. Model is cached in `~/.cache/huggingface/hub/`
5. Subsequent runs skip the download

**Text encoder:** the first-run setup screen shows an explicit **Download** button next to "Text Encoder" whenever the selected encoder isn't cached yet — this is the primary way to fetch it, rather than waiting for your first generation to trigger it. A failed download leaves your selection in place with a **Retry** button; an already-cached encoder shows as ready with no download or network access.

### Download Progress

The app shows real-time download progress:
- `Downloading: 8.4GB / 42GB (20%)`
- `Downloading: 4.0GB / 19.4GB (21%)`

If download is interrupted, it will resume from where it left off.

### Storage Location

Models are cached by Hugging Face in folders such as:
```
~/.cache/huggingface/hub/models--notapalindrome--ltx2-mlx-av/
~/.cache/huggingface/hub/models--notapalindrome--ltx23-mlx-av-q4/
~/.cache/huggingface/hub/models--notapalindrome--ltx23-mlx-av/
```

To free up space later, you can delete this folder (the model will re-download on next use).

## Optional: Prompt Enhancement

For better results, enable **Settings > Generation > Enable Gemma Prompt Enhancement**. An LLM rewrites your prompt with vivid details before generation; first run downloads ~7GB.

**Important:** this feature does not use the Gemma text encoder described above. It unconditionally uses a third-party fine-tune, [`TheCluster/amoral-gemma-3-12B-v2-mlx-4bit`](https://huggingface.co/TheCluster/amoral-gemma-3-12B-v2-mlx-4bit), whose own model card describes reduced refusal/content-filtering behavior relative to the base Gemma model. There is no in-app toggle to use the standard model for this feature instead — enabling Prompt Enhancement at all means this specific model rewrites your prompt. See the [README's disclosure](../README.md#prompt-enhancement--important-disclosure) and [MODEL_LICENSES.md](../MODEL_LICENSES.md) before enabling it.

## Verify Installation

To verify everything is working:

1. Enter a simple prompt: `"A river flowing through a forest"`
2. Use the **Quick Preview** preset (512x320, 49 frames)
3. Click **Generate**
4. Watch progress in the Queue sidebar
5. Your video should appear when complete

## Installing Python

If you don't have Python installed, here are your options:

### Homebrew (Recommended)

```bash
brew install python@3.12
```

Python will be at `/opt/homebrew/bin/python3.12`

### pyenv

```bash
# Install pyenv
brew install pyenv

# Install Python
pyenv install 3.12

# Set as default
pyenv global 3.12
```

### System Python

macOS includes Python, but you may need to install Xcode Command Line Tools:

```bash
xcode-select --install
```

## Troubleshooting

### "Python not found"
- Click **Auto Detect** in Preferences
- Or manually enter the path to your Python executable
- Verify it exists: `which python3`

### "Missing packages" after install
- Make sure you're using the same Python the app is configured to use
- Try: `/path/to/your/python3 -m pip install "mlx-video-with-audio==0.1.36"`

### "Out of memory" during generation
- Use smaller resolution (512x320)
- Reduce frame count
- Close other applications
- 32GB RAM minimum required

See the [Troubleshooting Guide](troubleshooting) for more solutions.
