# v0.9.0-preview.4 — Fourth Public Preview Release Candidate

Local Video Studio for Mac `v0.9.0-preview.4` introduces **experimental LTX-2.5 support** alongside the stable LTX-2.3 workflow, so creators who want to try the newer model can do so without disturbing the default, reliable path.

---

## Key Highlights

### 🧪 1. Experimental LTX-2.5 Distilled Q4 GGUF Support
- **GGUF Model Support**: Run the LTX-2.5 distilled transformer directly from GGUF checkpoints, including memory-saving block-streamed weight loading for lower peak memory use during load.
- **One Shot, Auto Movie & Last-Frame Continuity**: LTX-2.5 works across the same One Shot and Auto Movie workflows as LTX-2.3, including shot-to-shot Last-Frame Continuity.
- **Built-in Audio**: Synchronized audio generation is supported for LTX-2.5, on the same audio-on/audio-off toggle as LTX-2.3.
- **App-Managed Runtime**: LTX-2.5 runs in its own isolated, app-managed Python environment, installed explicitly from Preferences → Models & Features — never silently, and never mixed with your main Python setup.
- **LTX-2.3 remains Stable and the Default.** LTX-2.5 is clearly labeled **Experimental** throughout the app.

### 🗂️ 2. Multiple Custom Model Profiles
- **Up to 5 Saved Profiles**: Save several custom LTX-2 MLX model configurations (including LTX-2.5) side by side, each with its own display name and model folder, instead of overwriting a single custom model slot.
- **Independent, Explicit Selection**: Generation always resolves the exact profile you selected — no silent fallback to a different profile or path.
- **Safe Removal**: Removing a saved profile never deletes the underlying model files on disk.

### 🏷️ 3. Correct Model Identity in Video Archive
- **Accurate Archive Labels**: A video generated with LTX-2.5 or a custom model profile now shows its actual model/profile name in Video Archive, instead of a stale or incorrect label from a different model.
- **Existing History Preserved**: Previously generated LTX-2.3 history entries remain readable and correctly labeled.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later (Apple On-Device Translation programmatic session requires macOS 26.0+)
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew: `brew install ffmpeg`)
- **LTX-2.5 (Experimental)**: an additional ~2 GB for the app-managed runtime, plus your chosen GGUF model file (commonly 12–24 GB depending on quantization); an internal SSD with sufficient free space is recommended.

---

## Known Limitations

1. **LTX-2.5 is Experimental**: It is not the default model, is not guaranteed to be faster than LTX-2.3, and is not verified across every Apple Silicon Mac configuration. It may currently be significantly slower to generate than LTX-2.3.
2. **No Identity or Length Guarantees**: As with LTX-2.3, neither model provides deterministic biometric identity locking or unlimited video length — Last-Frame Continuity improves visual flow but does not guarantee an identical person across shots.
3. **Visual Continuity is Model-Dependent**: Same limitation as preview.3 — strong previous-frame conditioning can make large camera resets or location jumps harder within one Auto Movie sequence. For distinct scenes, create separate Auto Movie or One Shot projects and combine them in an external video editor.
4. **No-BGM Policy is Best-Effort with Built-in Audio**: Prompt negative constraints suppress music, but acoustic output cannot be 100% guaranteed by diffusion weights alone. For guaranteed music-free output, turn **Built-in Audio OFF** and use **Final Audio** mixing.
5. **Custom Model Profiles Cap at 5**: This is an intentional limit for this release, not a temporary restriction.

---

## Deferred Features (Preview.5+ Backlog)

The following capabilities are reserved for future preview releases:
- Cinematic Assembly Transitions (crossfades, dip-to-black, wipes)
- Character Sheet Visual Reference & Vision Grounding
- Persistent Identity Anchoring across separate scenes
- Explicit Scene Break / Camera Reset within Auto Movie
- MiniMax H3 backend integration
- Promoting LTX-2.5 out of Experimental status
