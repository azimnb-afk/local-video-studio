# Third-Party Notices

This file lists third-party software this application depends on or links against at build/runtime. It does **not** cover model weights — see [MODEL_LICENSES.md](MODEL_LICENSES.md) for those.

Sources were checked directly against each project's own repository/package registry page. Anything not confirmable from an official source is marked **Needs external verification** rather than guessed.

| Name | Purpose | License | Upstream | Bundled or runtime-only |
|:---|:---|:---|:---|:---|
| [PythonKit](https://github.com/pvieito/PythonKit) (pvieito fork) | Swift↔Python bridge; sole Swift Package Manager dependency, pinned to a specific commit revision in `Package.swift` / `Package.resolved` | Apache License 2.0 | `github.com/pvieito/PythonKit` | Bundled (source dependency, resolved via Swift Package Manager at build time) |
| [MLX](https://github.com/ml-explore/mlx) | Apple's array/ML framework; the Python `mlx_video`/`mlx-video-with-audio` backend runs on top of it | MIT License (Apple Inc.) | `github.com/ml-explore/mlx` | Runtime-only — installed into the user's Python environment via `pip`, not bundled in this repository or the app bundle |
| [mlx-video-with-audio](https://pypi.org/project/mlx-video-with-audio/) | The actual video/audio generation backend this app shells out to; minimum pinned version `0.1.36` | MIT License | PyPI: `mlx-video-with-audio` | Runtime-only — installed into the user's Python environment via `pip`, not bundled |
| [ffmpeg](https://ffmpeg.org/) / `ffprobe` | Final Assembly (muxing shots into one video), shot-continuity frame extraction, media duration probing | LGPL/GPL, version depends on how the user's `ffmpeg` build was configured — **Needs external verification per installation** (this project does not control or distribute the binary) | `ffmpeg.org` | Runtime-only — the app searches fixed candidate paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) for a user-installed binary (e.g. via `brew install ffmpeg`); **not bundled, not distributed, and not compiled by this repository** |
| [ltx-2-mlx](https://github.com/dgrauet/ltx-2-mlx) | Second local generation backend; a pure-MLX port of LTX-2 for Apple Silicon. Runs the 10Eros model, which the `mlx-video-with-audio` loader cannot read. Audited at v0.14.19 (commit `e1838a8`) | MIT License (confirmed from the repository's own `LICENSE` and GitHub API license metadata) | `github.com/dgrauet/ltx-2-mlx` | Runtime-only — installed by the user into a separate Python 3.11 environment (it pins different MLX versions than the LTX-2.3 backend); not bundled and not distributed by this repository |
| [Blaizzy/mlx-video](https://github.com/Blaizzy/mlx-video) | Origin of the MLX video-generation approach that `mlx-video-with-audio` builds on | Needs external verification — check the upstream repository directly before relying on this | `github.com/Blaizzy/mlx-video` | Not directly depended on by this Swift codebase; credited because `mlx-video-with-audio` is derived from it |

## Notes

- This repository's own Swift and Python source (everything under `LTXVideoGenerator/Sources` and its bundled helper scripts) is MIT-licensed — see [LICENSE](LICENSE). This file is about *other people's* code this app depends on, not this repository's own code.
- Nothing in this table is bundled inside the built `.app` except the PythonKit Swift source, which is compiled in. MLX, `mlx-video-with-audio`, and `ffmpeg` are all installed separately by the user into their own Python environment / Homebrew prefix and invoked as external processes or imports at runtime — none of their binaries or wheels ship inside this repository or the app bundle.
- **Maestro / WanGP**: Design/reference only — no code copied. Mentioned in development design discussions only; no third-party code from those projects is incorporated or distributed.
- If you distribute a signed/notarized build of this app, you are responsible for independently confirming license compliance for however you package these runtime dependencies (e.g. if you ever choose to vendor or bundle any of them, which this project currently does not do).
