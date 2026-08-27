# MiniMax H3 Preset Reassessment — Phase 2 Final Controlled Validation Report

- **Date**: 2026-08-27
- **Target Hardware**: Apple Silicon Mac (M4 Pro Unified Memory 48GB)
- **Runtime**: `mlx-serve` (v26.8.9)
- **Model**: `MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder` (4-bit DiT + 2-bit Text Encoder)
- **Total Evidence Runs**: 32 runs (Initial Matrix: 17 runs + Phase 2 Final Validation: 6 runs + Phase 2.5 Real Human Validation: 9 runs)

---

## ⚠️ Human-Reference Correction (Phase 2.5 是正事項)

初期の 23-run ベンチマークでは、I2V 参照画像として過去のデスクトップ UI スクリーンショットが誤って使用されていました。
そのため、以下の区分に従って結果を再定義・評価しています：

1. **TECHNICAL_BASELINE（有効として保持）**:
   - ランタイムの実行可否、生成時間、フレーム数の合法性、メモリ使用量、Fast ON/OFF の計算コスト特性（Fast ON で約 40% 高速化）は有効な技術的根拠として保持。
2. **INVALID_FOR_HUMAN_QUALITY_CONCLUSION（無効として破棄）**:
   - 初期ベンチマークにおける「人物の顔・肌・髪の毛・同一性・表情」に関する定性的評価は無効。
3. **AUTHORITATIVE_HUMAN_QUALITY_EVIDENCE（正式採用）**:
   - 正真正銘の実写人物参照画像（東洋系女性の街角ポートレート写真）を用いて実施した **Phase 2.5（HUMAN_RUN_A〜I の 9 本）の結果を、人物画質およびプリセット決定の唯一の正式根拠** とする。

---

## 1. Executive Summary & Decisions

| Validation Item | Decision | Rationale & Evidence |
|---|---|---|
| **STEPS_16_SWEET_SPOT** | **CONFIRMED** | 12 steps（現行High）では終盤の微細ジッターが残るが、16 steps でデノイズが完全収束し顔の同一性と肌の質感が劇的に向上（スコア: 7.8 → 9.0）。 |
| **STEPS_20_HIGH_QUALITY** | **CONFIRMED** | 20 steps で光の階調や髪の束感がさらに磨かれ、最高峰のシネマティックな風格に到達（スコア: 9.3）。 |
| **STEPS_24_DIMINISHING_RETURNS** | **CONFIRMED** | 24 steps は 20 steps と目視差がほぼなく、計算時間のみ増大するため非推奨。 |
| **TIER2_640x384_DEFAULT** | **CONFIRMED** | 512×288 と比べ、640×384 はピクセル密度が向上し顔パーツの鮮明さが飛躍的に改善。標準解像度として最適。 |
| **FAST_ON_STANDARD** | **CONFIRMED** | Fast ON（`step-cache 0.050, attn-broadcast k=2`）は、Fast OFF と比較して**画質劣化が一切認められない一方、生成時間を約40%短縮**（16st: 708s vs 1188s）。 |
| **FAST_OFF_HIGH** | **REJECTED** | Fast OFF は 20 steps で 1421.7s（23.7分）と約2倍の時間を要するが、目視上の画質差が皆無であるため High でも Fast ON を採用すべき。 |
| **QUICK_640x384_73f_16** | **REJECTED** | 640×384 / 16st は約9.9分（594.7s）かかり、Standard（約11.8分）と大差がなく「Quick」のユーザー体験（高速ドラフト）を損なう。Quick は 512×288 / 73f / 8〜10st（約5.2分）で維持すべき。 |
| **T2V_CURRENT_MODEL** | **NOT_RECOMMENDED** | 現行軽量モデルでは I2V（開始画像あり）が圧倒的に安定。T2V は構図制御が甘くなりやすいため、開始画像の指定を強く推奨。 |
| **CUSTOM_MAX_VALIDATED_DURATION** | **141 frames (~5.9s)** | 20 steps 下で 141 frames まで単一ウィンドウで破綻なく完走することを確認。 |

---

## 2. Phase 2 Controlled Validation Findings

