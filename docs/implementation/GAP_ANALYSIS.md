# GAP_ANALYSIS — Master Implementation Prompt vs 実装状態

Date: 2026-08-08 / Basis: FINAL_IMPLEMENTATION_REPORT.md + code @ `a02ad07`
Status legend:
- **Implemented** — 実装済み・テスト済み
- **Pending (Runtime Verification)** — 実装完了、実行時検証のみ外部要因待ち
- **Partial** — 一部実装（残作業を明記）
- **Not Implemented** — 未着手（理由を明記）
- **Unsupported (capability=false)** — backend未検証のため意図的に無効（fake実装を作らない方針、§43準拠）

---

## 1. Phase 8 Advanced — 機能別ステータス（§43）

Master Promptの原則: 「backendで実際に動作確認できたものだけenable」「Official LTXに存在するからといってcapability=trueにしない」。CapabilitySetの各advancedフラグはdefault falseで、UI/APIはcapability-drivenに拒否する構造。

| 機能 | ステータス | 詳細 |
|---|---|---|
| Custom Model Import | **Partial** | Validator基盤あり（ManifestValidator: descriptor/snapshot検証、repo-id injection guard / ModelInstaller: disk preflight・license ack・revision pin）。HF repo ID / Local Folderを受け付けるimport UI・登録フローは**Not Implemented**。理由: 任意repoの安全な受け入れはLab検証フローの人間確認が前提で、GUI優先度が低い |
| LoRA | **Unsupported (capability=false)** | `CapabilitySet.lora=false`。mlx-video-with-audio 0.1.36のLoRA適用は未検証（Deep Research: current backendのOfficial機能全対応は False/Unsupported） |
| Multi-LoRA | **Unsupported (capability=false)** | 同上（LoRA単体が未検証のため多重適用も対象外） |
| Keyframes | **Unsupported (capability=false)** | `CapabilitySet.keyframes=false`。backend CLIに対応引数の存在を確認していない |
| First/Last Frame | **Unsupported (capability=false)** | `CapabilitySet.firstLastFrame=false`。同上 |
| Continuation | **Unsupported (capability=false)** | `CapabilitySet.continuation=false`。同上 |
| Retake | **Implemented（service層）** | `TakeGenerationCoordinator.planTakes` は既存Shotへの追加呼び出しで新seedのTakeを追加可能＝Retake相当。専用「Retake」ボタンUIは無し（GUI課題としてPartial扱いも可） |
| Upscale | **Unsupported (capability=false)** | `CapabilitySet.upscale=false`。backendに実行経路が未検証 |
| Shot-level Model Override | **Not Implemented** | Shot構造体にmodelID overrideフィールド無し（modelはProjectSettings単位）。理由: モデル切替はunload/reclaimが未検証（Research仮説S=Unknown）で、Shot単位切替はメモリ安全性検証が先 |

**Unsupported各項目の解除条件**: backend CLIでの実行経路確認 + smoke test → CapabilitySetをtrueへ + capability-driven UIの追加。検証まではUI/APIに露出しない（現状維持で仕様準拠）。

---

## 2. Phase 0–7 未完了項目（全列挙）

### Pending (Runtime Verification) — 外部要因、ハーネス完備
| # | 項目 | Master Prompt節 | 待ち要因 / 解除手順 |
|---|---|---|---|
| P1 | 10Eros v1.2 Q8 / v1.3 DMD Q4 の runtime verification（11-check gate 0/11） | §25-26 | 数十GB download承認。手順: MODEL_COMPATIBILITY.md「Verification workflow」 |
| P2 | 16GB Compact ladder 実測（C0→C1→C2→audio） | §30 | 16GB実機。`scripts/lowram_bench.sh` |
| P3 | Low-RAM adapter runtime統合（verified前は意図的に実行拒否） | §30 | P2完了後に `lowRAMBackendVerified` を有効化して統合コードを実装 |
| P4 | フル20-take queue soak（3-takeは実施済み、peak横ばい） | §47 | `scripts/queue_soak.sh 20`（約17分、人間実行可） |
| P5 | .appバンドルbuild / 署名 / notarization | §26 | Xcode.app（+Developer ID）。pbxproj登録済み |
| P6 | REST API socket越しE2E（curl）・non-loopback拒否のsocketレベル確認 | §46 | 実行中のGUIアプリが必要（ロジック層は全unit-tested） |
| P7 | Ollama providerの実機動作確認（template fallbackは検証済み） | §31(v0.5)/§17 | Ollama+モデルのinstall（ユーザー任意） |

