# v0.9.0-preview.5 — LTX-2.5 Image Conditioning Hotfix

Local Video Studio for Mac `v0.9.0-preview.5` is a focused hotfix for `preview.4`. If you use **LTX-2.5 (Experimental)** with a starting image, an Opening Reference, or a Character Reference, this release is required — `preview.4` produced corrupted video in those cases.

Everything else in `preview.4` is unchanged.

---

## What's Fixed

### 🖼️ 1. LTX-2.5 with a Reference Image Now Works
In `preview.4`, any LTX-2.5 generation that started from an image produced a meaningless brown, woven-looking video instead of a real result. This affected:

- **One Shot** with a **Starting Image** (image-to-video)
- **Auto Movie Shot 1** using an **Opening Reference**
- **Auto Movie** shots using a **Character Reference**
- Every **Last-Frame Continuity** shot (each one starts from the previous shot's final frame)

All of these now generate correctly and visibly follow the reference image.

**Text-only LTX-2.5 generation was never affected** — if you only ever generated from text, `preview.4` output was already correct.

### 🏷️ 2. Character Sheets No Longer Get Named After Their Own Title
When importing a character reference sheet, the analyzer could take the sheet's title text (for example "Character Reference Sheet") and use it as the character's name. That name then appeared in every generated shot's prompt. Sheet titles and section labels (Front, Side, Expressions, Costume Details, and similar) are now rejected as names, and the name field is simply left for you to fill in. Real names are untouched.

### 🔒 3. The App Now Refuses an Incompatible Runtime Instead of Producing Bad Video
The LTX-2.5 runtime check now verifies that the image-conditioning component actually loaded. A runtime that cannot load it is reported as needing an update rather than silently generating corrupted output.

---

## Upgrading

Open **Preferences → Models & Features** and use **Install LTX-2.5 Runtime** to update the app-managed runtime. The updated runtime is required for the fix — the app will tell you if it is out of date.

Your existing projects, characters, and Video Archive history are unaffected.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later (Apple On-Device Translation programmatic session requires macOS 26.0+)
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew: `brew install ffmpeg`)
- **LTX-2.5 (Experimental)**: an additional ~2 GB for the app-managed runtime, plus your chosen GGUF model file (commonly 12–24 GB depending on quantization)

---

## Known Limitations

Unchanged from `preview.4`:

1. **LTX-2.5 is Experimental**: not the default model, not guaranteed faster than LTX-2.3, and not verified on every Apple Silicon configuration.
2. **No Identity or Length Guarantees**: neither model provides deterministic identity locking or unlimited video length. A reference image now genuinely influences the result, but it does not guarantee an identical person across separate shots.
3. **Visual Continuity is Model-Dependent**: strong previous-frame conditioning can make large camera resets or location jumps harder within one Auto Movie sequence.
4. **No-BGM Policy is Best-Effort with Built-in Audio**: for guaranteed music-free output, turn **Built-in Audio OFF** and use **Final Audio** mixing.
5. **Custom Model Profiles Cap at 5**: an intentional limit for this release.

---

## Preview Build Signing

Like `preview.1` through `preview.4`, this is an unsigned, un-notarized preview build. macOS will warn on first launch; right-click the app and choose **Open** to run it. Developer ID signing and notarization remain planned for the stable release.

---

## Technical Notes

For those who want the detail: the official LTX-2.5 Video VAE ships encoder and decoder weights in a single file, keyed `encoder.*` / `decoder.*`. The runtime's image-conditioning path looked for the older single-purpose `vae_encoder.*` key prefix, which matched none of that file's keys, and loaded non-strictly — so the encoder silently kept randomly-initialized weights. Reference images were therefore encoded through noise, which is what produced the corrupted output. The encoder now uses the same loader contract as the decoder (prefix handling, per-channel statistics naming, and a shape-checked PyTorch→MLX Conv3D reorder applied only when needed) and loads strictly, so an unreadable checkpoint fails visibly instead of generating garbage. This is gated by a new runtime capability, `ltx25_official_video_vae_encoder_v1`.
