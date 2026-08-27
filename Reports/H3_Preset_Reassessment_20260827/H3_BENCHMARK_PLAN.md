# MiniMax H3 Comprehensive Preset Reassessment Benchmark Plan

- Date: 2026-08-27
- Target Hardware: Apple Silicon Mac (M4 Pro Unified Memory)
- Runtime: `mlx-serve` (v26.8.9) at `http://127.0.0.1:11236` (or standalone benchmark port)
- Model: `MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder`
- Fixed Seed: `42` (ensures exact deterministic reproducibility across runs)

---

## 1. Objectives & Research Hypotheses

1. **Hypothesis 1 (Steps Deficit)**: Current 8–10 steps leave the flow-matching DiT under-denoised, causing grain, motion jitter, and late-frame blur. Increasing steps to 16–20 will dramatically improve temporal consistency.
2. **Hypothesis 2 (Resolution Deficit)**: 512×288 does not provide sufficient latent pixel density for fine facial details. 640×384 (Tier 2) will significantly stabilize faces and edges.
3. **Hypothesis 3 (Text Encoder Bottleneck)**: The 2-bit quantized Qwen3-VL text encoder struggles with fine compositional text cues, making T2V significantly weaker than I2V.
4. **Hypothesis 4 (Duration / Frame Decay)**: Single-window shots exceeding 107 frames (4.5s) experience compounding latent drift unless sampled at higher step counts (20+ steps).

---

## 2. Test Scenarios

- **SCENARIO A (Landscape I2V)**:
  - Source Image: `test_portrait_ref.png` (16:9 photo of woman near window)
  - Prompt: `The woman smiles gently and looks slightly to the side as a soft breeze moves her hair, the camera slowly glides forward, smooth cinematic motion.`
- **SCENARIO B (Landscape T2V)**:
  - Prompt: `A serene woman with shoulder-length dark hair and a warm smile, standing in a brightly lit modern room near a window, gentle breeze moving her hair, natural cinematic lighting, smooth slow camera push-in.`
- **SCENARIO C (Portrait I2V)**:
  - Source Image: `test_portrait_vertical.png` (9:16 cropped reference)
  - Prompt: `The woman smiles gently and looks slightly to the side as a soft breeze moves her hair, the camera slowly glides forward, smooth cinematic motion.`
- **SCENARIO D (LTX 2.3 Baseline Comparison)**:
  - LTX 2.3 Distilled Q4 with exact matching prompt and image.

---

## 3. Benchmark Execution Matrix

| Run ID | Scenario | Input Mode | Resolution | Frames | Duration | Steps | Description / Factor Tested |
|---|---|---|---|---|---|---|---|
| **RUN_01** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **8** | Current Quick step level |
| **RUN_02** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **10** | **Current Standard Baseline** |
| **RUN_03** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **12** | Current High step level |
| **RUN_04** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **16** | Proposed Standard candidate (16 steps) |
| **RUN_05** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **20** | Proposed High candidate (20 steps) |
| **RUN_06** | Scenario A (Landscape) | I2V | 512×288 | 90 | 3.75s | **24** | Quality ceiling test (24 steps) |
| **RUN_07** | Scenario A (Landscape) | I2V | **512×288** | 90 | 3.75s | 16 | Resolution comparison (Tier 1 @ 16st) |
| **RUN_08** | Scenario A (Landscape) | I2V | **640×384** | 90 | 3.75s | 16 | Resolution comparison (Tier 2 @ 16st) |
| **RUN_09** | Scenario A (Landscape) | I2V | **768×432** | 90 | 3.75s | 16 | High-res feasibility (768p @ 16st) |
| **RUN_10** | Scenario A (Landscape) | I2V | 640×384 | **73** | 3.04s | 16 | Duration comparison (3.0s / 73f) |
| **RUN_11** | Scenario A (Landscape) | I2V | 640×384 | **90** | 3.75s | 16 | Duration comparison (3.75s / 90f) |
| **RUN_12** | Scenario A (Landscape) | I2V | 640×384 | **107** | 4.46s | 16 | Duration comparison (4.5s / 107f) |
| **RUN_13** | Scenario A (Landscape) | I2V | 640×384 | **124** | 5.17s | 20 | Duration comparison (5.2s / 124f @ 20st) |
| **RUN_14** | Scenario A (Landscape) | I2V | 640×384 | **141** | 5.88s | 20 | Duration comparison (5.9s / 141f @ 20st) |
| **RUN_15** | Scenario B (Landscape) | **T2V** | 512×288 | 90 | 3.75s | **10** | T2V Current Baseline (10st) |
| **RUN_16** | Scenario B (Landscape) | **T2V** | 640×384 | 90 | 3.75s | **16** | T2V Proposed Standard (16st) |
| **RUN_17** | Scenario B (Landscape) | **T2V** | 640×384 | 90 | 3.75s | **24** | T2V High Steps (24st) |
| **RUN_18** | Scenario C (Portrait) | I2V | 288×512 | 90 | 3.75s | 10 | Portrait Current Baseline |
| **RUN_19** | Scenario C (Portrait) | I2V | 384×640 | 90 | 3.75s | 16 | Portrait Proposed Standard |
| **RUN_20** | Scenario D (LTX) | I2V | 512×320 | 49 | 2.04s | 15 | LTX 2.3 Distilled Q4 Baseline (I2V) |
| **RUN_21** | Scenario D (LTX) | T2V | 512×320 | 49 | 2.04s | 15 | LTX 2.3 Distilled Q4 Baseline (T2V) |

---

## 4. Evaluation Criteria & Metrics

For each run:
1. **Generation Latency & VRAM / Memory Stability**
2. **Key Frame Extraction**:
   - `f0` (First frame / 0%)
   - `f_early` (~25%)
   - `f_mid` (~50%)
   - `f_late` (~75%)
   - `f_end` (100% / final frame)
3. **Quality Metrics (1–10 Scale)**:
   - *Subject Consistency* (顔・服装の保持性)
   - *Face Stability* (顔の歪み・崩れにくさ)
   - *Motion Naturalness* (動きの自然さ・物理妥当性)
   - *Temporal Stability* (チラつき・ジッターの少なさ)
   - *Late-Frame Degradation* (後半のボケ・破綻の少なさ: 10=劣化なし, 1=激しい崩れ)
   - *Sharpness & Detail* (解像感・ディテール)
   - *Overall Preference* (総合評価)
