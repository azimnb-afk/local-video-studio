# GUI Acceptance Test Checklist（Xcode導入後の人間最終確認）

前提: Xcode.appをインストールし、`LTXVideoGenerator/LTXVideoGenerator.xcodeproj` を開いてbuild/run。
Python: `~/ltx-venv/bin/python3`（設定済みのはず）。モデル: ltx23_distilled_q4（キャッシュ済み）。
所要目安: フル実施 約60–90分（生成待ち含む）。各生成は512×320/25f/15stepsなら1分弱。

判定原則: **requested値ではなく実MP4（ffprobe）と実挙動が基準。**

## 2026-08-09 Phase A1 First Run / Dependency Onboarding Acceptance

- [x] Canonical Debug app built with Xcode 26.6 (`xcodebuild -scheme LTXVideoGenerator clean build` → BUILD SUCCEEDED).
- [x] Subprocess Python validation: verifies Python executable, version 3.11+,
  `mlx_video.generate_av`, and the LTX text-encoder import. `torch` and
  `diffusers` are not core MLX-video readiness gates.
- [x] Auto-detection recovery path: if configured `pythonPath` is deleted or invalid, `DefaultPythonChecker` automatically executes `autoDetectPython()` as a recovery path.
- [x] DependencyHealthManager aggregates statuses (`.python`, `.ffmpeg`, `.videoModel`, `.textEncoder`, `.localDirector`, `.vision`).
- [x] Required vs Optional: Python, FFmpeg, Video Model, and Text Encoder are Required (`isGenerationReady = true` when all 4 ready); Ollama and Local Vision are Optional.
- [x] Non-blocking onboarding: SetupWizardView is displayed on launch if required dependencies are missing, but users can click "Continue to App" to browse Archive, existing Projects, CharacterBible, and Settings.
- [x] Unified Generation Gating: All generation triggers across all UI views (Generate, Add to Queue, Batch, One Shot, Storyboard Take, Generate Missing Takes, Regenerate Selected Shots, Hybrid auto generation, Retake, History) check `isGenerationReady` and open `SetupWizardView` when incomplete.
- [x] Timeouts: Subprocess and HTTP checks (Ollama/localhost) utilize timeouts (15s / 5s) to guarantee no infinite spinners or MainActor thread blocking.
- [x] Legacy Alert Replacement: Removed legacy `showPythonSetupAlert` and `launchPackageUpgradeMessage` alerts; `SetupWizardView` displays detailed package/dependency diagnostic copy and directs users to Preferences.
- [x] Privacy & Safety: No silent network access, automatic pip/brew installs, or background model downloads. Diagnostics copy contains zero secrets or tokens.
- [x] Unit Test Suite: 598 passed / 0 failed in `swift run LTXTests`. TestKit test harness handles async MainActor dispatch via `RunLoop.main` without deadlocks.

## 2026-08-09 Phase A2 Release local-test runtime acceptance

- [x] Exact Release artifact launched by full path, not `open -a`:
  `build/LTXVideoGenerator.app` from HEAD
  `62d198ee2fe66c89482ae6f19ee712412a50abc3`; executable mtime
  `2026-08-09 20:49:42 +0900`; PID `84763` resolved to that executable.
- [x] Settings → Validate Setup used the external
  `/Users/azimnb/ltx-venv/bin/python3` and displayed **Python 3.14.5
  configured with MLX** / **MLX Ready**.
- [x] Generate, One Shot, Storyboard / Director, Hybrid, Video Archive, and
  Settings opened in the Release local-test app.
- [x] One existing-cache render completed through the Release app's external
  Python/MLX path. Archive count increased from 117 to 118; output
  `295A5926-B886-4A10-817B-3668C68CB705.mp4` is H.264, 512×320, 24 fps,
  2.708333 seconds, 228,392 bytes. No MLX child remained afterward.
- [x] External FFmpeg `8.1.1` was available. Existing Ollama localhost models
  were reachable and did not block video readiness.
- [x] The app displayed a high-memory warning because persisted Custom values
  yielded 512×768 / 121 frames / 30 steps even while Quick Preview was selected;
  no second render was queued. This is a pre-existing preset-state issue outside
  the Phase A2 packaging scope, not a Hardened Runtime failure.
- [x] Release local-test artifact is ad-hoc signed and therefore expected to be
  rejected by Gatekeeper. It is not a distribution claim.

## 2026-08-09 Preset effective-settings regression acceptance

- [x] Root cause confirmed: Quick was correctly resolved by
  `GenerationSettingsResolver` for the renderer, but the Generate preflight
  warning and queue displayed stale Custom `GenerationParameters`.
- [x] Canonical Debug app launched by its full DerivedData path from HEAD
  `09ef2a7b5108de64314c75354ef7bcdcd5af3914`; executable mtime
  `2026-08-09 21:20:37 +0900`; running PID `86234` resolved to that path.
- [x] Generate visibly reported Quick Preview → **C3** (512×320 / 49 frames /
  15 steps), Standard → **S0** (768×512 / 73 frames / 25 steps), High Quality
  → **H0** (768×512 / 121 frames / 30 steps), and Custom exposed the retained
  manual controls.
- [x] Quick Preview remained selected and C3 remained visible after close and
  relaunch of that exact app.
- [x] No render was queued: the canonical app reported MLX Environment Not
  Ready, and the audit's resolver, queue, and persisted-Take tests cover the
  non-rendering settings path. No model or encoder download was started.
- [x] `swift build`; `swift run LTXTests` = **643 passed / 0 failed**;
  Xcode Debug clean build = **BUILD SUCCEEDED**; `git diff --check` passed.

---

## 2026-08-08 GUI-first completion verification

- [x] Final Debug `.app` built with Xcode 26.6 and launched.
- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Hybrid.
- [x] Generate shows Preset (Quick Preview / Standard / High Quality / Custom) instead of primary Quality picker.
- [x] One Shot is an independent screen with Brief / Preset / Model / Target Duration / Audio / Create & Generate.
- [x] Storyboard Project Settings shows Preset / Model / Audio; Custom reveals Resolution / Frames / FPS / Steps and Requested→Effective→Actual text.
- [x] Storyboard exposes Generate Missing Takes, per-shot current-Preset regeneration, multi-shot regeneration, Take selection and Final Assembly reachability.
- [x] Hybrid creation sheet shows Brief / Preset / Model / Audio / Target Duration / Create & Generate; orchestration split/state is unit-tested.
- [x] `swift run LTXTests`: 331 passed, including final Quick/Standard/High request comparison, duration propagation, Preset mapping, Project Settings persistence, Preview Take retention and Hybrid split.
- [x] Final Debug app launched; One Shot's independent Preset changed to Quick while Generate remained Standard.
- [x] Archive UI reproduced the old regression: Quick C3 and Standard C3 were identical; High was H0.

This pass intentionally did not enqueue another heavy LTX render. The existing real-generation/MD5/API/MediaProbe regression evidence below remains the Official fast-path baseline.

---

## 2026-08-09 Storyboard encoder investigation

- [x] Ollama created a three-shot Storyboard with Quick Preview, Official LTX-2.3 Distilled Q4 and Audio ON.
- [x] The first queued Take resolved Quick Preview to 512×320 / 121 frames / 24 fps / 15 steps, confirming Preset and duration propagation.
- [x] Root cause isolated: new Storyboard/Hybrid projects used the `ProjectSettings` schema default (`gemma3_12b_bf16`) instead of the current `selectedTextEncoderID` (`gemma3_12b_4bit`).
- [x] New Storyboard and Hybrid projects now inherit the same current text-encoder selection used by Generate and One Shot; regression test added.
- [x] Cancel now terminates the Python wrapper and its `mlx_video.generate_av` child instead of leaving the download/render alive.
- [x] Re-ran all three Quick Preview Takes sequentially, regenerated only the final shot at High Quality, retained both final-shot Takes, selected High, and assembled the final MP4.

