# Local Video Studio v0.9.0 Preview 18

This public preview updates the model-readiness workflow and makes configured local model identity easier to verify before generation.

## Highlights

- Custom local LTX-2 MLX profiles remain available after app updates when their configured folder and runtime are still present.
- Generation model pickers show only models that are ready on the current machine.
- Custom model lists show the configured local folder name (not the user's absolute path), so similarly named models can be distinguished without leaking machine paths.
- The existing Generate, One Shot, Storyboard, Hybrid, Auto Movie, queue, and project workflows remain unchanged.

## Notes

- This is a source-first public preview for Apple Silicon macOS.
- Model weights are not bundled. Users must configure or download compatible local models explicitly.
- The app runs inference locally; no model files or user projects are uploaded by the core workflows.
- A signed/notarized DMG is not included in this source publication. Build with Xcode or the documented local build scripts.
