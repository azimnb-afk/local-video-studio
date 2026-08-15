# v0.9.0-preview.3 — Third Public Preview Release Candidate

Local Video Studio for Mac — AutoMovie Edition `v0.9.0-preview.3` focuses on enabling creators to produce **longer, more consistent AI video sequences locally on Apple Silicon Macs** without requiring high-end discrete GPU PCs or cloud generation subscriptions.

---

## Key Highlights

### 🎬 1. Auto Movie — Shot-to-Shot Visual Continuity
- **Sequential Last-Frame Conditioning**: Auto Movie builds longer video sequences shot by shot. Each new shot (Shot 2+) automatically continues from the actual final frame of the preceding selected take, helping reduce visual drift across multi-shot sequences.
- **Continuous Sequence Focus**: Designed to synthesize one continuous, connected sequence with consistent character appearance, lighting, and wardrobe.

### 🛑 2. Safe Generation Cancellation
- **Sub-Second Job Abort**: Running video generations can now be cancelled safely and immediately from the Production Queue.
- **Clean Process Tracking**: Ensures no orphaned Python subprocesses remain running in the background, allowing queued jobs to advance smoothly.

### ⏱️ 3. Director Planning Live Progress & Safe Cancellation
- **Real-Time Phase & Elapsed Time**: Inspect the Local AI Director's progress through preparing, planning, parsing, and applying phases with live elapsed-time tracking.
- **Instant Abort**: Sub-second cancellation for deep reasoning models (e.g. 35B+ local LLMs via Ollama) without waiting for timeouts or triggering unwanted fallback providers.

### 🛡️ 4. Storage Health Preflight Guards
- **Target Volume Preflight**: Automatically verifies available disk capacity on target write destinations (Videos directory, Hugging Face model cache, temporary assembly workspace) before heavy operations begin.
- **Failure Risk Reduction**: Prevents out-of-disk failures during video generation, large model downloads, and final movie assembly while preserving all user data and project history without automatic deletion.

### 📊 5. Clearer Standard & High Quality Preset Summaries
- **Transparent Generation Settings**: Preset summaries clearly display exact inference step counts and clip durations across One Shot, Storyboard, and Auto Movie workflows.

### 🗂️ 6. Compatible Local Model Freedom
- **Bring Your Own Local Model**: Seamlessly run official supported models (LTX-2.3 Distilled Q4 / Unified), user-configured custom LTX-2 MLX models, or direct local weight folders without redownloading.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later (Apple On-Device Translation programmatic session requires macOS 26.0+)
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew: `brew install ffmpeg`)

---

## Known Limitations

1. **Visual Continuity is Model-Dependent**: Last-frame conditioning significantly anchors visual flow, but underlying diffusion models do not provide deterministic biometric identity locking.
2. **Continuous Sequence Focus**: Auto Movie is designed for single continuous sequences. Strong previous-frame conditioning can make large camera resets or location jumps harder within one sequence. For distinct scenes, create separate Auto Movie or One Shot projects and combine them in an external video editor.
3. **Storage Preflight Scope**: Storage preflight checks help reduce storage-related failures before generation, model downloads, or assembly start. However, external applications writing to the same disk can still affect available capacity during long rendering runs.
4. **No-BGM Policy is Best-Effort with Built-in Audio**: Prompt negative constraints suppress music, but acoustic output cannot be 100% guaranteed by diffusion weights alone. For guaranteed music-free output, turn **Built-in Audio OFF** and use **Final Audio** mixing.

---

## Deferred Features (Preview.4+ Backlog)

The following capabilities are reserved for future preview releases:
- Cinematic Assembly Transitions (crossfades, dip-to-black, wipes)
- Character Sheet Visual Reference & Vision Grounding
- Persistent Identity Anchoring across separate scenes
- Explicit Scene Break / Camera Reset within Auto Movie
- LTX-2.5 & MiniMax H3 backend integrations
