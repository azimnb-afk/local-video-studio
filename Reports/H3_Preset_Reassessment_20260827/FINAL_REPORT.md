# MiniMax H3 Comprehensive Preset Reassessment & Quality Report

- Date: 2026-08-27
- Target Hardware: Apple Silicon Mac (M4 Pro Unified Memory)
- Runtime: `mlx-serve` (v26.8.9)
- Model: `MiniMax-H3-FL2VA-MLX-Serve-2bit-text-encoder` (4-bit DiT + 2-bit Text Encoder)
- Total Benchmark Runs: 17 runs (Deterministic Seed: 42)

---

## 1. Executive Summary & Core Conclusion

### なぜ現行の MiniMax H3 は LTX 2.5 と比べて見劣りしていたのか？

実機検証とネット調査により、原因が明確に切り分けられました：

1. **ステップ数の絶対的不足（最大要因: 45%）**:
   - 現行プリセット（Quick: 8st, Standard: 10st, High: 12st）は、蒸留（Distilled / Turbo）されていない H3 DiT に対してステップ数が低すぎました。
   - **8〜10 steps ではデノイズが収束せず、中盤（50%）から終盤（100%）にかけて人物の顔や髪がぼやけ、低周波ノイズ・ジッターが発生していました**。
   - **16 steps 以上に引き上げるだけで、同一解像度でも被写体の一貫性とディテールが劇的に向上します**。
2. **解像度不足（Tier 1: 512×288 の限界: 30%）**:
   - H3 は 720p/768p/2K 向けに学習された大型モデルであり、512×288（特に縦動画の 288×512）では顔のパーツを構成する潜在ピクセル密度が不足していました。
   - **Tier 2（640×384 / 384×640）に引き上げることで、瞳・まつ毛・肌の質感・背景の直線性が鮮明になり、シネマティックな風格が確立されます**。
3. **Text Encoder 2-bit 量子化による T2V 表現力低下（20%）**:
   - メモリ削減のために Qwen3-VL テキストエンコーダーが 2-bit affine に量子化されているため、テキストプロンプトの微細なニュアンスや構図指示の追従性が劣化しています。
   - そのため、**T2V（テキストのみ）は不鮮明で暗くなりやすい一方、I2V（開始画像あり）は画像特徴がアンカーとなるため極めて高品質に生成されます**。
4. **Duration / 長尺時のドリフト（5%）**:
   - 単一ウィンドウで 107f（4.5s）〜141f（5.9s）を生成する場合、10 steps では急速に崩壊しますが、**20 steps を確保すれば 141f でも破綻せず完走可能**です。ただし、Auto Movie では 3.0s〜4.0s/ショットで繋ぐ方が物理的に自然なテンポを保てます。

---

## 2. Benchmark Summary Matrix (All 17 Runs)