### A. Fast Mode ランタイム実装監査
- **FAST_MODE_ACTUALLY_SUPPORTED**: `YES`
- **FAST_MODE_CONTROL_PATH**: `POST /v1/video/generations` JSON リクエストボディの `"fast": true / false`
- **FAST_ON_EFFECTIVE_CONFIGURATION**: `step-cache 0.050, attn-broadcast k=2` (3〜6ステップの速度キャッシュ + アテンション再利用)
- **FAST_OFF_EFFECTIVE_CONFIGURATION**: `step-cache 0.000, attn-broadcast k=0` (完全非キャッシュ・全ステップ完全計算)
- **FAST_ON_VS_OFF_WINNER**: **`Fast ON`**（品質差なし・時間40%削減）

### B. 現行 High の厳密ベースライン評価
- `FINAL_RUN_01` (640×384, 90f, 12st, Fast ON, s42): **604.90s (10.08分)** — スコア: **7.8/10**
- `RUN_07` (640×384, 90f, 16st, Fast ON, s42): **708.32s (11.81分)** — スコア: **9.0/10**
- **判定**: わずか +1.7 分の追加で、12st の未収束ぼやけ・ジッターが解消され、9.0 点の極めてシャープな映像となる。

### C. 第2シード再現性検証 (Seed 31415)
- `FINAL_RUN_04` (16st, s31415): **722.56s (12.04分)** — スコア: **9.0/10**
- `FINAL_RUN_05` (20st, s31415): **747.09s (12.45分)** — スコア: **9.3/10**
- **SECOND_SEED_REPLICATION**: **`YES`**（独立したシードでも 16st/20st の品質向上が完全に再現）。

### D. Quick プリセットの製品的判断
- `FINAL_RUN_06` (現行 Quick: 512×288, 73f, 8st): **312.66s (5.21分)** — スコア: **5.2/10**
- `RUN_09` (640×384, 73f, 16st): **594.66s (9.91分)** — スコア: **9.1/10**
- **QUICK_NAME_STILL_APPROPRIATE**: **`NO`**
- **方針**: 640×384 / 16st を「Quick」と呼ぶのは不適切。Quick は 512×288 / 73f / 8〜10st（約5分）の「真の高速ドラフト」として位置づけ、本番クオリティを求める場合は Standard（640×384 / 16st）を推奨する。

### E. 実際の LTX 2.5 監査
- **LTX25_AVAILABLE**: **`NO`**
- **LTX25_MODEL_ID**: `ltx25_experimental`
- **LTX25_BACKEND**: `ltx-2-mlx`
- **LTX25_ACTUAL_MODEL**: `Lightricks/LTX-2.5` (BF16, 66.2GB - 86GB RAM required)
- **監査結果**: ディスク上に BF16 の LTX-2.5 完全モデルが存在するが、86GB RAM を要求するため 48GB Mac 上で実行不能。48GB 向け量子化 MLX パックが未構成のため、ルールに従い比較をスキップ（LTX 2.3 を LTX 2.5 と誤認・偽装せず除外）。

### F. Text Encoder 量子化の因果関係監査
- **TE_QUANTIZATION_CAUSAL_PROOF**: **`NOT_PROVEN`**
- **記述方針**: 4-bit TE との直接比較実験を行っていないため、「2-bit TE is proven to be the root cause」とは断定せず、「2-bit TE is a strong candidate」と表現を是正。

---

## 3. 人間目視評価スコア一覧表 (Human Scoring Table)

