# Generation Backends

The app runs local video generation through more than one Python runtime,
because the model families it supports are packaged for different loaders.
Everything above the bridge — Director, Storyboard, Auto Movie, Production
Queue, Continuity, Final Assembly — is backend-agnostic and stays that way.

## Routing

```
One Shot / Storyboard / Auto Movie / Regenerate / Production Queue / API v1
                              │
                              ▼
                   GenerationModelResolver          ← the only place a model
                              │                       ID picks a runtime
              ┌───────────────┴───────────────┐
              ▼                               ▼
     mlx-video-with-audio                 ltx-2-mlx
              │                               │
              ▼                               ▼
          LTX-2.3 (default)        Custom MLX Models (User Configured)
```

`GenerationModelResolver.resolve(modelID:)` returns either a `RunnableModel`
(the model plus its `GenerationBackendKind`) or an `UnsupportedReason`. It never
falls back to a different checkpoint: a model that cannot run has *no* backend
rather than the default one. That rule is what keeps a failed custom model request
from being quietly served by the LTX-2.3 backend.

Routing is table-driven — `LTXModelCatalog` for the official backend,
`CustomLTX2MLXModelCatalog` for `ltx-2-mlx`. Nothing matches on substrings of a model
name.

## Why Two Runtimes

Official LTX-2.3 models run through `mlx-video-with-audio`. Certain fine-tuned
and distilled weights in the ecosystem use tensor naming or quantization
schemes (such as specific attention gating and group sizes) targeted at
`ltx-2-mlx`.

To provide flexibility while keeping official LTX-2.3 completely stable,
the secondary `ltx-2-mlx` runner provides an isolated execution path for
user-configured custom models.

LTX-2.3 deliberately stays on `mlx-video-with-audio`.

## Environments

The two runtimes pin different dependency versions and cannot share one
environment:

| | mlx-video-with-audio | ltx-2-mlx |
|---|---|---|
| Python | 3.14 | 3.11 |
| MLX | 0.32.0 | 0.31.1 |

Each is configured independently in Preferences. The `ltx-2-mlx` executable path is a user
preference with no default, so no machine-specific path is baked into the build.

## Readiness

Runtime readiness and model readiness are tracked separately
(`LTX2MLXRuntime.Readiness`). They fail independently and have different
remedies — configure a runtime executable, or download weights. Generation requires both.

Weights are never fetched implicitly. Custom model downloads are triggered
explicitly by user action in Preferences.

## Adding a Backend Later

### LTX-2.5

If `ltx-2-mlx` gains LTX-2.5 support, it is a new entry in
`CustomLTX2MLXModelCatalog` with `backend: .ltx2MLX` — no new backend, no workflow
changes. If it needs its own runtime, add a `GenerationBackendKind` case and a
service alongside `LTX2MLXBackend`, then a catalog the resolver consults. The
layers above the bridge do not change either way.

### MiniMax H3

A different architecture, so it would be its own `GenerationBackendKind` case
and its own backend service. What it reuses unchanged: the Director, Storyboard,
Auto Movie, FilmProject/Take persistence, Production Queue, Continuity and Final
Assembly. What it would need at the boundary: whatever request fields it
genuinely requires, added when it is implemented — not speculatively now.

Neither is implemented. These are insertion points, not plans.