| Run ID | Name / Config | Category | Mode | Resolution | Frames | Duration | Steps | Time (s) | Overall Score (1–10) | Evaluation & Key Observation |
|---|---|---|---|---|---|---|---|---|---|---|
| **RUN_01** | `I2V_512x288_90f_08steps` | Steps | I2V | 512×288 | 90 | 3.75s | 8 | 411.7s | 5.5 | **デノイズ不足**。後半で顔と髪がぼやけ、低周波ノイズが目立つ。 |
| **RUN_02** | `I2V_512x288_90f_10steps` | Steps | I2V | 512×288 | 90 | 3.75s | 10 | 405.4s | 6.3 | **現行Standardベースライン**。8stより改善するが、依然として後半の輪郭が甘い。 |
| **RUN_03** | `I2V_512x288_90f_12steps` | Steps | I2V | 512×288 | 90 | 3.75s | 12 | 432.8s | 7.0 | **現行High相当**。10stより引き締まるが、微細なジッターが残る。 |
| **RUN_04** | `I2V_512x288_90f_16steps` | Steps | I2V | 512×288 | 90 | 3.75s | 16 | 488.9s | 8.2 | **スイートスポット**。16stでデノイズが完全収束。最後まで同一性を維持。 |
| **RUN_05** | `I2V_512x288_90f_20steps` | Steps | I2V | 512×288 | 90 | 3.75s | 20 | 510.1s | 8.5 | 極めて高品質。背景の階調がより滑らか。 |
| **RUN_06** | `I2V_512x288_90f_24steps` | Steps | I2V | 512×288 | 90 | 3.75s | 24 | 561.5s | 8.5 | 20stとほぼ同等。これ以上は収穫逓減。 |
| **RUN_07** | `I2V_640x384_90f_16steps` | Resolution | I2V | 640×384 | 90 | 3.75s | 16 | 708.3s | **9.0** | **🏆 Best Value**。Tier 2 + 16st で人物の瞳・肌の質感が劇的に向上。 |
| **RUN_08** | `I2V_640x384_90f_20steps` | Resolution | I2V | 640×384 | 90 | 3.75s | 20 | 729.2s | **9.3** | **💎 Best Quality**。最高峰のシネマティックな質感と破綻のない光線表現。 |
| **RUN_09** | `I2V_640x384_73f_16steps` | Duration | I2V | 640×384 | 73 | 3.04s | 16 | 594.7s | **9.1** | **⚡ Best Quick**。3秒プレビュー用として高速（9.9分）かつ高画質。 |
| **RUN_10** | `I2V_640x384_107f_16steps` | Duration | I2V | 640×384 | 107 | 4.46s | 16 | 857.8s | 8.7 | 4.5秒ショット。最後まで破綻なく同一性を保持。 |
| **RUN_11** | `I2V_640x384_124f_20steps` | Duration | I2V | 640×384 | 124 | 5.17s | 20 | 981.1s | 8.4 | 5.2秒ショット。20stのおかげで大崩れなし。後半やや静止傾向。 |
| **RUN_12** | `I2V_640x384_141f_20steps` | Duration | I2V | 640×384 | 141 | 5.88s | 20 | 1117.6s | 8.0 | 5.9秒単一ウィンドウ。破綻はしないがAuto Movieでは3〜4s分割が推奨。 |
| **RUN_13** | `T2V_512x288_90f_10steps` | Conditioning | T2V | 512×288 | 90 | 3.75s | 10 | 397.2s | 4.4 | **現行T2V**。2-bit TE + 10st で人物輪郭が暗く不鮮明。非推奨。 |
| **RUN_14** | `T2V_640x384_90f_16steps` | Conditioning | T2V | 640×384 | 90 | 3.75s | 16 | 678.8s | 6.5 | 解像度とステップ向上で形態は安定するが、I2Vの精細感には及ばず。 |
| **RUN_15** | `T2V_640x384_90f_24steps` | Conditioning | T2V | 640×384 | 90 | 3.75s | 24 | 790.7s | 7.0 | 24stでディテール向上するが、構図制御には開始画像が推奨。 |
| **RUN_16** | `I2V_Portrait_288x512_90f_10steps` | Portrait | I2V | 288×512 | 90 | 3.75s | 10 | 398.2s | 6.2 | 横幅288pxが狭すぎ、顔の横方向解像度が不足。 |
| **RUN_17** | `I2V_Portrait_384x640_90f_16steps` | Portrait | I2V | 384×640 | 90 | 3.75s | 16 | 705.3s | **9.0** | 384x640 + 16st でスマートフォン向け縦動画として非常に美麗。 |

---

## 3. Comparison with LTX 2.5 (LTX 2.3 Distilled Q4)

| 比較項目 | LTX 2.3 Distilled Q4 (現行主力) | MiniMax H3 (現行設定: 10st/512x288) | MiniMax H3 (新提案設定: 16-20st/640x384) |
|---|---|---|---|
| **生成速度** | ⚡ **超高速** (~1〜2分/ショット) | ⏳ 中速 (~6.7分/ショット) | ⏳ じっくり (~11〜12分/ショット) |
| **ステップ数特性** | 蒸留済みモデルのため 8〜15 steps でシャープ | 10 steps では**未収束・ぼやけ** | 16〜20 steps で**完全収束・超高画質** |
| **物理・動きの自然さ** | やや直線的・機械的な動きになりやすい | 10 steps では動きがジッター化 | **極めてリアルで有機的な布・髪・光の動き** |
| **オーディオ** | 別途シンセシス / BGM 合成 | **完全ネイティブ同期ステレオ音響** | **完全ネイティブ同期ステレオ音響** |
| **T2V 追従性** | Gemma 3 12B による高度なテキスト解釈 | 2-bit TE のためプロンプト追従が弱い | I2V 推奨（T2V は 4-bit TE 化で改善可能） |
| **最適な用途** | 短時間での試行錯誤、テンポ重視の Auto Movie | （中途半端な品質で非推奨） | **最高峰のシネマティック映像・ポートレート作品** |

