# GUI Acceptance Test Checklist（Xcode導入後の人間最終確認）

前提: Xcode.appをインストールし、`LTXVideoGenerator/LTXVideoGenerator.xcodeproj` を開いてbuild/run。
Python: `~/ltx-venv/bin/python3`（設定済みのはず）。モデル: ltx23_distilled_q4（キャッシュ済み）。
所要目安: フル実施 約60–90分（生成待ち含む）。各生成は512×320/25f/15stepsなら1分弱。

判定原則: **requested値ではなく実MP4（ffprobe）と実挙動が基準。**

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
- [ ] Re-run all three Quick Preview Takes, regenerate only the final shot at High Quality, retain/select both final-shot Takes, and assemble the final MP4.

The affected project still has its original persisted BF16 snapshot and must not be reused. Disk cleanup restored about 66 GiB free while preserving the completed Q4 model and 4-bit encoder caches; the unchecked acceptance will use a newly-created project.

---

## A. Regression — 全flag OFF = 従来動作（最優先）

- [ ] A1. 初回起動: Preferences → Models & Features の全トグルがOFF、Adult Content ModeがOFFであること
- [ ] A2. T2V生成（prompt任意、seed **42**、512×320/25f/15steps/24fps/audio ON）が完了しHistoryに追加される
- [ ] A3. 生成物を `md5 <出力mp4>` で確認 → 同一設定のbaseline（`bf8020b1f55f73a62c075f2df1c65a8d`、prompt: "A small red fox walks slowly through a snowy forest clearing, soft morning light, gentle camera pan, cinematic."・negative無し・tiling auto・cfg 3.0の場合）と一致
- [ ] A4. I2V生成（画像ドロップ→生成）が完了する
- [ ] A5. Audio OFF（Generate Audioを無効化）で音声トラック無しのMP4になる（QuickTime/ffprobeで確認）
- [ ] A6. 旧バージョンで作成したHistory / Preset / CharacterProfileが壊れず読み込める（既存ユーザー環境で起動して確認）
- [ ] A7. 3 variations / 5 variationsが**1件ずつ順番に**処理される（同時に2つ進行しない）
- [ ] A8. 生成中のCancelが効き、アプリが正常状態に戻る

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
- [ ] D4. Compact選択→512×320になり、ffprobeの実解像度が512×320
- [ ] D5. Advanced選択→手動パラメータが**一切変更されない**
- [x] D6. target 5s、同一seed/model/audioで Quick=C3 / Standard=S0 / High=H0、全て121f（duration制約維持）
- [x] D7. One Shot / Storyboard / Hybrid / APIのdurationがprofile適用後もframesへ反映され、Customは手動framesを保持する
- [x] D8. History/Take metadataにeffective profile reason、target/requested duration、audio、sourceを保存する

Post-fixの新規実生成は未実施。今回起動したDebug appは `MLX Environment Not Ready`、sandbox内PythonのMetal probeはdevice非検出だった。request比較は必須項目として完了し、旧Quick/Standard/Highの実MP4はArchiveとffprobe metadataで確認済み。

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
