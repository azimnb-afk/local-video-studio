# Generation backends

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
          LTX-2.3 (default)                10Eros
```

`GenerationModelResolver.resolve(modelID:)` returns either a `RunnableModel`
(the model plus its `GenerationBackendKind`) or an `UnsupportedReason`. It never
falls back to a different checkpoint: a model that cannot run has *no* backend
rather than the default one. That rule is what keeps a failed 10Eros request
from being quietly served by the LTX-2.3 backend and labelled as 10Eros.

Routing is table-driven — `LTXModelCatalog` for the original backend,
`LTX2MLXModelCatalog` for `ltx-2-mlx`. Nothing matches on substrings of a model
name.

## Why two runtimes

`mlx-video-with-audio` cannot load the published 10Eros MLX conversions. This
was measured against the weights, not inferred:

| | 10Eros v1.3 DMD q4 | LTX-2.3 q4 (working) |
|---|---|---|
| Transformer file | `transformer-distilled.safetensors` | `transformer.safetensors` |
| Gated attention | 576 `to_gate_logits.*` tensors | absent |
| Quantization group size | 32 (declared in `quantize_config.json`, absent from `split_model.json`) | 64 |
| Quantized layers | transformer blocks only | broader |

`mlx-video-with-audio` derives the transformer filename from the component
prefix and reads the group size from `split_model.json` with a default of 64, so
it would load an empty weight dict and then mis-dequantize. `ltx-2-mlx`
resolves `transformer-distilled*.safetensors` explicitly, implements gated
attention, and *derives* `(bits, group_size)` from the tensor shapes. The 10Eros
model card states it is packaged for `ltx-2-mlx`.

LTX-2.3 deliberately stays on `mlx-video-with-audio`. Migrating it would change
two variables at once and put a working production path at risk.

## Environments

The two runtimes pin different dependency versions and cannot share one
environment:

| | mlx-video-with-audio | ltx-2-mlx |
|---|---|---|
| Python | 3.14 | 3.11 |
| MLX | 0.32.0 | 0.31.1 |

Each is configured independently. The `ltx-2-mlx` executable path is a user
preference with no default, so no machine-specific path is baked into the build.

## Readiness

Runtime readiness and model readiness are tracked separately
(`LTX2MLXRuntime.Readiness`). They fail independently and have different
remedies — install a runtime, or download ~23 GB — so a single "not ready" flag
would send the user to the wrong fix. Generation requires both.

Weights are never fetched implicitly. Enabling Adult Content Mode makes 10Eros
*selectable*; the download is a separate, explicit action
(Missing → Download → Downloading → Ready, with Retry on failure).

## Adding a backend later

### LTX-2.5

If `ltx-2-mlx` gains LTX-2.5 support, it is a new entry in
`LTX2MLXModelCatalog` with `backend: .ltx2MLX` — no new backend, no workflow
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
