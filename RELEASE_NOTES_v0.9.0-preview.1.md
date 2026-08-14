# v0.9.0-preview.1 — First Public Preview

Local Video Studio for Mac — AutoMovie Edition `v0.9.0-preview.1` is the first public preview release candidate. It delivers an on-device AI filmmaking studio for Apple Silicon Macs, combining LTX-2.3 and custom MLX video diffusion with automated shot planning, character continuity, and production queue management.

---

## Key Highlights

### 🎬 Auto Movie & Local AI Director
- **Automated Multi-Shot Planning**: Transforms brief narrative prompts and single reference images into cohesive multi-beat cinematic sequences.
- **On-Device LLM Integration**: Connects seamlessly with local Ollama instances (`gemma3`, `llama3`, `qwen2.5`) with structured JSON protocol negotiation.
- **Deterministic Basic Fallback**: Rule-based director ensures reliable script generation even without an active LLM provider.

### 🖼️ Opening Reference & Scene Grounding
- **Visual Evidence Extraction**: Automatically observes environment, lighting, subject state, visible clothing, and key objects from the starting reference image to ground subsequent shots.
- **Character Consistency Tracking**: Evaluates costume and appearance consistency across multi-shot takes.

### 🔗 Shot Continuity & Pacing
- **Adaptive Last-Frame I2V**: Seamlessly carries the previous shot's final frame forward as conditioning for action continuation (`CONTINUE` vs `CUT`).
- **Motion Tempo v1**: Preserves narrative motion dynamics (slow, moderate, high tempo) consistently across sequential shots.
- **Target Total Duration**: Automatically plans shot counts and frame durations to match user-specified movie length targets.

### 📐 Source-Aware Orientation Presets
- **Aspect Ratio Detection**: Automatically detects landscape vs portrait source images and sets resolution presets (e.g. 768x512 landscape, 512x768 portrait) accordingly.

### 🎵 Enhanced Audio Pipeline
- **Synchronized Audio Synthesis**: Direct generation of synchronized natural sound effects matching video motion.
- **No-BGM Policy v2**: Prompt-level suppression of unwanted background music to keep dialogue and environmental SFX clean.
- **Final Audio Layer**: Mix custom BGM files (with looping and volume sliders) and atmospheric ambience tracks directly into the final film assembly.

### 🚀 Production Queue & Project Management
- **Background Production Queue**: Asynchronous generation queue with real-time progress monitoring, cancellation, and retry capabilities.
- **Selected Take Workflow**: Generate multiple takes per shot and designate preferred takes for downstream continuity and Final Assembly.
- **Storyboard & Direct Generate**: Granular manual control for single-shot creation or shot-by-shot project construction.

### ⚡ Supported Generation Backends
- **LTX-2.3 (Distilled Q4 & Unified)**: Powered by `mlx-video-with-audio` for fast on-device generation.
- **Custom LTX-2 MLX Models**: Secondary isolated backend via `ltx-2-mlx` allowing users to configure compatible fine-tuned models.

### 🔒 Security & Privacy Hardening
- **macOS Keychain Integration**: Optional external API credentials (such as ElevenLabs API keys) are stored securely in macOS Keychain with isolated namespaces for Personal and Dev apps.
- **Zero Telemetry & 100% Local Inference**: Complete privacy guarantee for core video and audio generation.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew)

---

## Known Limitations

1. **No-BGM Policy is Prompt-Based**: Unwanted background music is strongly suppressed via prompt engineering, but acoustic output cannot be 100% mathematically guaranteed by diffusion weights.
2. **Motion Continuation**: Inter-shot continuity uses Last-Frame I2V still-image conditioning; physical temporal momentum is not an end-to-end continuous tensor state.
3. **Identity Tracking**: Character consistency aids narrative grounding, but diffusion models do not guarantee biometric Face Lock.
4. **External Dependencies**: `ffmpeg` must be installed separately by the user for multi-shot Final Assembly.

---

## Feedback & Community

This is a public preview release. Please test generation workflows, report issues, and verify hardware compatibility.
