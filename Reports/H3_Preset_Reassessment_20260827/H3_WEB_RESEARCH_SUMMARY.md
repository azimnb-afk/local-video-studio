# MiniMax H3 (Hailuo 3.0) Web Research Summary

- Research Date: 2026-08-27
- Focus: Optimal generation parameters, community best practices, quantization trade-offs, and comparison with LTX models.

---

## 1. Overview & Official Specifications

| Dimension | Official / Standard Community Recommendation | Current Local Video Studio Implementation | Gap / Note |
|---|---|---|---|
| **Architecture** | Omni-modal DiT (Joint Video + Stereo Audio in single pass) | Native mlx-serve DiT + Audio VAE | Matched |
| **Native Resolution** | 720p / 768p / 1080p / 2K | Tier 1 (512×288) / Tier 2 (640×384) | **Lower**: Local implementation runs at 512×288 / 640×384 for memory/speed |
| **Sampling Steps** | **16–30 steps** (standard) / 4–10 steps (with Turbo LoRA) | **8–12 steps** (Quick: 8, Std: 10, High: 12) | **Under-sampled**: 8–10 steps without Turbo LoRA leads to under-denoising |
| **Duration / Frames** | 5–15 seconds @ 24fps (124–360+ frames) | 3–4 seconds (73–90 frames single window) | Focused on short shots; multi-shot continuity handles duration |
| **Prompt Format** | Structured instruct format (`<Subject N>`, camera tags, lighting) | `MiniMaxH3PromptCompiler` rule-based compiler | Partially aligned (adds camera & identity preservation rules) |
| **Guidance (CFG)** | 1.0 – 3.0 (lower CFG preferred for video stability) | Controlled inside DiT / mlx-serve defaults | Managed by mlx-serve |
| **Quantization** | FP16/BF16 (cloud) / 4-bit DiT (local) / 4-8bit TE | 4-bit DiT + **2-bit Text Encoder** | **2-bit TE**: Reduces memory but impairs text-only comprehension |

---

## 2. Key Findings by Dimension

### 2.1 Resolution & Quality
- MiniMax H3 DiT was trained on high-resolution video (up to 2K, native 768p/720p).
- Downscaling to **512×288** reduces compute by ~50% but degrades fine facial features, eye sharpness, and background textures.
- **640×384** (Tier 2) and **768×432 / 768×448** offer substantially better subject stability and sharper edges.

### 2.2 Inference Steps & Denoising Quality
- Without a dedicated distillation/Turbo LoRA, flow-matching / diffusion video models require **at least 16 to 24 steps** to converge fully.
- At **8–10 steps**, high-frequency motion details blur, and the latter half of the clip often exhibits temporal jitter or softening (late-frame degradation).
- Increasing steps from 10 to **16–20 steps** provides the most visible improvement in motion coherence and sharpness.

### 2.3 Text Encoder Quantization (2-bit vs 4-bit/8-bit)
- The Qwen3-VL text encoder in the local model pack is quantized to **affine 2-bit (group size 64)** to fit within 32GB/48GB Mac memory budgets alongside the 18.7GB DiT.
- **Impact**: 2-bit quantization causes loss in complex text semantic parsing. Consequently:
  - **T2V (Text-to-Video)**: Struggles with nuanced composition, detailed character descriptions, and subtle actions.
  - **I2V (Image-to-Video)**: Drastically outperforms T2V because the visual features in the starting image anchor the subject, bypassing text encoder limitations.

### 2.4 Prompting Best Practices
- H3 performs best with **direct, declarative physical descriptions** rather than abstract adjectives.
- Explicit camera direction (e.g. `The camera pans slowly...`, `Static wide shot`) prevents erratic synthetic camera drift.
- Explicit appearance preservation constraints (`The subject's face, clothing, and background remain consistent throughout the shot`) significantly reduce subject morphing.

### 2.5 MiniMax H3 vs LTX 2.3 / 2.5
- **MiniMax H3 Strengths**: Cinematic physics, complex fluid/cloth motion, native synchronized stereo audio, photorealistic lighting.
- **LTX Strengths**: Fast inference speed (distilled models run at 8–15 steps natively), robust local control, sharp text-to-video alignment at low step counts.
- **Why H3 currently looks worse in Local Video Studio**:
  1. H3 is running at low steps (8–10) without distillation weights, whereas LTX runs distilled weights designed for 8–15 steps.
  2. H3 is constrained to 512×288 by default.
  3. The 2-bit text encoder weakens text-only prompt fidelity.

---

## 3. General Recommended Settings Summary

| Scenario | Target Resolution | Target Frames (Duration) | Target Steps | Mode | Expected Quality |
|---|---|---|---|---|---|
| **Quick Preview** | 512×288 / 288×512 | 73f (3.0s) | 12 steps | I2V preferred | Usable for composition preview |
| **Standard (Balanced)** | 640×384 / 384×640 | 90f–107f (3.75s–4.5s) | 16 steps | I2V preferred | Good balance of speed and clarity |
| **High Quality** | 640×384 or 768×448 | 107f–124f (4.5s–5.2s) | 20–24 steps | I2V / Structured T2V | High sharpness, stable motion |
| **Cinematic / Archival** | 768×448 / 864×480 | 124f–141f (5.2s–5.9s) | 24–30 steps | I2V | Maximum detail, slowest speed |
