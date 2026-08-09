# CURRENT_STATE

Updated: 2026-08-09

## Current Phase
CharacterBible Phase 0 foundation is complete on top of the zero-setup Storyboard Director. Storyboard and Hybrid now share one stable-ID character source of truth through planning, Shot assignment, continuity resolution, prompt compilation, persistence, and GUI editing. The previously verified Preset/text-encoder, cached-model render, Take queue, assembly, and cancellation paths were not changed.

## Completed
- Source acquisition: cloned `james-see/ltx-video-mac` (MIT) @ `a441dc2` → branch `director-extensions`.
- Phase 0: audit + SPM build/test harness + measured baselines (BASELINE.md, BENCHMARK_RESULTS.md).
- Phase 1: ModelRegistry + VideoGenerationAdapter boundary + backward-compatible metadata + rollback-capable FeatureFlags.
- Phase 2: CompatibilityLab (11-check gate), ManifestValidator, ModelInstaller (no auto-download), Adult Mode + policy at Service/API layers, Preferences "Models & Features" tab.
- Phase 3: MemoryMonitor/HardwareProfiler/QualityProfile ladder/AutoQualityEngine/HistoricalSuccessStore, fallback retry (max 3), MediaProbe wiring, LowRAMMLXAdapter boundary (Runtime Verification Pending), lowram_bench.sh.
- Phase 4: One Shot Director (Ollama loopback provider + template fallback, terminate-before-render), OneShotPlan, PromptCompiler, DialogueNormalizer, UI disclosure.
- Phase 5: FilmProject/Shot/Take (1–20 sequential takes), versioned atomic persistence, resume reconciliation (real MP4 = truth).
- Phase 6: ContinuityEngine (deterministic directives + validator + monotony rules), StoryboardDirector (hybrid, sequential roles), FinalAssemblyService (stream-copy/normalize+concat) — verified against real MP4s.
- Phase 7: LocalAPIServer v1 (loopback + token + asset sandbox + policy), extras/openclaw.
- Regression: same-seed re-run produces **byte-identical MP4** to Phase 0 baseline (MD5 match).
- GUI completion: shared user-facing Preset (`Quick Preview / Standard / High Quality / Custom`) maps centrally to internal QualityMode (`Compact / Auto / High / Advanced`). Generate no longer exposes Quality as a primary picker; manual parameter edits select Custom.
- Storyboard Project Settings: Preset, Model, Audio plus Custom Resolution/Frames/FPS/Steps; requested/effective/actual metadata is visible and persisted per Take.
- Preview → Final workflow: changing Preset preserves project/shot/continuity state; per-shot and multi-shot regeneration append new Takes and keep previews; assembly still uses selected Takes and MediaProbe.
- Navigation: Generate / One Shot / Storyboard / Director / Hybrid are distinct production modes. Hybrid composes StoryboardDirector + continuity + FilmProject + sequential Take queue and deterministically splits template fallback into 4–6 second shots.
- Preset propagation fix: `GenerationSettingsResolver` is now the only preset/profile-to-render boundary used by Generate, One Shot, Storyboard, Hybrid, retakes, missing-take generation, REST and OpenClaw v1 requests.
- Duration precedence: profile supplies resolution/FPS/steps/audio; One Shot/Storyboard/Hybrid/API target duration recomputes 8n+1 frames at the resolved FPS; Custom preserves manual frames.
- Standard Auto policy: a lower-profile success alone no longer caps Standard. On 48 GB, Standard targets S0 while High remains H0; a real latest S0 failure can fall back to known-safe history with an explicit reason.
- Diagnostics: every render attempt logs final width/height/frames/FPS/steps/audio/target/model/seed; Result/Take/Archive preserve profile reason, source, target/requested duration and audio state.
- Storyboard/Hybrid encoder inheritance: newly-created projects now snapshot the same current model/text-encoder selections used by Generate and One Shot. Legacy Codable defaults remain unchanged for old project migration.
- Render cancellation: Cancel terminates the active Swift-launched Python wrapper, and the wrapper forwards termination to its `mlx_video.generate_av` child before exiting.
- Cancellation persistence: a cancelled project request is now saved as a cancelled Take and Job, shown as cancelled in the Storyboard UI, and does not surface a failure alert.
- Real GUI E2E (2026-08-09): cached Official Q4 + Gemma 12B 4-bit rendered three sequential Quick Preview shots, retained a Quick take while adding/selecting one High Quality take, normalized the mixed 512×320/768×512 sources into a playable 768×512 final MP4 with audio, and left no generation process behind.
- Pure Storyboard planning closure (2026-08-09): `qwen3.6-claw-fast:latest` returned valid three-shot schema JSON in Ollama's `thinking` envelope field while `response` was empty. The provider now requests `think:false`, retains a compatibility fallback for non-empty `thinking`, and distinguishes no response from request, extraction, syntax, decode, schema, semantic, repair, retry, and template-fallback stages.
- Structured-output recovery is bounded: direct decode, balanced-object extraction, conservative deterministic repair, one LLM repair request, then the existing Basic/template fallback. Debug builds may retain raw responses only in a rotating temporary log; Release builds do not persist them.
- New projects persist planning provenance (`directorProvider`, `directorModel`, `planningMode`, optional `fallbackReason`) and the Storyboard UI identifies Local AI versus Basic Fallback.
- Director UX: Auto is the default and resolves an installed preferred model through the loopback `/api/tags` API; unavailable server/model conditions become a visible Basic Director result instead of blocking Storyboard creation. No shell-based discovery, automatic model download, cloud fallback, or OpenClaw coupling was added.
- Settings now has a Director tab with Auto / Local AI / Basic, friendly readiness state, installed-model picker backed by the existing `directorOllamaModel` preference, manual refresh, lightweight Test, and an Advanced-only endpoint/technical status disclosure.
- Requested/effective Director mode is persisted as optional FilmProject metadata. Explicit Basic is labeled Basic rather than AI/failure, bypasses Ollama entirely, and safely decomposes briefs containing explicit first/next/final shot cues into multiple deterministic shots.
- CharacterBible Phase 0: `FilmProject.characterBible` owns versioned `BibleCharacter` records with stable UUIDs, structured appearance, costume, dialogue/planning metadata, continuity notes, trait locks, and future reference-asset metadata. `Shot.characterIDs` is the only durable identity relation; names remain freely editable display data.
- Character data follows one shared path for Storyboard and Hybrid: CharacterBible → Director/Basic planning → `Shot.characterIDs` → ContinuityEngine → PromptCompiler. Only assigned characters contribute compact visual guidance to a Shot; personality and speaking style remain available to planning but are not dumped into render prompts.
- Storyboard/Hybrid GUI supports Add, Edit, Cancel, confirmed Delete, per-Shot multi-selection, same-name disambiguation by ID prefix, and live prompt recompilation. Deleting a character removes all Shot references without deleting Takes; renaming preserves the UUID.
- Existing FilmProject JSON without CharacterBible or `characterIDs` loads with an empty Bible and intact Shots/Takes/assembly state. Existing `CharacterProfile` remains the separate Generate/legacy model; an explicit non-mutating bridge can create a candidate but no profiles are automatically migrated.
- Reference assets are metadata/storage foundation only. Safe project-relative paths resolve under `Projects/<ProjectID>/Assets/Characters/<CharacterID>`; absolute and traversal paths are rejected. No image import, Vision parsing, face crop/embedding, LTX reference conditioning, or same-person guarantee was added.

