# BASELINE — Phase 0 Audit

Date: 2026-08-08
Git baseline: upstream `main` @ `a441dc2372fd1f245930f822a30e079a328109b5` (CHANGELOG top: 2.3.66)
Branch for work: `director-extensions`

## Source layout
```
LTXVideoGenerator/
  LTXVideoGenerator.xcodeproj
  Sources/
    LTXVideoGeneratorApp.swift   (App entry, RootView, Python launch validation)
    PythonEnvironment.swift      (821 loc; validation, package install, PythonKit config)
    Models/
      GenerationRequest.swift    (LTXModel, LTXModelCatalog, LTXTextEncoderCatalog, GenerationRequest, GenerationParameters)
      GenerationResult.swift
      Preset.swift               (built-in presets incl. Low Memory Preview 512x320/25f/15steps)
      CharacterProfile.swift
    Services/
      GenerationService.swift    (single-flight queue; addBatch(any count); @MainActor)
      LTXBridge.swift            (1033 loc; Python subprocess; 64-px floor; failure diagnosis)
      APIServer.swift            (NWListener port 8420; /status /queue /generate DELETE /queue/:id; wildcard CORS; NO token; NO loopback restriction param)
      HistoryManager.swift       (history.json in App Support/LTXVideoGenerator)
      AudioService.swift         (1145 loc; voiceover mlx-audio/elevenlabs; music; ffmpeg mux)
      PresetManager.swift, MacOSSystemMemory.swift, GenerationFailureRecovery.swift, LTXGenerationLogSummary.swift
    Views/ (ContentView, PromptInputView 3/5 variations UI, QueueView, HistoryView, ParametersView, PreferencesView, AddAudioView)
  Resources/ (av_generator.py, audio_generator.py, enhance_prompt_preview.py, prompts/)
```

## Research hypotheses re-verified against local code
| Hypothesis | Verdict |
|---|---|
| GenerationService is single-flight | CONFIRMED (`processingTask == nil` guard, sequential `processNextIfNeeded`) |
| No fixed 3/5 cap in service; `addBatch` takes any count | CONFIRMED |
| 3/5 variations is UI-only (PromptInputView buttons) | CONFIRMED (lines ~628-640) |
| width/height floored to 64 multiple | CONFIRMED (`(params.width / 64) * 64` LTXBridge:250) |
| APIServer exists, port 8420 | CONFIRMED. No auth token, `Access-Control-Allow-Origin: *`, binds all interfaces (NWListener default), no I2V source image field |
| GenerationRequest has modelId, no revision | CONFIRMED |
| unloadModel() is bool-state only, not MLX release | CONFIRMED (LTXBridge.unloadModel just flips flag) |
| Subprocess exit = memory reclamation boundary | CONFIRMED (each generation is its own `python -c` → `mlx_video.generate_av` child) |

## Environment
- Apple M4 Pro, 48 GB, macOS 26.5.2, Mac16,11
- No Xcode.app; CLT with Swift 6.3.3, macOS 26.5 SDK. swift-build present → SPM harness for build/test.
- ffmpeg/ffprobe: /opt/homebrew/bin (Homebrew)
- Python venv ~/ltx-venv: Python 3.14.5, mlx 0.32.0, mlx-video-with-audio 0.1.36 (pip; no local checkout at ~/projects/mlx-video-with-audio despite pref useLocalMlxVideoRepo=1 → pip path taken)
- Models cached: notapalindrome/ltx23-mlx-av-q4 (~20GB) = catalog default `ltx23_distilled_q4`; gemma-3-12b-it-4bit (selected), 12b bf16, 4b bf16
- User has been running distributed app 2.3.66 (real prefs + prior session state present)

## Baseline generation plan
Harness: `scripts/benchmark_baseline.sh` (added by this work) runs `mlx_video.generate_av` with the exact CLI the app builds, capturing time + peak RSS (`/usr/bin/time -l`) + swap (`sysctl vm.swapusage`) + ffprobe of output.
Reference profile (Low Memory Preview equivalent): 512x320, 25 frames, 15 steps, 24fps, seed 42, audio ON and audio OFF variants.
Results recorded in BENCHMARK_RESULTS.md as they are measured.

## Acceptance targets for later phases
- Peak RAM <= baseline x 1.05; generation time <= baseline x 1.05 (median of runs, worst peak); actual resolution/fps/duration/audio unchanged (ffprobe = source of truth).
