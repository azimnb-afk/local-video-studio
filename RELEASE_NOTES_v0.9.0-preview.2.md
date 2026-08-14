# v0.9.0-preview.2 — Second Public Preview Release Candidate

Local Video Studio for Mac — AutoMovie Edition `v0.9.0-preview.2` is the second public preview release candidate. It delivers major improvements to custom model support, prompt localization, local AI planning reliability, and queue resilience for on-device AI filmmaking on Apple Silicon Macs.

---

## Key Highlights

### 🗂️ Existing Local Model Selection for Custom LTX-2 MLX
- **Direct Folder Picker**: Select existing local weight folders containing model components directly in Preferences (`Preferences > Models & Features > Custom LTX-2 MLX Model`), avoiding duplicate downloads.
- **Generic Custom Model Naming**: Safe, clean public interface for fine-tuned or community-provided LTX-2 MLX weights.

### 🔒 Immutable Queued Job Snapshots & Live Sidebar Sync
- **Frozen Queue State**: Every queued generation job freezes its exact model configuration (official LTX or custom local path) at submission time. Changing active model selections in the UI during a render does not alter running or pending jobs.
- **Reactive Sidebar Indicator**: The lower-left model badge stays live and synchronized with current UI selections and environment readiness.

### 🌐 Multilingual One Shot & Strict English Render Prompts
- **Original Brief vs. Render Prompt**: Keeps user-entered Japanese or other language text safe in the project archive while compiling clean, renderer-safe English prompts for video diffusion.
- **Apple On-Device Translation**: Leverages macOS native on-device translation to translate descriptive action briefs locally without external cloud APIs or network calls.
- **Dialogue Language Preservation**: Retains dialogue lines verbatim in their original language.
- **Fail-Closed Gate**: Rejects untranslated non-English descriptive text before dispatching to the renderer to prevent hallucination.

### 🛡️ Enhanced Prompt Sanitization & Semantic Guardrails
- **Special-Token Stripping**: Automatically removes LLM chat-template tokens (e.g. `<end_of_turn>`, `<start_of_turn>`, `<|eot_id|>`, `</s>`) before prompts reach generation backends.
- **Intent-Preserving Enhancement**: Constrains prompt expanders from inventing unrequested narrative beats, dialogue, or sound effects.

### 🎬 Restored Auto Movie Local AI Planning & Dual Protocol Support
- **Structured JSON + Text Protocol Fallback**: Employs a robust fallback chain (Structured JSON → Text Protocol → Basic Template) so that models that struggle with strict JSON schemas still succeed via Text Protocol.
- **Text Protocol Success Recognized as Local AI**: Text Protocol completions produce rich, scene-specific multi-shot plans without falling back to basic templates.
- **300-Second Local Director Timeout**: Accommodates deep reasoning / CoT planning in 35B+ local models without premature 60-second timeouts.

### 🎵 No-BGM Policy & Audio Workflow Guidance
- **No-BGM Policy v2 Maintained**: Prompt plumbing reliably enforces negative music constraints at the backend boundary.
- **Best-Effort Disclosure**: Clarifies that acoustic music suppression in built-in LTX audio is model-dependent. For guaranteed music-free outputs, turning **Built-in Audio OFF** and using the **Final Audio** layer is recommended.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later (Apple On-Device Translation programmatic session requires macOS 26.0+)
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew)

---

## Known Limitations

1. **No-BGM Policy is Best-Effort with Built-in Audio**: Prompt negative constraints suppress music, but acoustic output cannot be 100% guaranteed by diffusion weights alone.
2. **Apple On-Device Translation Availability**: Native programmatic platform translation requires supported macOS versions (macOS 26.0+); unsupported or older versions fail-closed cleanly without sending unresolved non-English descriptive text to the renderer.
3. **Hardware Intensive**: Local generation fully utilizes GPU and unified memory. Close heavy applications during multi-shot rendering.

---

## Feedback & Community

This is a public preview release candidate. Please report any issues or feedback on GitHub.