## In Progress
- No open item in CharacterBible Phase 0. Character Sheet Vision analysis and actual identity/reference conditioning are explicitly deferred to later phases.

## Build Status
- `swift build` clean (final GUI implementation).
- **Xcode 26.6 installed (2026-08-08): `xcodebuild -scheme LTXVideoGenerator -configuration Debug` → BUILD SUCCEEDED.** Full .app bundle produced (arm64, ad-hoc signing via CLI overrides only — no project settings changed; deployment target 14.0, bundle id com.ltxvideo.generator). App launches and runs.

## Canonical Development App / GUI Acceptance Preflight
The canonical development app is the Debug product of `LTXVideoGenerator.xcodeproj` / `LTXVideoGenerator` scheme. Its expected shape is `~/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-*/Build/Products/Debug/LTXVideoGenerator.app`, but the wildcard is descriptive only and must never be used to launch it. The DerivedData hash is intentionally not recorded. Resolve the full path from the active Xcode build settings each time:

```bash
cd /Users/azimnb/ltx23appdev/ltx-video-mac
LTX_APP_PATH="$(
  xcodebuild \
    -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj \
    -scheme LTXVideoGenerator \
    -configuration Debug \
    -showBuildSettings |
  awk -F ' = ' '
    /^[[:space:]]*TARGET_BUILD_DIR = / { targetBuildDir=$2 }
    /^[[:space:]]*WRAPPER_NAME = / { wrapperName=$2 }
    END {
      if (targetBuildDir == "" || wrapperName == "") exit 1
      print targetBuildDir "/" wrapperName
    }
  '
)"
test -d "$LTX_APP_PATH"
printf 'canonical_app=%s\n' "$LTX_APP_PATH"
```