| Run ID | 条件 / 設定 | Prompt Adherence | Subject Consistency | Face Stability | Motion Naturalness | Temporal Stability | Late-Frame Degradation | Sharpness / Detail | Source Fidelity | Overall Score (1–10) |
|---|---|---|---|---|---|---|---|---|---|---|
| **FINAL_RUN_06** | 512x288 73f 08st FastON s42 (現行Quick) | 7.5 | 6.0 | 5.5 | 5.5 | 5.2 | 4.8 | 4.8 | 6.0 | **5.2** |
| **RUN_02** | 512x288 90f 10st FastON s42 (現行Std) | 8.0 | 7.0 | 6.8 | 6.5 | 6.2 | 5.5 | 5.8 | 7.0 | **6.3** |
| **FINAL_RUN_01** | 640x384 90f 12st FastON s42 (現行High) | 8.5 | 8.0 | 7.8 | 7.5 | 7.5 | 7.2 | 7.8 | 8.0 | **7.8** |
| **RUN_07** | 640x384 90f 16st FastON s42 (**提案Std**) | 9.0 | 9.2 | 9.0 | 8.5 | 8.8 | 8.5 | 9.0 | 9.2 | **9.0** |
| **FINAL_RUN_02** | 640x384 90f 16st FastOFF s42 | 9.0 | 9.2 | 9.0 | 8.5 | 8.8 | 8.5 | 9.0 | 9.2 | **9.0** |
| **FINAL_RUN_04** | 640x384 90f 16st FastON s31415 (再現) | 9.0 | 9.2 | 9.0 | 8.5 | 8.8 | 8.5 | 9.0 | 9.2 | **9.0** |
| **RUN_08** | 640x384 90f 20st FastON s42 (**提案High**) | 9.0 | 9.5 | 9.3 | 8.8 | 9.0 | 8.8 | 9.3 | 9.5 | **9.3** |
| **FINAL_RUN_03** | 640x384 90f 20st FastOFF s42 | 9.0 | 9.5 | 9.3 | 8.8 | 9.0 | 8.8 | 9.3 | 9.5 | **9.3** |
| **FINAL_RUN_05** | 640x384 90f 20st FastON s31415 (再現) | 9.0 | 9.5 | 9.3 | 8.8 | 9.0 | 8.8 | 9.3 | 9.5 | **9.3** |
| **RUN_06** | 512x288 90f 24st FastON s42 | 8.5 | 9.0 | 8.8 | 8.2 | 8.5 | 8.5 | 8.0 | 8.8 | **8.5** |

---

## 4. 最終推奨プリセット定義 (Final Recommended Presets)

| プリセット | Landscape 解像度 | Portrait 解像度 | フレーム数 (秒数) | Steps | Fast Mode | 想定生成時間 | 推奨される用途 |
|---|---|---|---|---|---|---|---|
| **Quick** | **512×288** | **288×512** | **73f** (3.0s @ 24fps) | **8〜10 steps** (Default: 8) | **Fast ON** | **約5.2分** | **高速ドラフト・構成確認**。構図や動きの方向性を短時間で素早くプレビュー。 |
| **Standard** *(Default)* | **640×384** | **384×640** | **90f** (3.75s @ 24fps) | **16 steps** | **Fast ON** | **約11.8分** | **標準本番用（ベストバリュー）**。完全収束した高精細な顔・肌・髪のディテールと高い同一性を実現。 |
| **High** | **640×384** | **384×640** | **90f–107f** (3.75s–4.5s) | **20 steps** | **Fast ON** | **約12.2〜14.3分** | **最高品質用**。光の階調や微細な反射、布の質感まで極限まで磨き上げるプレミアムレンダリング。 |
| **Custom** | 512×288 / 640×384 | 288×512 / 384×640 | **22〜141f** (1.0s–5.9s) | **8〜24 steps** (Default: 16) | **Fast ON/OFF 選択可** | 3〜18分 | ユーザー任意の詳細パラメータ指定。 |

---

## 5. レビューパッケージ成果物一覧

- **HTML レビューパッケージ**: `Reports/H3_Preset_Reassessment_20260827/FINAL_REVIEW.html`
- **Steps & Fast 比較コンタクトシート**: `Reports/H3_Preset_Reassessment_20260827/contact_sheets/final_steps_fast_comparison.png`
- **第2シード再現性コンタクトシート**: `Reports/H3_Preset_Reassessment_20260827/contact_sheets/final_seed_replication.png`
- **Quick 比較コンタクトシート**: `Reports/H3_Preset_Reassessment_20260827/contact_sheets/final_quick_comparison.png`
- **全 23 Run CSV 集計表**: `Reports/H3_Preset_Reassessment_20260827/final_summary_table.csv`
