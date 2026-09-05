# Local Video Studio v0.9.0 Preview 19

This preview makes the latest public source snapshot directly usable by macOS testers through a GitHub Release download.

## Highlights

- Includes the model-readiness fixes from Preview 18.
- Custom local model pickers show the configured folder name without exposing an absolute machine path.
- A GitHub Actions job packages an unsigned Apple Silicon macOS app as a zip for preview users.
- The source release remains clean-history and contains no model weights or user data.

## Download and first launch

1. Download `LocalVideoStudio-0.9.0-preview.19-unsigned.zip` from the GitHub Release.
2. Expand the zip and move `Local Video Studio.app` to Applications if desired.
3. On first launch, use Finder's **Open** command (or Control-click → Open) to approve this unsigned preview.

Because this build is unsigned/not notarized, macOS may show an additional confirmation. This is expected for the preview and is not a Developer ID distribution.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Python 3.11+ and `ffmpeg` for generation and assembly.
- Compatible local model weights configured explicitly by the user; no weights are bundled.