Before every GUI acceptance pass, build the canonical product and capture source/build provenance. Check the executable timestamp, not only the `.app` directory timestamp, because incremental Xcode builds may leave the wrapper directory timestamp unchanged:

```bash
LTX_GUI_HEAD="$(git rev-parse HEAD)"
printf 'git_head=%s\n' "$LTX_GUI_HEAD"
git status --short

xcodebuild \
  -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj \
  -scheme LTXVideoGenerator \
  -configuration Debug \
  build

test "$(git rev-parse HEAD)" = "$LTX_GUI_HEAD"
LTX_APP_EXECUTABLE_NAME="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleExecutable' \
    "$LTX_APP_PATH/Contents/Info.plist"
)"
LTX_APP_EXECUTABLE_PATH="$LTX_APP_PATH/Contents/MacOS/$LTX_APP_EXECUTABLE_NAME"
test -x "$LTX_APP_EXECUTABLE_PATH"
stat -f 'app_executable_mtime=%Sm' \
  -t '%Y-%m-%d %H:%M:%S %z' \
  "$LTX_APP_EXECUTABLE_PATH"

# No unexpected LTXVideoGenerator process should be accepted as the test target.
ps -axo pid=,comm= | rg '[L]TXVideoGenerator.app/Contents/MacOS/LTXVideoGenerator' || true

# Launch this exact product. Do not use open -a, Dock, Spotlight, or a recent item.
open -n "$LTX_APP_PATH"

# Acceptance starts only after the running executable resolves to the same full path.
ps -axo pid=,comm= | rg -F "$LTX_APP_EXECUTABLE_PATH"
```

If the pre-launch process check prints any app instance, quit all existing LTX Video Generator instances and rerun the check before `open -n`; do not continue acceptance against a process that survived the latest build.

Record the three provenance values with the GUI acceptance result: `git_head`, `app_executable_mtime`, and the full running process executable path. If HEAD or tracked source changes after the build, rebuild before acceptance.

Builds created with a custom path such as `-derivedDataPath /tmp/...` are disposable test artifacts. They must not be treated as the normal development app or used to claim final GUI acceptance. Multiple old Debug apps with bundle id `com.ltxvideo.generator` may coexist, so bundle-name lookup is always ambiguous; `open -a LTXVideoGenerator` is prohibited for GUI verification.

