# v0.9.0-preview.10 — Director ON / OFF, Direct Auto Movie & 15-Second One Shot

Local Video Studio for Mac `v0.9.0-preview.10` introduces **Director ON / OFF controls** across both One Shot and Auto Movie workflows, featuring a **direct prompt-preserving mode**, **deterministic structural movie planning**, and extended **15-second One Shot generation** for LTX models.

---

## What's New

### 🎬 One Shot & Auto Movie Director ON / OFF
- **Director ON (AI-Assisted)**: Local AI plans and directs your shot or multi-shot sequence with creative shot scaling, camera movement, and pacing.
- **Director OFF (Direct / Prompt Structure)**: Uses your authored prompt structure directly without AI creative rewriting or filmmaking embellishment.

### 🎥 Direct Auto Movie & Deterministic Structural Planning
- **Structural Movie Planner**: In Director OFF mode, the application deterministically converts paragraphs and sentences into structured multi-shot sequences without an LLM creative-planning pass.
- **Explicit CUT / CONTINUE Control**: Scene transitions follow natural paragraph boundaries (paragraph break = CUT, intra-paragraph sentence = CONTINUE) or explicit user-authored markers (`[CUT]`, `[CONTINUE]`).
- **Full Continuity Conditioning**: Shot-to-shot Image-to-Video continuation seamlessly inherits the verified final frame of the preceding shot.

### ⏱️ Extended One Shot Generation
- **Up to 15-Second LTX Generation**: Extended generation duration support up to 15 seconds (361 frames) for single-shot takes on LTX models.

---

## Improvements

- **Canonical Request Architecture**: Improved canonical request construction for directed and multi-shot generation workflows ensures consistent prompt compilation, frame calculations, and audio policy enforcement.
- **Clearer Validation & Error UX**: Instant in-sheet error feedback for empty prompts, excessive shot counts, or duration capacity mismatches before queueing jobs.
- **Custom LTX-2 MLX Compatibility**: Continued support and robust descriptor routing for user-registered custom LTX models.
- **MiniMax H3 Stability**: Preserved managed `mlx-serve` runtime isolation, port separation, and machine-wide generation lease serialization.

---

## Notes & Limitations

- **Single Engine per Auto Movie**: An Auto Movie project executes all shots using the single user-selected video model.
- **Director OFF Semantics**: Director OFF performs deterministic structural segmentation and does not make creative filmmaking choices.
- **Hardware Tiering**: 32 GB unified memory minimum for LTX Q4 models; 48 GB+ recommended for LTX Q8 and experimental MiniMax H3.

---

## Upgrading

Download `Local.Video.Studio-0.9.0-preview.10.dmg`, open it, and drag **Local Video Studio** to your Applications folder. Your existing projects, custom models, and archive history will remain fully intact.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Max/Ultra, M2, M3, M4)
- **RAM**: 32 GB minimum (LTX Q4 models); 48 GB+ recommended (LTX Q8 / MiniMax H3)
- **OS**: macOS 14.0 (Sonoma) or later
- **Dependencies**: Python 3.11+ and `ffmpeg` (`brew install ffmpeg`)

---

## Preview Build Signing

This Preview build is not Developer ID signed or notarized. On first launch, right-click the app in Finder and choose **Open** to proceed. Developer ID signing and notarization remain planned for the general release.