The affected project still has its original persisted BF16 snapshot and was not reused or migrated. Disk cleanup restored about 66 GiB free while preserving the completed Q4 model and 4-bit encoder caches.

### Real GUI E2E evidence

- [x] Canonical app provenance captured: HEAD `3b5782b652d13bb42a8f771d9451d2d803a9a18b`; app `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`; executable mtime `2026-08-09 03:31:30 +0900`; running PID 52199 used that exact executable path.
- [x] Before/after free disk: 66 GiB / 66 GiB. Cache sizes: Official Q4 about 20 GiB; Gemma 12B 4-bit about 7.5 GiB. BF16 12B download: **NO**. Unexpected large download: **NO**. Remaining `.incomplete`: **none**.
- [x] A new pure Storyboard (`5EA7ED62-B8D4-4532-BA6A-26DA1C3B56EF`) stored `ltx23_distilled_q4` + `gemma3_12b_4bit`. The configured Ollama model failed strict plan-schema validation, so template fallback produced one shot; it was not used as the three-shot production project.
- [x] New three-shot Hybrid/Storyboard production project `2B81DA40-9886-4733-A4AC-4E8879FC44DD` used the same shared ProjectSettings, StoryboardDirector, sequential Take queue, regeneration, selection, and assembly paths. Audio ON; target duration 15 s.
- [x] Generation log resolved `notapalindrome/ltx23-mlx-av-q4` and `mlx-community/gemma-3-12b-it-4bit`; cache snapshot checks completed immediately. No BF16 repo was selected.
- [x] Quick Shot 1: C3, requested 768×512, effective/actual 512×320, 121f @ 24fps, 15 steps, audio, 5.01 s, 129.48 s generation, seed 1153703474.
- [x] Quick Shot 2: C3, requested 768×512, effective/actual 512×320, 121f @ 24fps, 15 steps, audio, 5.01 s, 128.79 s generation, seed 1405865902.
- [x] Quick Shot 3: C3, requested 768×512, effective/actual 512×320, 121f @ 24fps, 15 steps, audio, 5.01 s, 128.68 s generation, seed 1195254423.
- [x] High Shot 3 only: H0, requested/effective/actual 768×512, 121f @ 24fps, 30 steps, audio, 5.01 s, 278.47 s generation, seed 1924045886. Encoder remained 4-bit. The Quick Shot 3 take remained present and High was selected.
- [x] Final selection order: Quick / Quick / High. Final MP4 `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/2B81DA40-9886-4733-A4AC-4E8879FC44DD_final.mp4` exists; H.264 768×512; 15.060667 s; AAC stereo 48 kHz. QuickTime playback progressed and ended normally.
- [x] Final cancellation probe: wrapper PID 52241 and child PID 52243 stopped; GUI showed cancelled without an error alert; project `F466A6E9-9C02-4AC4-8AC8-6FE27B87816B` persisted Take and Job as `cancelled`; residual generation/download process: **NO**.
- [x] Final validation: `swift build`; `swift run LTXTests` = 335 passed / 0 failed; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean.

## 2026-08-09 Pure Storyboard structured-output acceptance

- [x] Reproduced the original response before parser changes with the exact sea-side Brief and `qwen3.6-claw-fast:latest`: Ollama `response` was empty and `thinking` contained valid exact-schema JSON for three shots.
- [x] Classified the original failure as Ollama envelope extraction/no-response handling, before JSON extraction, Codable decode, schema validation, or semantic validation.
- [x] Ollama requests now use `format: json` plus `think: false`; non-empty `thinking` remains a compatibility fallback, without a qwen/model-name-specific branch.
- [x] Direct JSON, fenced JSON, prose prefix/suffix, balanced-object extraction, conservative trailing-comma/field-alias repair, missing required fields, invalid syntax, no response, bounded repair success, bounded repair failure, provider unavailability, and Basic fallback are covered by tests.
- [x] Failure diagnostics distinguish request, no response, extraction, syntax, Codable decode, schema, semantic, deterministic repair, retry, and template fallback stages.
- [x] New project `2274CB69-B651-4C1F-A9B5-2BF975E00023` was planned from the same Brief by Local AI, not Basic fallback: `directorProvider=ollama`, `directorModel=qwen3.6-claw-fast:latest`, `planningMode=ai`, `fallbackReason=null`.
- [x] GUI displayed `Director: Local AI qwen3.6-claw-fast:latest` and exactly three 5-second shots: The Walk, The Pause, The Smile.
- [x] Every shot had a non-empty compiled prompt; continuity carried the same character/outfit/location/time and propagated explicit position changes across shot boundaries.
- [x] Project retained `ltx23_distilled_q4` + `gemma3_12b_4bit`; no BF16 selection and no model download occurred.
- [x] Ollama had no loaded model after planning. Existing Basic/template fallback remains available when Ollama is absent or repair fails.
- [x] Canonical app provenance: executable mtime `2026-08-09 08:11:28 +0900`; PID 58415 executable `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app/Contents/MacOS/LTXVideoGenerator`.
- [x] Final automated validation: `swift build`; `swift run LTXTests` = 368 passed / 0 failed; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean.

No new LTX render was queued for this Planning-only acceptance. The same downstream 4-bit Quick/High queue, retake, mixed-resolution assembly, and cancellation paths had already passed real E2E immediately before this fix and were deliberately left unchanged.

## 2026-08-09 Zero-setup Director UX acceptance

- [x] New users default to Director Auto; the Storyboard sheet exposes only Auto / Local AI / Basic plus friendly status copy.
- [x] Settings has a Director tab with mode, readiness, installed-model picker, Refresh Models, Test, and Advanced-only endpoint/technical details.
- [x] `/api/tags` populated the picker with ten existing models, including `qwen3.6-claw-fast:latest`; no shell `ollama list` call is used by the app.
- [x] GUI model selection persisted through the existing `directorOllamaModel` key. A temporary selection change was observed in UserDefaults and the preferred qwen-fast selection was restored.
- [x] Test returned `Local AI Director is ready (qwen3.6-claw-fast:latest)` and `/api/ps` was empty afterward.
- [x] Auto + Local AI created project `668BCE7F-D25C-4AB8-A68C-24FDDA280181`: 3×5 s, requested Auto, effective Local AI, planning AI, fallback nil.
- [x] Explicit Basic with Ollama running created project `93CA9860-CF98-4009-9D81-F600873DC397`: 3×5 s, requested/effective Basic, template provider, no fallback reason; UI displayed `Director: Basic`.
- [x] Homebrew Ollama service was stopped safely. Auto displayed Basic/No setup required and created project `B37EC01D-47A1-441F-A9D1-2B22210A8DC6`: 3×5 s, requested Auto, effective Basic, planning fallback, `localAIServerUnavailable`; no blocking alert.
- [x] Ollama service was restored to started; Director mode is Auto, preferred model is qwen fast, and no Ollama model remains loaded.
- [x] All projects retained Official Q4 + Gemma 12B 4-bit. No model download, BF16 selection, LTX render, OpenClaw connection, or cloud fallback occurred.
- [x] Existing FilmProject JSON without the optional requested/effective fields remains decodable; new metadata persists across store reload.
- [x] Canonical app provenance: base HEAD `da86397` plus reviewed worktree; executable mtime `2026-08-09 08:45:59 +0900`; running PID 59844 executable `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app/Contents/MacOS/LTXVideoGenerator`.
- [x] Automated validation: `swift build`; `swift run LTXTests` = 396 passed / 0 failed; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean.