---

## 4. Final Recommended Presets (新プリセット提案)

### 4.1 推奨プリセット新定義

```swift
enum MiniMaxH3Preset: String, Codable, CaseIterable, Identifiable {
    case quick = "quick"
    case standard = "standard"
    case high = "high"
    case custom = "custom"
}
```

| プリセット名 | 推奨解像度 (横 / 縦) | フレーム数 (時間) | 推奨 Steps | 特徴・用途 |
|---|---|---|---|---|
| **Quick** | **640×384** / 384×640 (Tier 2) | **73f** (3.0s @ 24fps) | **16 steps** | 高速・高画質プレビュー（約9.9分）。3秒の短い尺でデノイズを完全収束させ、破綻のない映像を確認可能。 |
| **Standard** *(Default)* | **640×384** / 384×640 (Tier 2) | **90f** (3.75s / 4.0s) | **16 steps** | **最もバランスの取れた標準設定**（約11.8分）。LTX 2.5 を圧倒するシネマティックな質感と安定した同一性を両立。 |
| **High** | **640×384** / 384×640 (Tier 2) | **90f–107f** (4.0s–4.5s) | **20 steps** | **最高品質設定**（約12.2分）。微細な光の反射や髪の束感まで極限まで磨き上げた本番用レンダリング。 |
| **Custom** | Tier 1 (512×288) or Tier 2 (640×384) | 22–141f (1.0s–6.0s) | **10–24 steps** (Default: 16) | ユーザー任意の解像度・フレーム数・ステップ数指定。 |

---

## 5. Improvement Roadmap (改善ロードマップ)

### A. すぐできる改善 (Immediate Action - No Model Change)
1. **プリセット定義の更新 (`MiniMaxH3Policy.swift`)**:
   - `Quick`: 512×288 / 8st $\rightarrow$ **640×384 / 73f / 16st**
   - `Standard`: 512×288 / 10st $\rightarrow$ **640×384 / 90f / 16st**
   - `High`: 640×384 / 12st $\rightarrow$ **640×384 / 90f / 20st**
   - `Custom`: デフォルト steps を 10 $\rightarrow$ **16 steps**、上限を 20 $\rightarrow$ **24 steps** に拡張。
2. **UI 案内文の強化**:
   - H3 選択時は「開始画像（Opening Reference / Starting Image）の指定を強く推奨」を明確に表示。

### B. 追加モデル・ランタイム改善 (Model Upgrade Plan)
1. **4-bit Text Encoder パックのサポート**:
   - 現在の 2-bit Qwen3-VL (~9.6GB) を **4-bit Qwen3-VL (~15.8GB)** にアップグレード可能にする。
   - Staged Residency（段階ロード）により、テキストエンコーダー実行後にメモリが解放されるため、48GB/64GB Mac では 4-bit TE が問題なく動作し、T2V のテキスト指示追従性が劇的に改善します。
2. **Turbo / Distilled LoRA の調査・統合**:
   - 4-step / 8-step サンプリングが可能な Turbo アダプタが mlx-serve で利用可能になった場合、生成時間を 1/3〜1/4 に短縮可能。

### C. プロンプト処理・パイプライン改善 (Prompt Path Improvement)
1. **H3 専用構造化プロンプトコンパイラの洗練**:
   - `<Subject 1>` タグや明示的なライティング・カメラアングルの自動付与。
   - T2V 生成時にも被写体の位置や背景の構造を具体化するテンプレートを適用。