### Partial — 実装済みだが残作業あり
| # | 項目 | Master Prompt節 | 残作業 |
|---|---|---|---|
| G1 | Requested / Effective / Actual 解像度の**UI表示** | §31 | metadata記録・API返却は済み。HistoryView/生成画面に3値表示が無く、64-px roundingがUI上はまだsilent |
| G2 | Resume後の自動再enqueue | §35 | reconcileはstatus=queuedへ戻すが、GenerationServiceへの自動再投入は無し（現状は手動re-plan）。データ整合は保証済み |
| G3 | peakMemory / swapPeak のruntime自記録 | §18/§33 | GenerationResult/Takeにフィールドはあるがbridge非対応でnil（実測はharness側で取得）。bridgeへのtask_info注入は薄い変更で可能だが未実施 |
| G4 | Storyboard専用workspace UI | §31/§36 | service層+テストは完全。GUIはOne Shot Directorのみで、Storyboard/Shot/Take/選択/AssemblyのGUIが無い（現状はAPI/コード経由） |
| G5 | AI撮影チームの役割分割（Director/Screenwriter/Continuity/Cinematographer/Audio/QC） | §36 | 単一providerの**1回のstoryboard呼び出し**に統合実装。役割ごとの逐次呼び出しには未分割（heavy LLM同時常駐禁止は満たす）。QC相当はContinuityEngine/monotonyがdeterministicに担当 |
| G6 | Global BGM の Final Assembly 適用 | §38 | `ProjectSettings.globalBGMGenre` フィールドのみ。Assembly後の最終ファイルへのBGM mux未実装（既存AudioService.addMusicToVideoの手動適用は可能）。Shot単位BGM禁止は遵守 |
| G7 | Take UI（favorite/rating/notes編集） | §33 | データモデル・永続化は完備。編集UIなし |
| G8 | Adult model install GUIフロー（Model Card表示→Explicit Install→Checksum） | §26 | ModelInstaller（plan/record/license ack/checksumフラグ）とLab表示は済み。ダウンロード実行UIは無し（意図的: 明示承認が前提のため人間手順として文書化） |
| G9 | Advanced設定としてのQuality「Advanced」表示 | §27(v0.5)/§31 | Advancedモード自体は実装（=手動パラメータ、AutoQualityが不介入）。既存Parameters UIがその役割を担い、専用画面は無し |

### 仕様と異なる実装判断（Decision Logged、逸脱ではない）
| # | 項目 | 判断 |
|---|---|---|
| D1 | エラー型: 提案の`LTXAppError`巨大enumではなく既存`LTXError`+目的別error型（ModelPolicyError等）で統合 | §27の「既存error typeと統合し重複させない」に従った |
| D2 | fallback順は初期値どおり（memoryOpt→frames→resolution→…） | §29。実測でresolution優位の証拠が出ておらず入替なし |
| D3 | legacy APIServer(8420)は無変更のまま残置 | §4互換性優先。**既知リスク**: wildcard CORS・token無し・全interface bind（upstream由来）。ただしUIトグルでopt-in（default OFF）。v1(8421)が推奨surface。将来はv1有効時にlegacy非推奨警告を出すのが望ましい |
| D4 | Official modelのrevision pin | §3。公式カタログはupstream追従（pin無し）。render時のHF_HUB_OFFLINE運用はharnessで実証、アプリ本体のlocal_files_only強制は未実装（cache完備時は事実上オフライン） |

### 完了確認済み（主要Acceptance）
- Official fast path regression 0%（同一seed MD5一致）/ all-flags-OFF = legacy path
- Registry / Adapter / Metadata migration / Feature flags 9種 / MediaProbe
- Auto+High+Compact+fallback+履歴学習 / HardwareProfiler / MemoryMonitor
- One Shot Director（plan→compile→request、LLM分離）
- FilmProject/Shot/Take 1–20 sequential / persistence / resume（データ層）
- Story Bible / Character Bible / deterministic continuity / validator / Assembly（実MP4で検証）
- API v1（token/loopback/sandbox/policy/≤20）+ OpenClaw extras
- Adult Mode policy 5-case matrix（UI/Service/API各層）
- Unit 242 checks / integration（実生成4本+regression+soak3）/ security(unit) / benchmark harness一式

---

## 3. 整合性確認結果（2026-08-08, `a02ad07`）
- `swift build`: clean
- `swift run LTXTests`: 242 passed, 0 failed
- `git status`: clean / 全9 commits green
- pbxproj: plutil OK、新規26ファイル登録済み
- ドキュメント: CURRENT_STATE / BASELINE / DECISION_LOG / IMPLEMENTATION_PLAN / TEST_MATRIX / MODEL_COMPATIBILITY / BENCHMARK_RESULTS / OPENCLAW_API / FINAL_IMPLEMENTATION_REPORT / GAP_ANALYSIS（本書）/ GUI_ACCEPTANCE_CHECKLIST — 相互参照一致
