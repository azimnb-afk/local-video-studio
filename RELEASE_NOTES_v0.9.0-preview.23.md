# Local Video Studio v0.9.0 Preview 23

Preview 23 improves LTX-2.5 local model setup and persistence.

## LTX-2.5 improvements

- LTX-2.5 keeps its own local model-folder setting.
- A valid selected LTX-2.5 model remains available after restarting or updating the app.
- Existing local model folders are validated before they are marked Ready.
- Incomplete or unrelated model folders are rejected instead of being used accidentally.
- LTX-2.3 custom-model settings remain independent from LTX-2.5.
- Starting generation does not silently download another model or switch models.

## Download and setup

Download the ZIP or DMG asset from the GitHub Release. This is an unsigned,
not-notarized macOS preview; use Finder's **Open** command the first time if
macOS asks for confirmation. No model weights are bundled. Configure compatible
local models from Settings → Models & Features.

The app does not automatically repair arbitrary model folders or download a
missing LTX-2.5 model during generation.
