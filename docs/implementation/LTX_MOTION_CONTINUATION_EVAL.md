# LTX Motion Continuation — Feasibility

**Date:** 2026-08-12
**Classification: PARTIAL — PRIMITIVE EXPRESSIBLE, INSTALLED BACKEND HAS NO PATH TO IT**

Research only. No implementation, and no experiment — for the reason below,
one cannot be run without modifying a vendored dependency.

## 1. Question

Not "does LTX support video conditioning" but: can **the backend this app
actually calls** accept a previous shot's tail *video* as temporal conditioning?

Installed: `mlx-video-with-audio` **0.1.36**, MLX 0.32.0, at
`/Users/azimnb/ltx-venv/lib/python3.14/site-packages/mlx_video`. Unchanged since
the earlier audit.

## 2. What exists

**The conditioning primitive already accepts multiple frames.**
`conditioning/latent.py` → `VideoConditionByLatentIndex` exposes
`get_num_latent_frames()` returning `latent.shape[2]`, and `apply_conditioning`
handles it properly:

```python
num_cond_frames = cond_f
end_idx = min(frame_idx + num_cond_frames, f)
```

So injecting an N-frame tail latent at a frame index is *architecturally
supported* by the latent-replacement mechanism. `apply_conditioning` also takes
a **list**, so several conditionings could coexist.

The video VAE is a genuine video VAE — it decodes multi-frame output — so the
encoder side is not the obstacle either.

## 3. What is missing

Three plumbing gaps, all in the installed package:

| Gap | Evidence |
| --- | --- |
| **No video decode for conditioning** | no `load_video` / `VideoCapture` / `av.open` anywhere; the only `imageio` use is *writing* WAN output |
| **Preparation is single-frame by construction** | `prepare_image_for_encoding` ends `mx.expand_dims(image, axis=2)  # (1, 3, 1, H, W)` — the frame dimension is hardcoded to 1 |
| **No surface to reach it** | CLI exposes only `--image`, `--image-strength`, `--image-frame-idx`; `generate_video_with_audio` exposes only `image`, `image_strength`, `image_frame_idx` |

`--image` goes through PIL `Image.open`, so pointing it at a video is not a
workaround.

## 4. Why no experiment was run

An honest tail-video test requires building an F>1 conditioning latent, and
there is no path from any public surface to one. The only way to try tonight
would be to patch `site-packages` — modifying an installed third-party
dependency, which is neither a valid experiment nor something to leave behind on
a working machine. §33 explicitly rules out an overnight port.

So this is a genuine "cannot be expressed by the usable backend" answer, not a
result that was skipped.

## 5. Scope of the gap

**Bounded, and notably not a port.** The hard parts — the multi-frame
conditioning primitive and the video VAE — are already present. What is needed:

1. a video reader producing an (F, H, W, 3) tensor for a tail segment
2. a `prepare_video_for_encoding` that does not collapse the frame axis
3. encode → `VideoConditionByLatentIndex(latent, frame_idx: 0, strength)`
4. a CLI/API argument to reach it

That is upstream work on `mlx-video-with-audio`, or a maintained fork — not a
PyTorch/diffusers migration and not IC-LoRA.

## 6. Consequence

**LTX Continuity v1 (last frame) remains the production system.** That is a
valid outcome, not a fallback: it is accepted, tested and shipping.

The known limitation stands and is now precisely located — a single still
carries pose and appearance but not velocity or direction, so joins can restart
motion. Fixing that needs temporal conditioning the installed backend cannot
currently express.

## 7. Future shape (documentation only — not implemented)

```
ContinuationContext
├ LastFrame      ← implemented today
├ TailVideo      ← needs the four items in §5
├ TailAudio
├ PreviousPrompt
└ References
```

Model adapters (LTX, and others later) would sit behind that. **No H3 work was
done**: nothing downloaded, nothing integrated, no refactor toward a
hypothetical API — deliberately, per the brief.

## 8. Recommendation

Do not pursue tail-video conditioning until either upstream adds a multi-frame
conditioning surface, or the join-quality limitation is shown to matter more
than the remaining identity work. Watch `mlx-video-with-audio` releases for a
video-conditioning argument; that release is the trigger to revisit.
