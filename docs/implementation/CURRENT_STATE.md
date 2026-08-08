# CURRENT_STATE

Updated: 2026-08-09

## Current Phase
Preset/Quality and text-encoder propagation hardening is complete. Pure Storyboard structured output is also hardened and has passed a real local-Ollama multi-shot GUI acceptance; the previously verified cached-model Storyboard/Hybrid render, mixed-resolution final assembly, and cancellation paths were not changed.

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

## In Progress
- No open item in the Storyboard structured-output repair scope. Optional broader planning-quality evaluation remains separate from schema transport and validation correctness.

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
- `swift run LTXTests`: **368 checks, 0 failures** (including structured-output extraction/repair/failure-stage coverage, planning metadata migration, new-project text-encoder inheritance, Hybrid request propagation, and cancelled Take/Job persistence).
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

## Known Blockers / Remaining Human Actions
1. ~~No Xcode.app~~ → RESOLVED: Xcode 26.6 installed; unsigned dev .app builds and runs. Remaining: Developer ID signing + notarization for distribution (needs credentials).
2. 10Eros weights not downloaded (user authorization required, tens of GB) → lab models stay verified=false. To verify: download weights, run scripts/compat_lab_smoke.sh, record checks in Compatibility Lab.
3. No 16GB hardware → LowRAM adapter Runtime Verification Pending; run scripts/lowram_bench.sh on a 16GB Mac (a dgrauet/ltx-2-mlx checkout already exists at ~/AI/LTX-MLX/ltx-2-mlx with a Q8 model).
4. Full 20-take queue soak (scripts/queue_soak.sh 20, ≈17 min) not yet run; 3-take validation done.
5. ~~Fresh post-fix Quick/High real render pending~~ → RESOLVED: the 2026-08-09 canonical-app E2E completed three Quick renders, one High retake, mixed-resolution assembly, QuickTime playback and cancellation using cached Q4 + 4-bit weights.
6. Storyboard real-generation root cause (resolved): the shared Storyboard/Hybrid creation sheet previously initialized `ProjectSettings()` and captured schema default `gemma3_12b_bf16`; it now inherits the current `gemma3_12b_4bit` selection. Existing projects intentionally retain their stored encoder snapshot. A pre-fix scratch project that was cancelled before cancellation-persistence existed may still contain queued status; there is intentionally no automatic migration of old project intent/state.

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

## Exact Resume Action
`cd /Users/azimnb/ltx23appdev/ltx-video-mac && git status && swift run LTXTests && xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO build`.
