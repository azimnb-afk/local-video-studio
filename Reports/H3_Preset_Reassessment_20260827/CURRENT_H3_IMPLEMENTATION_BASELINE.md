# Current MiniMax H3 Implementation Baseline

- Date: 2026-08-27
- Environment: Apple Silicon Mac (M4 Pro / Unified Memory)
- App: Local Video Studio (Dev / Personal)
- Model: `MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder`
- Runtime: `mlx-serve` (v26.8.9, native arm64)

---

## 1. Current Preset Definitions

| Preset | Resolution (Landscape) | Resolution (Portrait) | Frames | Duration (@24fps) | Steps | Chain Windows | Description |
|---|---|---|---|---|---|---|---|
| **Quick** | 512×288 | 288×512 | 73 | 3.04s (display: 3.0s) | 8 | 1 | 3 sec · 8 steps · fast preview |
| **Standard** (Default) | 512×288 | 288×512 | 90 | 3.75s (display: 4.0s) | 10 | 1 | Recommended · 4 sec · 10 steps · proven balance |
| **High** | 640×384 | 384×640 | 90 | 3.75s (display: 4.0s) | 12 | 1 | 4 sec · 12 steps · 384×640 high resolution |
| **Custom** | Tier 1 (512×288) or Tier 2 (640×384) | Tier 1 (288×512) or Tier 2 (384×640) | 22–141 (17k+5) | 1.0s–6.0s | 6–20 | 1 | Custom duration (1–6s), steps (6–20), resolution tiers |

---

## 2. Model & Runtime Architecture

### 2.1 Model Components
- **Text Encoder**: Qwen3-VL (2-bit affine quantized, group size 64, ~9.6 GB).
  - Staged residency: Loaded for prompt embedding, then freed before DiT loads.
  - *Known impact*: 2-bit quantization affects prompt adherence / nuance compared to 4-bit / 8-bit text encoders.
- **Diffusion Transformer (DiT)**: MiniMax-H3 Transformer (4-bit affine quantized, group size 64, ~18.7 GB).
  - 50 layers, 56 attention heads, hidden size 5376.
- **Video VAE**: Dense FP16 (~5.2 GB).
- **Audio VAE**: Dense FP32 (~0.6 GB).
- **Total Storage**: ~34.1 GB.

### 2.2 Inference Transport
- Native HTTP JSON API via `mlx-serve`: `POST /v1/video/generations`
- Payload:
  ```json
  {
    "prompt": "...",
    "width": 512,
    "height": 288,
    "num_frames": 90,
    "steps": 10,
    "seed": 123456,
    "first_frame_image": "<base64 encoded jpeg/png>",
    "chain_windows": 1
  }
  ```
- Output: Base64-encoded raw RGB8 frames + PCM s16le stereo audio, muxed via FFmpeg (`libx264` + `aac`).

---

## 3. Constraints & Behavioral Properties

1. **Frame Count Ladder ($17k + 5$)**:
   - Legal single-window frames: `22, 39, 56, 73, 90, 107, 124, 141`
   - Frame rates: Fixed 24 fps.
2. **Resolution Tiers**:
   - Tier 1: `512×288` (landscape) / `288×512` (portrait)
   - Tier 2: `640×384` (landscape) / `384×640` (portrait)
   - Higher resolutions (e.g. 768×448, 864×480) are not exposed in presets but may be supported by mlx-serve.
3. **Prompt Conditioning & Enhancers**:
   - Gemma LLM Prompt Enhancer is **explicitly disabled** for H3 (only used for LTX).
   - `MiniMaxH3PromptCompiler` adds rule-based structuring (camera movements, appearance preservation text for I2V).
4. **Image Conditioning (I2V & Auto Movie Continuity)**:
   - Initial shot / Single generation: `first_frame_image` contains prepared reference image.
   - Continue shot: `first_frame_image` contains exact decoded final frame of previous shot.
   - Re-anchor shot (natural cut): `first_frame_image` contains prepared Project Identity Anchor.