## Test Status
- `swift run LTXTests`: **498 checks, 0 failures** (including CharacterBible migration/persistence, stable rename/delete semantics, Character Sheet parsing/repair/import/manual fallback/selective merge/model lifecycle, Director/Basic/Hybrid character assignment, continuity precedence, compact multi-character prompts, and all prior Director/render regressions).
- Final concrete comparison on Mac16,11/48 GB, same prompt/model/seed 4242/target 5 s/audio ON: Quick=C3 512×320/121f/24fps/15 steps; Standard=S0 768×512/121f/24fps/25 steps; High=H0 768×512/121f/24fps/30 steps.

## 2026-08-09 Real Storyboard / Hybrid GUI E2E
- Source/build provenance: checkpoint `a32e93f` supplied the encoder inheritance and child-process termination fix; cancellation persistence was verified from `3b5782b652d13bb42a8f771d9451d2d803a9a18b`. Canonical app: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`; executable mtime `2026-08-09 03:31:30 +0900`; running PID 52199 resolved to that exact executable path.
- Disk/cache: 66 GiB free before and after. Completed caches remained about 20 GiB (Official Q4) and 7.5 GiB (Gemma 12B 4-bit). BF16 12B download: **NO**. Unexpected large model download: **NO**. `.incomplete` files after E2E: **none**.
- Pure new Storyboard project `5EA7ED62-B8D4-4532-BA6A-26DA1C3B56EF` saved `modelID=ltx23_distilled_q4` and `textEncoderID=gemma3_12b_4bit`. It was not the old BF16 project. The local planner failed schema validation and produced a one-shot template fallback, so this project was used only to verify inheritance.
- Three-shot production project: Hybrid `2B81DA40-9886-4733-A4AC-4E8879FC44DD`, target 15 s, audio ON. Hybrid uses the same project creation/settings, StoryboardDirector, sequential Take queue, retake, selection, and FinalAssembly code paths.
- Quick resolved request for every 5 s shot: Quick Preview / Compact / C3, requested 768×512, effective 512×320, 121 frames at 24 fps, 15 steps, aggressive tiling, Official Q4, Gemma 12B 4-bit, audio ON. Generation times were 129.48 s, 128.79 s, and 128.68 s. Actual MP4s were 512×320, approximately 5.01 s, H.264 + AAC stereo audio.
- Only Shot 3 was regenerated at High Quality. It resolved High / H0, 768×512, 121 frames at 24 fps, 30 steps, auto tiling, the same model/4-bit encoder/audio, and completed in 278.47 s. Its actual MP4 was 768×512, approximately 5.01 s, H.264 + AAC. The original Shot 3 Quick take remained stored and the High take became selected.
- Final selected order was Shot 1 Quick, Shot 2 Quick, Shot 3 High. Final file: `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/2B81DA40-9886-4733-A4AC-4E8879FC44DD_final.mp4`; 2,249,897 bytes; H.264 768×512; 15.060667 s container duration; AAC stereo 48 kHz. QuickTime playback advanced through the timeline and ended normally.
- Cancellation probe from the final canonical app used `textEncoderRepo=mlx-community/gemma-3-12b-it-4bit`. Cancel terminated wrapper PID 52241 and child PID 52243. Project `F466A6E9-9C02-4AC4-8AC8-6FE27B87816B` persisted both Take and Job as `cancelled`, displayed the cancelled UI state, showed no error alert, and left no Python/MLX/download process.

## 2026-08-09 Pure Storyboard Local AI Acceptance
- Pre-fix raw response, captured before parser changes with the exact sea-side brief and `qwen3.6-claw-fast:latest`: Ollama returned an empty `response` plus valid exact-schema three-shot JSON in `thinking`. It had no fence, preamble, trailing comma, missing field, invalid enum, or semantic error. The failure was envelope extraction before JSON/schema validation, not strict schema rejection.
- Provider fix: send Ollama `format:"json"` and `think:false`; prefer non-empty `response`, use non-empty `thinking` only for compatibility, and report an explicit no-response failure if both are empty. No model-name-specific hack was added.
- Canonical Debug app: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`; executable mtime `2026-08-09 08:11:28 +0900`; running PID 58415 resolved to that exact executable path. Acceptance source was base HEAD `7302c67` plus the reviewed structured-output worktree that becomes the local `fix: harden storyboard director structured output` checkpoint.
- Project `2274CB69-B651-4C1F-A9B5-2BF975E00023` was created from the same Japanese sea-side brief. GUI reported `Planned 3 shots via Local AI Director (ollama)` and displayed `Director: Local AI qwen3.6-claw-fast:latest`.
- The saved plan has three 5-second shots (`The Walk`, `The Pause`, `The Smile`), non-empty compiled prompts, propagated continuity state, and `directorProvider=ollama`, `directorModel=qwen3.6-claw-fast:latest`, `planningMode=ai`, `fallbackReason=null`.
- Project render settings remained `modelID=ltx23_distilled_q4` and `textEncoderID=gemma3_12b_4bit`. No BF16 selection or model download occurred. Ollama was no longer serving a model after planning. A new LTX render was intentionally not queued because downstream Quick/High generation, queue, retake, assembly, and cancellation had already passed the immediately preceding real E2E and were outside this Planning-only fix.