## 2026-08-09 CharacterBible Phase 0 acceptance

- [x] Audited and preserved existing CharacterProfile; expanded the existing CharacterBible stub instead of introducing a competing model. No automatic profile migration occurred.
- [x] Storyboard and Hybrid creation sheets expose Characters, Add Character, and the Phase 0 form fields/trait locks with the textual-guidance limitation clearly stated.
- [x] Pure Storyboard project `F9C4AC55-B1A4-4962-9869-FBE477A8B6B2` was created through Basic Director from the requested First/Next/Finally Brief and produced exactly three shots.
- [x] All three Storyboard shots reference stable UUID `C7133C84-7791-4F7F-AFC8-0A31ADD2A140`, not a name string.
- [x] Renaming Adventurer Heroine to Maya preserved all three UUID references; Shot UI and compiled prompts resolved the new name.
- [x] Quit and exact-path relaunch restored the CharacterBible, Maya, every Shot assignment, locks, and compiled prompts.
- [x] Compiled prompts contain compact face/hair/eyes/default-costume/continuity guidance and exclude planning-only personality text; the Bible is not dumped wholesale.
- [x] Hybrid project `9F8F7FF6-852E-48EF-9627-E9A9A8D65D7C` used the same shared Bible/planner/continuity/compiler path; all three shots reference UUID `B04A90CE-85AA-40AE-9121-E370FA1BFAA5`.
- [x] Hybrid Shot assignment removal removed the Maya prompt block; re-adding Maya restored it. No separate Hybrid character model exists.
- [x] Added and deleted a temporary character through the confirmation alert. The final project contains only Maya and no dangling Shot IDs; Takes would be preserved.
- [x] Hybrid planning-only acceptance left Jobs and Takes empty. The production default still generates the first pass unless the user explicitly turns that option off.
- [x] Reference asset model/storage boundary is present, but GUI makes no face lock, identity guarantee, image analysis, or conditioning claim.
- [x] No Vision/face pipeline, cloud request, Ollama pull, Hugging Face download, LTX generation process, or loaded Ollama model was introduced during acceptance.
- [x] Canonical app was launched by full path: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`. Final checkpoint HEAD, executable mtime, and running path are captured after the committed rebuild.
- [x] Automated validation: `swift build`; `swift run LTXTests` = 444 passed / 0 failed; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean.

---

## A. Regression — 全flag OFF = 従来動作（最優先）

- [ ] A1. 初回起動: Preferences → Models & Features の全トグルがOFF、Adult Content ModeがOFFであること
- [ ] A2. T2V生成（prompt任意、seed **42**、512×320/25f/15steps/24fps/audio ON）が完了しHistoryに追加される
- [ ] A3. 生成物を `md5 <出力mp4>` で確認 → 同一設定のbaseline（`bf8020b1f55f73a62c075f2df1c65a8d`、prompt: "A small red fox walks slowly through a snowy forest clearing, soft morning light, gentle camera pan, cinematic."・negative無し・tiling auto・cfg 3.0の場合）と一致
- [ ] A4. I2V生成（画像ドロップ→生成）が完了する
- [ ] A5. Audio OFF（Generate Audioを無効化）で音声トラック無しのMP4になる（QuickTime/ffprobeで確認）
- [ ] A6. 旧バージョンで作成したHistory / Preset / CharacterProfileが壊れず読み込める（既存ユーザー環境で起動して確認）
- [ ] A7. 3 variations / 5 variationsが**1件ずつ順番に**処理される（同時に2つ進行しない）
- [x] A8. 生成中のCancelが効き、wrapper/MLX child停止後にアプリが正常状態へ戻る（Storyboard実生成で確認）

## B. Feature Flags / Preferences

- [ ] B1. Models & Featuresタブが表示され、9個のflag+Adult Modeトグルが操作できる
- [ ] B2. Compatibility Lab欄に10Erosの2モデルが「Unverified」「Gate: 0/11 passed」で表示される
- [ ] B3. 全flagをONにした後、全flagをOFFに戻す → A2同等の生成が引き続き成功する（rollback確認）
- [ ] B4. Adult Mode OFFのまま何も変わらないこと（modelピッカーにadult modelが現れない）

## C. Model Registry（modelRegistryV1 ON）

- [ ] C1. flag ONで従来どおりT2V生成が成功する（経路: Registry→Adapter→同じLTXBridge）
- [ ] C2. 生成後のHistory項目にmetadata（quantization: q4等）が記録されている（history.jsonを直接確認可）
- [ ] C3. derivedModelsV1のみON（adultModelsV1 OFF）→ 10Erosがモデル選択に**出ない**
- [ ] C4. derived+adult flag ON + Adult Mode ON → 10Erosが選択肢に出るが、生成は「未検証(unverified)」エラーで**拒否**される

## D. Preset / Auto Quality（autoQualityV1 ON）

- [x] D1. 生成ボタン付近にPreset（Quick Preview/Standard/High Quality/Custom）が表示され、通常Quality pickerは露出しない
- [x] D2. 最終request比較: 48GB機のStandardはS0（768×512/25steps）、HighはH0（768×512/30steps）へ明確に分離される
- [x] D3. Compact成功だけではStandardをCompactへ固定しない。S0の最新失敗がある場合だけ既知safe profileへfallbackし、reasonを保存する
- [x] D4. Compact選択→512×320になり、ffprobeの実解像度が512×320
- [ ] D5. Advanced選択→手動パラメータが**一切変更されない**
- [x] D6. target 5s、同一seed/model/audioで Quick=C3 / Standard=S0 / High=H0、全て121f（duration制約維持）
- [x] D7. One Shot / Storyboard / Hybrid / APIのdurationがprofile適用後もframesへ反映され、Customは手動framesを保持する
- [x] D8. History/Take metadataにeffective profile reason、target/requested duration、audio、sourceを保存する

Post-fixの新規実生成を2026-08-09に実施。Quick C3は3本とも512×320/121f/24fps/15 steps、High H0は最終Shotのみ768×512/121f/24fps/30 stepsとなり、実MP4 metadataとGUI Take metadataが一致した。

## E. One Shot Director（directorV1 ON）

- [ ] E1. Prompt欄の下に「One Shot Director」disclosureが表示される
- [ ] E2. Brief入力→「Plan Shot」→ Prompt欄がcompileされた英語フロー記述で置き換わる（Ollama未導入なら「Planned via template」）
- [ ] E3. 日本語台詞をBriefに含める → compiled promptに台詞が原文のまま残る
- [ ] E4. Ollama導入済み環境の場合: `ollama ps` でplanning後にモデルがunloadされている（keep_alive:0、LTX render前にメモリ返却）

## F. FilmProject / Take（filmProjectV1 ON）※GUI未実装領域はスキップ可

- [ ] F1. GUI上の専用画面は無い（GAP_ANALYSIS G4）。スモークとして: 生成完了後も従来機能に影響がないこと
- [ ] F2. （API/コード経由でTakeを作った場合）アプリ再起動で `Projects/*.json` のin-flight takeがqueued/completedへ正しく復元される

## G. Local REST API v1（localAPIv1 ON、要アプリ再起動）

ターミナルで:
```bash
TOKEN=$(cat ~/Library/Application\ Support/LTXVideoGenerator/api_token)
```
- [ ] G1. `curl -s http://127.0.0.1:8421/v1/models` （token無し）→ **401**
- [ ] G2. `curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8421/v1/system | jq` → hardware/memory/generatorが返る
- [ ] G3. `curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8421/v1/models | jq` → officialモデルのみ（flag状態に応じ）
- [ ] G4. jobs POST（extras/openclaw/README.mdのT2V例）→ 201 + jobID → GUIのQueueに現れ生成される → `GET /v1/jobs/<id>` がcompleted+actual metadata
- [ ] G5. `variations: 21` を送る → 400
- [ ] G6. 別マシン/`ifconfig`のLAN IPで `curl http://<LAN-IP>:8421/v1/system` → **接続不可**（loopback bind確認）
- [ ] G7. adult model IDを指定したjob → **403**（Adult Mode OFF時）
- [ ] G8. レスポンスヘッダに `Access-Control-Allow-Origin` が**無い**こと（`curl -sI` 相当で確認）
- [ ] G9. flag OFFで再起動 → 8421が閉じている。GUI生成は正常（API非依存確認）

## H. 生成中ネットワーク監査（Local-only）

- [ ] H1. モデルキャッシュ済み状態でWi-Fiを切って T2V生成 → **成功する**（render時外部通信なしの実機確認）
- [ ] H2. 生成中に `nettop -p <python pid>` 等で外部宛通信が無いことを目視（任意、H1で代替可）

## I. 安定性

- [ ] I1. 20 variationsを投入 → 全件sequential完了、Activity Monitorでpeakメモリが件数とともに増加し続けないこと（±10%以内）
- [ ] I2. 生成中にアプリを強制終了→再起動 → クラッシュ/データ破損なし、History整合
- [ ] I3. Preferencesの全タブを開閉してもクラッシュなし（新規Models & Featuresタブ含む）

## 判定
- A群（regression）が1つでもFAIL → **リリース不可**。`git diff a441dc2` で原因を特定するか、flags OFFのまま利用
- B–G群のFAIL → 該当feature flagをOFFにして隔離し、issueとして記録（アプリ全体は出荷可能）
- 結果はTEST_MATRIX.mdの該当行を PASS/FAIL に更新してcommitすること

## J. CharacterBible Phase 1 — Character Sheet Import（2026-08-09）

- [x] Canonical DerivedData appをフルパス指定で起動し、Storyboard / Hybrid共通Characters UIに`Import Character Sheet`が表示されることを確認。
- [x] 1600×1600 synthetic PNGを選択。外部sampleが実行環境から取得できなかったためdownloadは行っていない。
- [x] Project-owned copyをUUID filenameで作成。元画像・managed copyのSHA-256が一致し、元画像は変更されていない。
- [x] Preferences > AnalysisでAuto / Local Vision / Manual、独立Vision model picker、reported capability方針、no-auto-download、local/privacy/非identity-conditioning表示を確認。
- [x] Autoはinstall済み`agents-a1:32k`を使用。1 repair後もrequired appearance structure不足だったためManual Reviewへfallbackし、Ollamaはunload済み（`/api/ps` empty）。
- [x] Review前にBibleへ確定されず、Mayaへ編集後にCreate Character。Face/Hair/Eyes/Costume/Accessories、detected views/expressions、Character Sheet asset metadataを保存。
- [x] Existing Character更新ReviewでCurrent/Detectedを分離し、既存non-empty fieldがすべてdefault OFF。Cancel後、staged managed copyだけが削除され既存assetと外部originalを保持。
- [x] Storyboard project `7F85893F-D234-41BC-97ED-635D4EAA533A`でcompiled promptへreview済みvisual dataを反映。sheet image bytesはLTXへ渡していない。
- [x] 段落区切りBriefのproject `7DDDD8E2-C149-41CB-B49C-08A3CD7CDEC7`で3 shots。全Shotが同じMaya UUID `9C0C46EE-DBF7-4F0B-BCA2-9C576618FD1B`を参照。
- [x] MayaへFace/Hair/Eyes lockを明示設定し、compiled promptでvisual fields、costume、accessories、textual lock guidanceを確認。
- [x] App quit/relaunch後にproject、3 shots、UUID assignment、Character Sheet metadataを復元。Hybrid既存projectにも同じshared import controlを確認。
- [x] `swift build`; `swift run LTXTests` = 498 passed / 0 failed; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean。
- [ ] Exact user sampleによるVision extraction品質E2Eはsample未アクセスのためPending。Local provider/schema failureからManual Reviewまでのproduct fallbackはPASS。

## K. CharacterBible Phase 2 — Reference Extraction（2026-08-09）

- [x] Exact user sample 1086×1448 PNGをcanonical DerivedData appへimportし、project-owned originalのSHA-256が外部sourceと一致することを確認。
- [x] Installed `agents-a1:32k`でDetect References。Front / Side / Back / Expression / Costume Detailの5 proposalを取得し、model download/cloud/OpenClawなし。
- [x] 実画像localizationを **C: semantic detectionは可能だがbounding boxは不安定** と判定。Side/Backは近似、Front/Expression/Costumeは手動補正、Faceはmanual cropで追加。
- [x] Overlay、checkbox/remove、Reference Type変更、label変更、numeric rect、drag resize、manual Add Reference Cropを実GUIで確認。Vision proposalをtruthとして即保存しない。
- [x] Normalized `x/y/width/height`、0...1、top-left originを表示・永続化。補正済みauto proposalは`visionProposedUserAdjusted`、manual Faceは`manual`として保存。
- [x] ORIGINAL 1086×1448からFront 287×774、Side 174×751、Back 272×769、Expression 191×228、Costume Detail 145×202、Close-Up 344×499のPNGを生成。analysis derivativeからのcrop/upscaleなし。
- [x] 全assetが`Projects/<ProjectID>/Assets/Characters/<CharacterID>/References/<UUID>.png`に存在し、sourceAssetID、sourceCropRect、source dimensionsを持つことをJSON/file inspectionで確認。
- [x] Review Cancel時にderived file/metadataなし。Save後はCharacter Editorにefficient thumbnailとdelete controlを表示。source sheetとderived assetの削除責務を分離。
- [x] App quit/relaunch後、Character Sheet + 6 referencesのthumbnail/type/dimensionsを復元。Shotのstable Character UUIDとcompiled textual promptも維持。
- [x] Vision modelは検出後にunload。LTX generation、PromptCompilerへのpath注入、identity conditioning、face recognition、cloud、downloadはなし。

## L. CharacterBible Phase 4 — Starting Image Bridge（2026-08-09）

- [x] Storyboard / Hybrid共通のShot UIに`Starting Image`セクションが追加され、Character別にグループ分けされたDerived Reference Assets（Front, Side, Back, Face, Expression, Costume Detail）から最大1枚をStarting Imageとして選択できることを確認。
- [x] Raw Character Sheetオリジナルは候補Menuに露出しない。
- [x] 選択中Starting Imageのサムネイルが即時表示され、`None`選択・クリアボタンで解除できることを確認。
- [x] Shot 1にMaya Front, Shot 2にMaya Side, Shot 3にNoneを設定してProject保存。アプリ終了・完全再起動後、各ShotのStarting Image選択状態とサムネイルが正常に復元される。
- [x] `TakeGenerationCoordinator.planTakes`にて、`Shot.startingImageReferenceAssetID`からプロジェクト所有の絶対パスが解決され、`GenerationRequest.sourceImagePath`および`Take.sourceImagePath`へマッピングされることを確認。
- [x] 存在しないAsset IDや実ファイル消失時、silent T2V fallbackを起こさず明示的な `CoordinatorError`（`startingImageNotFound` / `startingImageUnavailable`）がスローされる。
- [x] キャラクターや参照アセット削除時、`sanitizeStartingImageReferences()`によりdangling IDが安全に除去される。
- [x] UIおよびコード上の用語は`Starting Image`に統一。`Face Lock`, `Identity Lock`, `Same Face`, `Same Person`, `Character Identity Conditioning`等の不適当な用語が存在しないことを確認。
- [x] `swift build` PASS; `swift run LTXTests` = **575 passed / 0 failed**; Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean。

## M. CharacterBible Phase 6B — Production UX / Final Polish & Acceptance（2026-08-09）

- [x] StoryboardおよびHybridのShot UIにおいて、Starting Imageの標準デフォルトおよび「未選択」表示が `None (Recommended)` と表記され、文字プロンプト主体の生成を推奨することが明確に示される。
- [x] Starting Image選択Menuが `Recommended Anchor (Front)`, `Other Views (Side / Back)`, `Advanced (Face / Close-Up, Expression, Costume Detail)` の3カテゴリーに整理され、Character Sheet原紙は露出しない。
- [x] Frontには `Recommended Anchor` バッジ、Faceには `Advanced` バッジが適切に表示される。
- [x] Trait Locksの表示名が `Facial Features`, `Hair`, `Eyes`, `Body Appearance`, `Costume`, `Accessories` に更新され、ヘッダー `Keep Consistent` の下に配置されている。
- [x] 禁止用語（`Face Lock`, `Identity Lock`, `Same Face`, `Same Person`, `Identity Reference`, `Multi-view Identity`）がGUIおよびソースコード上に一切存在しない。
- [x] Starting Image選択時にカメラ構図・初期フレーム影響に関するインラインガイダンスが表示され、Face選択時に `Close-up starting images strongly constrain camera framing` 警告が表示される。
- [x] `AspectMismatchCalculator` により、アスペクト比差異（縦横の不一致または20%以上の比率差）がある場合に `Aspect ratio mismatch` 警告が表示され、動画生成自体は妨げない。
- [x] Starting Image実ファイルがディスク上から消失しているプロジェクトをロードした際、ID選択が勝手に `nil` へリセットされず、赤字の `⚠ Image unavailable` バッジと `Clear`, `Change...` ボタンが表示される。
- [x] アセット消失状態で生成を実行すると、`CoordinatorError.startingImageUnavailable` がスローされ、サイレントなT2Vフォールバックが防止される。
- [x] StoryboardとHybridで同一のUI構造、Menu構成、アセット消失保護、警告ロジックが共通化されている。
- [x] `swift build` PASS; `swift run LTXTests` = **593 passed / 0 failed** (新規 `StartingImageUXTests` 含む); Xcode Debug `BUILD SUCCEEDED`; `git diff --check` clean。

## N. Phase X — Generate / One Shot responsibility split（2026-08-09）

- [x] `xcodebuild -showBuildSettings` からcanonical Debug appを解決し、フルパスで起動した。
- [x] 起動前HEAD `9f2a355`、executable mtime `2026-08-09 22:04:52 +0900`、実行PID `87843`、実行ファイルのフルパスを確認した。
- [x] build前から残っていたPID `86580`を終了し、最新canonical executableを起動した。
- [x] Generateに `One Shot Director` / director brief / planning actionが表示されない。
- [x] Generateの既存 `Image to Video`、選択画像、strength、preset、audio、queue操作が維持されている。
- [x] One Shotに `Starting Image (Optional)`、first-frame guidance、Chooseが表示される。
- [x] 1086×1448 PNGを選択し、thumbnail、filename、`Image-conditioned starting frame` status、Choose Another、Clearを確認した。
- [x] 選択画像を一時的に欠損させて生成操作を行い、text-onlyへ落ちず `Starting Image is unavailable`、Choose Again、Clear、生成button disabledを確認した。
- [x] Clear後は画像状態とerrorが消え、text-only One Shotの生成buttonが再度有効になった。
- [x] One Shotの選択状態はGenerateのsource-image preferenceと別keyであり、相互リークしない。
- [x] `swift build` PASS; `swift run LTXTests` = **659 passed / 0 failed**; Xcode Debug clean build `BUILD SUCCEEDED`; Xcode Release clean build `BUILD SUCCEEDED`; `git diff --check` PASS。
- [x] GUI sessionはMLX Environment Not Readyだったためrenderは開始せず、model download / cloud call / backend変更も行っていない。

## O. Bilingual page descriptions（2026-08-09）

- [x] canonical Debug appをフルパスで1つだけ起動し、Generate / One Shot / Storyboard / Hybrid / Video Archive / Settingsを開いた。
- [x] 6ページすべてでpage title直下にEnglish → Japaneseの順で説明が表示される。
- [x] navigation名はGenerate / One Shot / Storyboard / Director / Hybrid / Video Archiveの英語表記を維持する。
- [x] button・Preset・設定項目・error・tooltip・Localizable infrastructureを変更していない。
- [x] One ShotのStarting Image (Optional)、thumbnail、filename/status、Choose Another、Clearが説明文の下で正常に表示される。
- [x] Generateはdirect T2V/I2Vのままで、One Shot Director UIは復活していない。
- [x] Settingsの550×450 windowを含め、文字切れ・重なり・不自然なoverflowなし。
- [x] `swift build` PASS; `swift run LTXTests` = **659 passed / 0 failed**; Xcode Debug clean build `BUILD SUCCEEDED`; `git diff --check` PASS。

## P. Bilingual Settings descriptions（2026-08-09）

- [x] baseline `257fece`から、Settings内の既存説明23箇所だけをEnglish → Japaneseの順で2行併記した。
- [x] General / Generation / Director / Analysis / Audio / Models & Featuresの全対象説明を確認した。Aboutには翻訳対象となるoption説明がないことも確認した。
- [x] setting item、section heading、button、picker、Model名、path、status、default値は英語表記と既存値を維持する。
- [x] Settings behavior、`@AppStorage` key、feature flag、generation/backend/data model、Localizable infrastructureを変更していない。
- [x] canonical appのSettings headerはEnglish/Japanese両方を表示し、追加説明はform内でscroll可能。文字切れ・重なり・control崩れなし。
- [x] AnalysisのVision Model pickerを開閉し、選択値を変えずにcontrol interactionを確認した。
- [x] 起動前にHEAD `257fece`、canonical executable mtime `2026-08-09 22:38:15 +0900`を確認。旧processを終了後、PID `89377`が同じfull executable pathから動作することを確認した。
- [x] `swift build` PASS; `swift run LTXTests` = **659 passed / 0 failed**; Xcode Debug clean build `BUILD SUCCEEDED`; `git diff --check` PASS。

## Auto Movie (Sora 2-like) — long-form acceptance

Added 2026-08-10 with the continuity chain. Run on the canonical Debug app.

### J. Auto Movie end-to-end
- [ ] J1. Sidebar shows **Auto Movie** with the subtitle "Sora 2-like connected shots"
- [ ] J2. The page header reads "Auto Movie (Sora 2-like)" with the English and Japanese descriptions
- [ ] J3. **New Auto Movie…** → enter a brief (e.g. "A young woman walks toward an old stone library, reaches the entrance, opens the door and steps inside"), target duration ~15s → **Generate Movie**
- [ ] J4. The director plans multiple shots and **only the first shot is queued** (Queue shows one item, not all shots)
- [ ] J5. Shot cards show a continuity badge: "Continues from Shot N" (link icon) or "Cut — starts a new scene"
- [ ] J6. As each shot completes, the next shot is queued automatically — never two generations at once
- [ ] J7. A continuing shot's take shows an inherited starting frame (its request is image-to-video)
- [ ] J8. When the last shot completes, **Final Assembly runs automatically once**
- [ ] J9. A green "Completed movie ready" panel appears with **Play** and **Reveal**
- [ ] J10. Play opens a single continuous movie containing every shot in order

### K. Auto Movie continuity behaviour
- [ ] K1. Give one shot its own Starting Image → that image is used, not the inherited frame
- [ ] K2. Delete a completed shot's output file, then let a continuing shot run → the shot is **blocked with a reason**, and no movie is assembled (it must NOT silently render text-to-video)
- [ ] K3. Retake an earlier shot and select the new take → downstream continuity is reported stale
- [ ] K4. Cancel mid-run → no further shots start and nothing is assembled

### L. Storyboard automatic assembly
- [ ] L1. Create a 2-shot storyboard, generate one take per shot manually
- [ ] L2. When the last take completes, assembly runs **once** automatically
- [ ] L3. Re-opening the project does not assemble again
- [ ] L4. Manual **Assemble Final Video** still works

### M. Regression / window matrix after the Auto Movie work
- [ ] M1. Generate, One Shot, Storyboard / Director, Auto Movie, Video Archive all reachable
- [ ] M2. Navigation stays pinned at normal window size, small window (900×500) and after relaunch
- [ ] M3. Settings bilingual descriptions unchanged
- [ ] M4. Existing storyboards created before this change still open

**Status 2026-08-10:** not executed. The graphical session was not vending
windows during the unattended run (every app, including TextEdit, reported zero
windows and screen captures were blank), so this matrix is pending a session
with an awake, unlocked display. Implementation, unit tests and a real
three-shot LTX continuity run were verified without the GUI.

## 2026-08-10 Auto Movie GUI acceptance (executed)

Canonical Debug app from HEAD `6a3e290` + calibration work; executable mtime
`2026-08-10 05:33`; PID 2139.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / **Auto Movie**
  ("Sora 2-like connected shots") / Video Archive, all pinned at the top —
  the 2db0abc sidebar fix is intact.
- [x] Page header reads "Auto Movie (Sora 2-like)" with the English and Japanese
  descriptions.
- [x] Existing Hybrid projects created before the rename still load and are
  listed under "Auto Movies" (backward compatibility).
- [x] A project persisted with the new continuity schema decodes and renders in
  the real app.
- [x] Shot 2 shows the **"Continues from Shot 1"** badge with the link icon;
  Shot 1 correctly shows no badge.
- [x] "Generate Missing Takes" enabled and "Assemble Final Video" disabled while
  no takes exist.
- [x] New Auto Movie sheet shows Title / Brief / Characters / Preset / Model /
  Audio / Target Duration / "Generate first pass after planning" / Director
  (Auto · Local AI · Basic, reporting "Local AI Ready").
- [x] Clearing "Generate first pass after planning" changes the action button to
  "Create Auto Movie", so a project can be planned without starting a render.

Not exercised in this pass: driving a full in-app Auto Movie render to
assembly. Synthetic clicks cannot focus the SwiftUI brief editor, and a render
was deliberately not started while the calibration generations were running.
The equivalent pipeline was verified end to end outside the GUI
(`scripts/automovie_continuity_e2e.sh`) and by unit tests.

## 2026-08-10 Auto Movie cinematic progression GUI check

Canonical Debug app, executable mtime `2026-08-10 06:17`, PID 4222.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie /
  Video Archive, pinned at the top (2db0abc sidebar fix intact).
- [x] Auto Movie page header and bilingual descriptions render unchanged.
- [x] Existing Auto Movie projects still load and list correctly.
- [x] No layout regression from this change (ContentView untouched this round).

Not re-exercised: a full in-app Auto Movie render to assembly, for the same
reason as the previous pass (synthetic clicks cannot focus the SwiftUI brief
editor). The equivalent pipeline — real Director planning, per-shot compilation,
continuity decision, sequential generation and assembly — was run outside the
GUI by `scripts/automovie_progression_e2e.py`.

## 2026-08-10 Continuity Reconciliation GUI check

Canonical Debug app, executable mtime `2026-08-10 07:06`, PID 5775.

- [x] Sidebar shows all five entries, pinned at the top (2db0abc fix intact).
- [x] Auto Movie page header and bilingual descriptions unchanged.
- [x] Existing Auto Movie projects still load after the two new optional Shot
  fields were added.
- [x] Shot badges continue to read `continuityMode`, which is now the effective
  (reconciled) value, so no badge change was required.

Not re-exercised: a full in-app render to assembly (same SwiftUI brief-editor
focus limitation as previous passes). The equivalent pipeline — Director
planning, reconciliation, sequential generation with inheritance, and assembly —
was run by `scripts/automovie_progression_e2e.py`.

## 2026-08-10 Adaptive Continuity Strength GUI check

Canonical Debug app, executable mtime `2026-08-10 07:34`, PID 7254, 1 window at
1680x948 (no HSplitView height inflation).

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top
  (2db0abc sidebar fix intact).
- [x] Auto Movie page header and bilingual descriptions render unchanged.
- [x] Existing Auto Movie projects still load and list correctly (3 projects,
  shot and selected-take counts intact) after the policy change.
- [x] Video Archive still lists prior takes with Requested / Effective / Actual
  resolution and duration.
- [x] No layout regression from this change (ContentView untouched this round).

No user-facing control was added: the policy is chosen deterministically from
the Director's own shot scales, so there is nothing new to exercise in the GUI.

Not re-exercised: a full in-app Auto Movie render to assembly (same SwiftUI
brief-editor focus limitation as previous passes). The equivalent pipeline —
Director planning, reconciliation, per-shot policy selection, sequential
generation with inheritance, and assembly — was run by
`scripts/automovie_progression_e2e.py`.

## 2026-08-10 Capability-Aware Shot Planning GUI check

Canonical Debug app, executable mtime `2026-08-10 08:23`, PID 9418, 1 window at
1680x948 (no HSplitView height inflation).

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top
  (2db0abc sidebar fix intact).
- [x] Auto Movie page header and bilingual descriptions render unchanged.
- [x] Existing Auto Movie projects load and list correctly (3 projects, shot and
  selected-take counts intact) after `originalCameraScale` and
  `capabilityAdjustmentReason` were added to Shot.
- [x] Video Archive still lists prior takes.
- [x] No layout regression from this change (ContentView untouched this round).

No user-facing control was added: the policy is chosen deterministically from the
Director's own shot scales, so there is nothing new to exercise in the GUI.

Not re-exercised: selecting a project to inspect shot cards and continuity
badges, and a full in-app render to assembly. Synthetic clicks still cannot
select a SwiftUI list row or focus the brief editor (same limitation as previous
passes). The projects list rendering correct per-project shot and take counts is
the meaningful compatibility check for the extended Shot schema, and it passes.
The equivalent pipeline — Director planning, capability planning, reconciliation,
per-shot strength policy, sequential generation and assembly — was run by
`scripts/automovie_progression_e2e.py`.

## 2026-08-10 Opening Shot Anchor GUI check

Canonical Debug app, executable mtime `2026-08-10 15:52`, PID 20798, 1 window at
1680x948.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top.
- [x] Auto Movie page header and bilingual descriptions unchanged.
- [x] All five existing Auto Movie projects load with correct shot and
  selected-take counts.
- [x] No layout regression (ContentView untouched this round).

No user-facing control was added: the opening correction is deterministic and
invisible, recorded only in the shot's `capabilityAdjustmentReason`.

## 2026-08-10 Reframe revalidation GUI check

Canonical Debug app, executable mtime `2026-08-10 18:11`, 1 window at 1680x948.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top.
- [x] Auto Movie page header and bilingual descriptions unchanged.
- [x] All five existing Auto Movie projects load with correct shot and
  selected-take counts.
- [x] No layout regression (ContentView untouched this round).

The change is invisible in the UI — a planning rule was removed, so a Director
close-up now survives to generation instead of being clamped. Verified in the
pipeline instead: the real 768x512 E2E logged `strength policy: reframe
(wide -> medium-close-up) @ 0.5`, where the same boundary previously logged
`standard @ 0.8`.

## 2026-08-10 v1 readiness audit GUI check

Canonical Debug app, executable mtime `2026-08-10 18:11`, 1 window at 1680x948.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top.
- [x] Auto Movie page loads; all five existing projects list with correct shot
  and selected-take counts.
- [x] Video Archive loads and lists 144 history entries with previews.
- [x] No layout regression (no compiled source changed this round).

Note: the 15 `AUDIT_*.mp4` files preserved for review are in the Videos folder
and playable, but do not appear in the Video Archive — it is driven by
`history.json`, which was deliberately not edited (user data).

## 2026-08-10 Character Anchor GUI check

Canonical Debug app, executable mtime `2026-08-10 22:56`, 1 window at 1680x948.

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top.
- [x] Auto Movie page loads; all seven existing projects list with correct shot
  and selected-take counts after the new `characterAnchor` field was added.
- [x] No layout regression at 1680x948.

**Not visually confirmed by automation:** the Character Anchor section itself,
which lives inside a project's detail view. Selecting a project row needs a real
click — synthetic clicks and accessibility traversal both fail on this SwiftUI
list, as recorded in every previous pass. The section's behaviour is covered by
unit tests (resolution, preference order, precedence, persistence, missing-file
blocking) and it compiles into the Auto Movie detail path, but a human should
open a project once to confirm the layout reads well.

## 2026-08-11 Opening Reference Image GUI check (partial)

Canonical Debug app, executable mtime `2026-08-11 04:58`, 1 window at 1680x948.
The display was asleep when this first ran and screen capture returned black; it
woke later in the session and the checks below were then completed.

Verified:

- [x] Sidebar shows Generate / One Shot / Storyboard / Director / Auto Movie
  (Sora 2-like connected shots) / Video Archive, pinned at the top.
- [x] Storyboard page loads and lists its projects.
- [x] Auto Movie page header and bilingual descriptions render.
- [x] **All eight existing Auto Movie projects load with correct shot and
  selected-take counts after `openingReferenceImage` was added to the schema** —
  the backward-compatibility check that mattered most.
- [x] New Auto Movie sheet opens and dismisses cleanly.
- [x] No layout inflation at 1680x948.

**Still unverified — needs a human at the keyboard:** the Opening Reference
Image section itself and its Choose / Replace / Clear controls, which live
inside a project's detail view. Selecting a project row requires a real click;
synthetic clicks and accessibility traversal both fail on this SwiftUI list, as
in every previous pass, and the file picker is a modal panel automation should
not drive blind.

- [ ] Open an Auto Movie project and confirm "Opening Reference Image
      (Optional)" appears above Character Anchor.
- [ ] Choose Image… imports and shows a thumbnail plus filename.
- [ ] Replace… switches to a new image; Clear removes it.
- [ ] With both set, the note that the opening reference wins is visible.
- [ ] Character Anchor section renders with its corrected copy.

The logic behind those controls is covered by unit tests — import, replace,
clear, precedence, missing-file blocking and persistence — and the pipeline half
was verified by the real 768x512 A/B run.

## 2026-08-11 Opening Reference in creation flow — GUI acceptance PASSED

Canonical Debug app, executable mtime `2026-08-11 06:45`, 1 window at 1680x948.
Driven end to end with real clicks and a real file panel.

- [x] `+` opens the New Auto Movie dialog.
- [x] **"Opening Reference Image (Optional)" is inside the dialog**, between
      Preset/Model and Target Duration — before Generate Movie.
- [x] "Choose Image…" opens the file panel; selecting an image populates it.
- [x] Thumbnail renders the chosen scene.
- [x] Filename shows (`scene_ref.png`).
- [x] Buttons become "Replace…" and "Clear".
- [x] Clear returns the control to "Choose Image…" with an empty placeholder.
- [x] Title and Brief accept input; Generate Movie enables.
- [x] Create produced a 4-shot Auto Movie and **queued shot 1 immediately**.
- [x] The project page shows "Movie Settings — Opening Reference Image" with the
      thumbnail, filename and Replace/Clear, clearly labelled as movie-level.
- [x] Character Anchor section renders below with its corrected copy.
- [x] No layout regression at 1680x948.

Verified in the persisted project rather than by eye alone: the movie carries
`Assets/OpeningReference/opening-reference-<uuid>.png`, and shot 1's queued take
has that path as its `sourceImagePath` while shots 2–4 have no take yet.

Real generation from the dialog: shot 1 rendered at 768x512 / 121 frames and its
first frame is the chosen reference, continuing into the same plaza scene. The
render was preserved as
`OPENREF_CREATEFLOW_shot01_from_dialog_768x512_*.mp4` for review.

## 2026-08-11 Global Production Queue — GUI acceptance PASS

Canonical Debug app rebuilt after the D-066/D-067/D-068 fixes. Three real Auto
Movies were queued from the New Auto Movie dialog and run to completion,
10:00–10:21. All observations are from the app on screen, corroborated by
`production_queue.json` and by sampling the render subprocesses every 0.5 s.

- [x] Sidebar shows Generate / One Shot / Storyboard / Auto Movie / Video
      Archive, pinned, no layout inflation at 1680x948.
- [x] **"Production Queue" panel renders in the sidebar** below the existing
      render queue, with its empty-state copy.
- [x] Auto Movie page and existing projects load.
- [x] Creating an Auto Movie routes through the queue and starts it.
- [x] **Several jobs visible together**: header read `1 running · 2 waiting`,
      with QFIN A Running and QFIN B / QFIN C Waiting in the panel at once.
- [x] **Jobs wait in the order they were created** (QFIN B above QFIN C) — this
      is what D-068 got wrong.
- [x] **Progress advances shot by shot**: Shot 1 / 5 → 2 / 5 → 3 / 5 → 4 / 5 →
      5 / 5 for A, then 1 / 4 → 4 / 4 for B. Previously pinned at Shot 1 / N
      (D-067).
- [x] **A finishes, B starts by itself**: at 10:11:53 A read Completed and B
      read Running Shot 1 / 4 in the same panel refresh. Same again for B → C at
      10:20:31.
- [x] **No premature completion**: neither movie reached Completed until every
      shot had rendered and the final movie existed (D-065 / D-066).
- [x] Move Up / Move Down exercised on waiting rows; the two swapped both ways.
- [x] Cancel from the panel: on a waiting job (row went Cancelled) and on the
      running job (QFIN C — the in-flight render stopped within 30 s and no
      further job started).
- [x] Completed rows show green Completed with Reveal and Remove; Waiting rows
      show Move Up / Move Down / Cancel.
- [x] Pause / Resume: header button toggles, and a paused queue starts nothing.
- [x] Restart with a waiting job: it restored as **Waiting** and then started on
      its own (pause is deliberately not persisted).
- [x] Restart with a running job: it restored as **Interrupted — "Interrupted
      when the app quit"** and offers Restart, rather than being resumed
      silently or reported complete.

Preserved for review in the Videos folder (copied with `cp -n`, nothing
overwritten): `QUEUE_ACCEPT_A_*_final.mp4` (25.07 s, 5 shots) and
`QUEUE_ACCEPT_B_*_final.mp4` (20.06 s, 4 shots).

Known cosmetic gap, not fixed: a completed job keeps its last `stageDescription`
("Assembling") in the persisted record. The panel hides progress text for
terminal states, so nothing wrong is displayed; only the JSON looks stale.

## 2026-08-11 Opening Reference Vision Appearance Sync — GUI acceptance PASS

Canonical Debug app rebuilt after the vision-sync and CONTINUE-policy changes.
One real Auto Movie (`VB NEW`) created and run end to end, 15:09–15:28.

- [x] New Auto Movie dialog opens; title and brief accept input.
- [x] Opening Reference **Choose Image…** opens the panel, selection applies, and
      the thumbnail renders in the dialog.
- [x] **Generate Movie** creates the project and enqueues it normally.
- [x] **New status line** renders in the project view:
      `✓ Opening appearance: Analysed locally` in green, with the derived costume
      (`white blouse with blue vest and bow tie, dark skirt, light-colored cape`)
      beneath it.
- [x] Character section shows the synced Bible — hair `brown, shoulder-length`
      and the correct default costume. **No "Beige trench coat".**
- [x] **Replace…** and **Clear** both present on an attached reference.
- [x] Production Queue panel visible; the job ran and reported Completed.
- [x] "Completed movie ready" banner with Play / Reveal.
- [x] Sidebar intact — Generate / One Shot / Storyboard / Auto Movie / Video
      Archive — no layout inflation at 1680x948.

Not exercised on screen: Replace/Clear invalidation of the derived appearance was
verified by unit test rather than in the GUI, because clearing the reference on
this project would have destroyed the E2E evidence it holds.

## 2026-08-11 Adaptive Identity Refresh production acceptance

Canonical Debug app rebuilt from the implementation under test. Production
project `IDREFRESH ACCEPT — forced true positive` ran inside the global queue.

- [x] App launches from the full DerivedData `.app` path.
- [x] Sidebar and Auto Movie page render with no obvious layout regression at
      1680x948.
- [x] New Auto Movie sheet opens and includes Opening Reference selection.
- [x] Opening appearance status remains `Analysed locally`.
- [x] Production Queue shows the acceptance job, progresses Shot 2 / 4 through
      Shot 4 / 4, and records Completed.
- [x] All four generated/selected Shots are persisted.
- [x] Completed movie is present and playable metadata is valid: 20.061 s,
      768x512 H.264, AAC stereo.
- [x] Shot 3 persisted `Identity Refresh: Reused Opening Reference` provenance;
      its take used that exact managed source path.
- [x] Review copies were made before any disposable-control work.
- [x] On disposable project, Replace the Opening Reference and confirm thumbnail
      / filename / local-analysis state update.
- [x] On the same disposable project, Clear and confirm the control returns to
      `Choose Image…` without altering the production evidence project.

Replace was exercised with `ChatGPT Image 2026年8月10日 23_51_41.png` on fresh
disposable project `7E9C8F0D-FCBC-4CB2-9F7E-642327B4FE05`. The first
GUI pass exposed an integration gap: filename and thumbnail updated, but the old
`Opening appearance` JSON remained because the View did not call the already
tested `OpeningReferenceSync.invalidateIfStale`. The View now calls it at the
same Replace/Clear boundary as refresh-anchor invalidation. The post-fix pass
confirmed in both UI and persisted JSON that Replace drops the previous
appearance and all refresh provenance, while Clear leaves
`openingReferenceImage = null`, `openingReferenceAppearance = null`, no refresh
provenance, and returns the section to `Choose Image…`. Reopening the evidence
project still showed its original Opening Reference, 4/4 selected takes and
`Completed movie ready`; its persisted project JSON and review media were
unchanged.

Final GUI preflight: repository HEAD `549e93b` plus the uncommitted implementation
under test, canonical app resolved from `xcodebuild -showBuildSettings`, executable
mtime `2026-08-11 19:08:18 +0900`, active PID 91285 with that exact executable
path. The app was launched by full path, not `open -a`.

## 2026-08-12 Auto Movie Plan Preview Phase A — GUI acceptance PASS

- [x] Canonical DerivedData Debug app was built and opened by its full path;
      `open -a` was not used.
- [x] Created isolated project `Plan Edit GUI Acceptance` with Basic Director,
      four planned shots, and **Generate first pass after planning** disabled.
- [x] Edited Shot 1 Action and the existing camera fields to `medium close-up`,
      `low`, and `slow dolly-in`; the preview and actual Shot card showed the
      revised values.
- [x] Later Shot 2–4 indicators remained `Continue · Previous shot's last
      frame`; Cut / Continue, durations and sources were never editable.
- [x] Quit and relaunched the same canonical app, reopened the project, and
      confirmed the saved action and camera values persisted.
- [x] No LTX generation, take creation, opening-reference mutation or queue job
      was started during this acceptance.

## 2026-08-12 Auto Movie Plan Preview Phase B — GUI acceptance PASS

- [x] Clean-built canonical DerivedData Debug app was relaunched by full path;
      the pre-build process was explicitly quit before acceptance.
- [x] Used isolated Basic Director project `Plan Edit GUI Acceptance` with zero
      generated Takes and an empty generation queue.
- [x] Shot 2 changed Continue → Cut; both preview and lower Shot status changed
      from `Previous shot's last frame` / link to `Text to video` / Cut.
- [x] Shot 2 changed Cut → Continue; both surfaces immediately returned to the
      existing Last Frame description.
- [x] Saved Shot 2 as Cut, quit and relaunched the canonical app, reopened the
      project, and confirmed Cut persisted.
- [x] Shot 1's segmented control stayed disabled with Cut selected.
- [x] Phase A Action and Camera controls remained available, and its previously
      saved `medium close-up`, `low`, `slow dolly-in` values remained visible.
- [x] No LTX generation, Take creation, queue job, source import, or production
      project edit occurred.

## 2026-08-12 LTX Generation Diagnostics — Phase 1 GUI acceptance

- [x] Automated source/provenance coverage: T2V, explicit Starting Image,
      Opening Reference, Character Anchor, inherited last frame, Identity
      Refresh provenance, selected-Take reason, image-preparation dimensions,
      and legacy JSON decode. `swift run LTXTests`: 1530 passed / 0 failed.
- [x] Canonical Debug artifact clean-built at
      `~/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-*/Build/Products/Debug/LTXVideoGenerator.app`.
      Pre-check HEAD `4051d91282ba3925447577ee40fe076d9864114e`; executable
      mtime `2026-08-12 10:16:23 +0900`. The pre-build process began at
      `09:46:59` with a running render, so it was not interrupted; after the
      queue reached no pending generations it was quit and the rebuilt app
      launched by full path as PID `29138` at `10:19:23`.
- [x] A historical pre-Phase-1 completed Take visibly says
      `Generation diagnostics unavailable for this earlier Take.` No Take or
      source-selection state was changed.
- [x] New-Take source plan, I2V image preparation, continuation-selection and
      refresh-provenance paths are covered without starting LTX:
      `swift run LTXTests` 1530 passed / 0 failed.
- [ ] Optional future live-render observation: after a normal user-initiated
      new I2V Take, its disclosure should show **Queued source plan** before
      execution, then original → effective dimensions and either **No-op** or
      **Scale to fill · center crop**. This task intentionally did not start a
      heavyweight render solely for UI evidence.
