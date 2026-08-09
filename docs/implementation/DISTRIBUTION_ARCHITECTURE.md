# LTX Video Generator - Distribution Architecture

Updated: 2026-08-09 (Phase A2)

## v1 Strategy: Thin Client

The LTX Video Generator is distributed using a **Thin Client Strategy**.
This means that the `.app` bundle acts as a lightweight interface and orchestrator, but relies on external components for heavy computational work.

### Python / MLX Backend
- **Environment**: External isolated Python environment (user-managed venv).
- **Compatibility actually exercised**: Python 3.14.5 with
  `mlx-video-with-audio` 0.1.36. The package declares Python 3.11 or newer;
  this is the minimum accepted by the app. It is not a claim that every newer
  Python release has been production-qualified.
- **Required core import**: `mlx_video.generate_av` and the LTX text-encoder
  module. `torch`, `diffusers`, and optional MLX Audio/TTS imports are not
  readiness requirements for this MLX video path.
- **Reasoning**: Bundling a full Python runtime and the `mlx-video-with-audio` package (which compiles Metal shaders at runtime) within the `.app` would significantly increase the bundle size and introduce complex nested signing and Hardened Runtime conflicts.
- **Path Resolution**: The app relies on explicit paths configured by the user or trusted known paths detected during the First Run Setup Wizard.
- **Isolation**: the render wrapper clears inherited `PYTHONPATH`; it does not
  fall back to a developer checkout such as `~/projects/mlx-video-with-audio`.

### FFmpeg
- **Environment**: External executable.
- **Reasoning**: We do not bundle FFmpeg to avoid binary signing complexity and redistribution/license reviews. The app utilizes existing FFmpegDetector logic to find Homebrew installations.

### Models and Encoders
- **Environment**: External cache (`~/.cache/huggingface/hub`).
- **Reasoning**: Machine learning models and text encoders (weighing upwards of 10GB) are too large to package into a DMG. The app checks for their existence and completeness via the `HuggingFaceCacheChecker`.
- **Readiness policy**: a cache is ready only when a snapshot includes
  metadata (`config.json` or `model_index.json`) and a non-empty
  `.safetensors` file. This avoids treating an interrupted repository
  directory as a ready model without hashing or loading multi-gigabyte files.

## Security & App Sandbox

### App Sandbox
- **Status**: OFF for v1 direct distribution.
- **Reasoning**: Developer ID direct distribution does not strictly require the App Sandbox. Disabling the Sandbox ensures seamless subprocess execution for `/opt/homebrew` and local Python environments, which are necessary under the Thin Client architecture. Future App Store distribution would require revisiting this.

### Hardened Runtime
- **Status**: ON.
- **Exceptions**: None. In particular, do not add
  `disable-library-validation`, `allow-unsigned-executable-memory`, or
  `disable-executable-page-protection` merely because Python or FFmpeg is a
  child process. Add the smallest exception only after a reproducible runtime
  failure proves it necessary.

## Scope and privacy

Core video rendering, models, and Ollama/Local Vision are local. First-run
setup or model installation can involve an explicit external download. Optional
integrations such as ElevenLabs can use their own network service only after an
explicit user action; the app does not claim that it never makes a network
request.

## Packaging trust chain

The `distribution` mode requires a valid **Developer ID Application** identity,
Hardened Runtime, a secure timestamp, an accepted `notarytool` submission,
stapling, and Gatekeeper verification. Apple documents Developer ID signing,
notarization, `notarytool`, and stapling in [Notarizing macOS software before
distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Customizing the notarization workflow](https://developer.apple.com/documentation/Security/customizing-the-notarization-workflow).

`local-test` is deliberately separate: it is an ad-hoc signed Release build
for local validation only and is never distribution-ready.