## 2026-08-09 Zero-Setup Director UX Acceptance
- Canonical app: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`; executable mtime `2026-08-09 08:45:59 +0900`; running PID 59844 resolved to that exact executable. Acceptance source was `da86397` plus the reviewed Director UX worktree that becomes the local `feat: add zero-setup storyboard director experience` checkpoint.
- Settings > Director opened with Auto (Recommended), `Ready`, model `qwen3.6-claw-fast:latest`, Refresh Models and Test. The picker listed all models returned by `/api/tags`; changing to `qwen3.6-claw:latest` persisted through `directorOllamaModel`, then the GUI restored `qwen3.6-claw-fast:latest`. Test returned `Local AI Director is ready` and unloaded the model afterward.
- Auto + Ollama ready: project `668BCE7F-D25C-4AB8-A68C-24FDDA280181`, three 5-second shots, requested `auto`, effective `localAI`, provider `ollama`, model `qwen3.6-claw-fast:latest`, planning `ai`, fallback nil.
- Explicit Basic while Ollama was running: project `93CA9860-CF98-4009-9D81-F600873DC397`, three deterministic 5-second shots, requested/effective `basic`, provider `template`, planning `basic`, fallback nil. Unit coverage verifies Basic never requests the Ollama model list; `/api/ps` remained empty.
- Auto while the Homebrew Ollama service was deliberately stopped: project `B37EC01D-47A1-441F-A9D1-2B22210A8DC6`, three deterministic 5-second shots, requested `auto`, effective `basic`, planning `fallback`, reason `localAIServerUnavailable`. Storyboard creation succeeded without an alert. The service was restored to its original started state; mode was restored to Auto, preferred model to qwen fast, and `/api/ps` was empty.
- All three projects retained `modelID=ltx23_distilled_q4` and `textEncoderID=gemma3_12b_4bit`. No Ollama pull, Hugging Face/BF16 download, or LTX generation was started.

## Known Blockers / Remaining Human Actions
1. ~~No Xcode.app~~ → RESOLVED: Xcode 26.6 installed; unsigned dev .app builds and runs. Remaining: Developer ID signing + notarization for distribution (needs credentials).
2. 10Eros weights not downloaded (user authorization required, tens of GB) → lab models stay verified=false. To verify: download weights, run scripts/compat_lab_smoke.sh, record checks in Compatibility Lab.
3. No 16GB hardware → LowRAM adapter Runtime Verification Pending; run scripts/lowram_bench.sh on a 16GB Mac (a dgrauet/ltx-2-mlx checkout already exists at ~/AI/LTX-MLX/ltx-2-mlx with a Q8 model).
4. Full 20-take queue soak (scripts/queue_soak.sh 20, ≈17 min) not yet run; 3-take validation done.
5. ~~Fresh post-fix Quick/High real render pending~~ → RESOLVED: the 2026-08-09 canonical-app E2E completed three Quick renders, one High retake, mixed-resolution assembly, QuickTime playback and cancellation using cached Q4 + 4-bit weights.
6. Storyboard real-generation root cause (resolved): the shared Storyboard/Hybrid creation sheet previously initialized `ProjectSettings()` and captured schema default `gemma3_12b_bf16`; it now inherits the current `gemma3_12b_4bit` selection. Existing projects intentionally retain their stored encoder snapshot. A pre-fix scratch project that was cancelled before cancellation-persistence existed may still contain queued status; there is intentionally no automatic migration of old project intent/state.

## 2026-08-09 CharacterBible Phase 0 GUI E2E
- Canonical app: `/Users/azimnb/Library/Developer/Xcode/DerivedData/LTXVideoGenerator-amthplfqixfwzxgnoumxohoqainn/Build/Products/Debug/LTXVideoGenerator.app`, always launched by full path. Final checkpoint HEAD/mtime/PID provenance is recorded after the checkpoint build.
- Pure Storyboard project `F9C4AC55-B1A4-4962-9869-FBE477A8B6B2`: the acceptance character was entered manually, saved, and assigned to three Basic Director shots using UUID `C7133C84-7791-4F7F-AFC8-0A31ADD2A140`. Renaming Adventurer Heroine to Maya changed GUI/prompt resolution but left every Shot UUID unchanged. Quit/relaunch restored the Bible, assignments, and prompts.
- Each compiled prompt contained the assigned character's compact face/hair/eyes/costume/lock/continuity guidance and excluded planning-only personality text. No unassigned Bible character was injected.
- Hybrid project `9F8F7FF6-852E-48EF-9627-E9A9A8D65D7C`: the same shared model/UI/planning/compiler path produced three shots assigned to UUID `B04A90CE-85AA-40AE-9121-E370FA1`. Per-Shot removal removed the character block and re-adding restored it. A temporary character was added and deleted through confirmation; no dangling IDs remained.
- Hybrid acceptance used the new `Generate first pass after planning` switch OFF. Its default remains ON, preserving prior Hybrid behavior. The saved project had zero Jobs/Takes; no MLX generation process, model download, or Ollama-loaded model remained.
- Capability boundary shown in the GUI: trait locks are textual storyboard-continuity guidance and do not guarantee pixel-identical identity. Reference asset analysis/conditioning remains disabled.

## 2026-08-09 CharacterBible Phase 1 — Character Sheet Import
- Storyboard and Hybrid now share `Import Character Sheet` for PNG/JPG/JPEG. Import copies the untouched source into `Projects/<ProjectID>/Assets/Characters/<CharacterID>/character-sheet-<UUID>.<ext>` before creating reference metadata; collisions cannot overwrite an existing asset. Wizard Cancel removes only the staged project copy.
- The project-owned original remains full resolution. A temporary, bounded analysis derivative is used for local Vision. Character reference metadata now persists dimensions, size, MIME type, detected views/expressions, provider/model provenance, and analysis date while continuing to decode Phase 0 assets that lack those fields.
- Preferences > Analysis has an independent Character Sheet Analysis mode/model source of truth: Auto, Local Vision, or Manual. Compatibility comes from Ollama-reported capabilities (with `/api/show` only when tag capability metadata is absent), never from model-name matching. Requests are loopback-only, never download models, make one bounded repair retry, and unload after success or failure. Analysis is disabled while LTX generation is active.
- Vision output is always an editable `CharacterSheetAnalysisCandidate`. New characters are created only after Review/Save. Existing characters show Current vs Detected and default all non-empty fields to not applied; selective apply preserves the UUID. Personality, speaking style, and trait locks are never inferred from appearance.
- Canonical GUI acceptance used the locally created 1600×1600 synthetic `CharacterSheet-Phase1-Acceptance.png` because the exact user sample was not accessible and no external image was downloaded. Auto selected the already-installed reported-Vision model `agents-a1:32k`; its response still lacked the required appearance structure after one repair, so the product correctly entered Manual Review. No model pull occurred and `/api/ps` was empty afterward.
- Saved Storyboard project `7F85893F-D234-41BC-97ED-635D4EAA533A` retained Maya plus the original Character Sheet and propagated reviewed face/hair/eyes/costume/accessories into the compiled prompt. Source and managed-copy SHA-256 were identical (`27a289b...d1b7a`). Existing-character import displayed selective merge controls; Cancel removed the staged second copy and preserved the original source and first managed asset.
- Paragraph-separated Basic Director acceptance project `7DDDD8E2-C149-41CB-B49C-08A3CD7CDEC7` created three 5-second shots. Every Shot references stable UUID `9C0C46EE-DBF7-4F0B-BCA2-9C576618FD1B`; compiled prompts include reviewed visual data plus explicit Face/Hair/Eyes textual locks. Exact-path quit/relaunch restored the project, character, sheet metadata, and all assignments. Hybrid exposes the same shared import/character controls.
- Deferred by design: PDF parsing, automatic crops, face recognition/embedding, identity conditioning, passing sheet bytes to LTX, multi-view conditioning, and any same-person guarantee.

## Feature Flags
GUI-first defaults (D-007): modelRegistryV1 / autoQualityV1 / directorV1 / filmProjectV1 / storyboardV1 = **ON** by default; derivedModelsV1 / adultModelsV1 / lowRAMAdapterV1 / localAPIv1 = OFF (opt-in). All OFF (Preferences → Models & Features) = byte-identical legacy behavior (proven by MD5-identical regression render). Quality defaults to "Advanced" (= manual parameters untouched).

## GUI (verified in the final running .app, 2026-08-08)
- Sidebar: Generate / One Shot / Storyboard / Director / Hybrid / Video Archive, with concise mode descriptions.
- Generate: Model + Preset picker; no primary Quality picker; non-Custom shows a preset explanation, Custom restores all legacy manual controls.
- One Shot: independent Brief / Preset / Model / Target Duration / Audio / Create & Generate screen.
- Storyboard: Project Settings, Custom resolution controls, Generate Missing, Regenerate Selected Shots, per-shot regeneration, append-only Take review/selection and Final Assembly.
- Hybrid: Brief / Preset / Model / Audio / Target Duration / Create & Generate sheet; automatic short-shot split and single-flight first-pass queue; same review/retake/assembly workspace.
- Video Archive: Requested / Effective / Actual (MP4) / Actual Length rows
- Video Archive inspection reproduced the bug before the fix: same prompt Quick C3 and Standard C3 were both 512×320/49f/15 steps (~70 s), while High H0 was 768×512/121f/30 steps (~275 s).
- One Shot now has its own persisted preset key; selecting Quick there leaves Generate on Standard. Non-Custom Generate no longer displays warnings from stale hidden manual FPS.
- Preferences → Models & Features: Adult Content Mode + all flags + Compatibility Lab status

## Last Known Good Commit
- Previous downstream checkpoint: `7302c67` on `director-extensions` (`docs: record storyboard 4bit e2e acceptance`).
- This document is included in the local `fix: harden storyboard director structured output` checkpoint, verified with 368 tests, Xcode Debug build, and canonical-app pure Storyboard GUI acceptance. No push was performed.
- This update is included in the local `feat: add zero-setup storyboard director experience` checkpoint, verified with 396 tests and the three canonical-app GUI cases above. No push was performed.
- CharacterBible Phase 0 is the reviewed worktree following `7a3d44b`; it is verified with 444 tests and the Storyboard/Hybrid GUI cases above and will be recorded as local `feat: add character bible foundation`. No push is performed.
- CharacterBible Phase 1 is the reviewed worktree following `f111ba4`; it is verified with 498 tests and the canonical Character Sheet import/Manual Review/Storyboard propagation cases above and will be recorded as local `feat: add local character sheet import`. No push is performed.

## Exact Resume Action
`cd /Users/azimnb/ltx23appdev/ltx-video-mac && git status && swift run LTXTests && xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
