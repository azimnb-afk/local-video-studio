# Character Reference Capability Audit

Date: 2026-08-09  
Baseline: `1d65b3bb1ea57a6d8379cd561b9a9ebfd2ed8799` (`feat: extract character reference assets from sheets`)  
Scope: CharacterBible Phase 3 audit only; no production reference/identity wiring

## Executive Summary

- **Can the extracted 344×499 Face Reference provide true face-only identity locking? NO.** The installed MLX backend has no face/identity encoder, identity embedding, subject token, adapter, identity mask, or character binding. Its sole image input is VAE-encoded and injected into a selected temporal video latent. That constrains the frame's full pixels/composition; it does not isolate facial identity from hair, costume, pose, background, lighting, or camera.
- **Can Front + Side + Back be supplied simultaneously as one character reference set? NO.** The installed public generation function and CLI accept one image. An internal helper accepts a list of temporal latent conditions, but the public pipeline constructs exactly one item and has no subject/reference-set semantics.
- **Can this backend perform generic, non-temporal reference-image conditioning? NO.** The image is a video-frame condition, not a global appearance or identity reference.
- **Can current I2V be marketed as Face Lock? NO.** Passing a face crop as the one I2V image is only an experimental misuse of a starting-frame mechanism and is likely to leak crop framing/composition. A visually similar result would not prove identity conditioning.

Product decision: **D — the installed backend provides single-image temporal I2V only. Do not implement or label Face Lock / Identity Lock.** Keep the Phase 2 assets as a high-quality local reference library until a separately verified identity-capable backend exists.

## Environment

The values below were measured from the app's preferences, model catalog, active cache, and the Python environment selected by `LTXBridge`; none were inferred from an old session.

| Item | Actual value |
|---|---|
| App branch / baseline | `director-extensions` / `1d65b3b` |
| Python executable | `/Users/azimnb/ltx-venv/bin/python3` |
| Python version | 3.14.5 |
| Python package | `mlx-video-with-audio` 0.1.36 |
| Imported source | `/Users/azimnb/ltx-venv/lib/python3.14/site-packages/mlx_video` |
| Generation entry point | `python -m mlx_video.generate_av` |
| Model catalog ID / repo | `ltx23_distilled_q4` / `notapalindrome/ltx23-mlx-av-q4` |
| Model cache | `~/.cache/huggingface/hub/models--notapalindrome--ltx23-mlx-av-q4/snapshots/88b4b5b2ed7697c25f281e76e3c692f659027ab1` (~20 GiB) |
| Model config | `model_type=AudioVideo`, `model_version=2.3.0`, 48 transformer layers |
| Quantization | 4-bit, group size 64 (`quantize_config.json`) |
| Text encoder | `mlx-community/gemma-3-12b-it-4bit` (~7.5 GiB cache) |
| Extra identity/vision component | None in the selected model/package path |

`LTXBridge.setupPythonPaths()` reads the `pythonPath` preference at `LTXBridge.swift:122-169`; the current preference resolves to the executable above. The stale optional local checkout path is absent, so the pip package is the actual imported implementation.

### Phase 2 acceptance assets

FilmProject JSON, rather than a guessed path, identifies project `07FA8292-0C89-4545-9D27-F1F64942C108`, character `7F76DC58-1349-40F4-9D1F-B29352D83605`, and source sheet asset `E7E526E4-F036-4D73-8FC1-458503CAC828`. Relevant project-owned inputs are:

- Front: `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/07FA8292-0C89-4545-9D27-F1F64942C108/Assets/Characters/7F76DC58-1349-40F4-9D1F-B29352D83605/References/8962D90A-0D53-45AC-A0AC-092979F2F55A.png` (287×774)
- Face / Close-Up: `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/07FA8292-0C89-4545-9D27-F1F64942C108/Assets/Characters/7F76DC58-1349-40F4-9D1F-B29352D83605/References/BDEB1F6C-98E4-4ECB-B132-6A9114F53F8B.png` (344×499)

Side, Back, Expression, and Costume Detail are siblings in the same managed `References` directory and retain their Phase 2 source UUID/crop provenance. No audit operation modified them.

## Current Generation Pipeline

```text
Generate SwiftUI (one optional Source Image)
  -> GenerationRequest.sourceImagePath + parameters.imageStrength
  -> GenerationSettingsResolver (quality/preset parameters; preserves source image)
  -> GenerationService
  -> OfficialMLXAudioAdapter
  -> LTXBridge.generate
  -> embedded Python wrapper
  -> python -m mlx_video.generate_av
       --image <one path>
       --image-strength <value>
       [no --image-frame-idx from the app, so backend default = 0]
  -> load/resize image -> LTX VAE encoder
  -> VideoConditionByLatentIndex(frame_idx=0)
  -> two-stage joint audio/video denoising
  -> MP4
```

Source evidence:

- `GenerationRequest.swift:173-209` has exactly one image field, `sourceImagePath`; there is no last image, image list, reference set, mask, or character/reference binding.
- `PromptInputView.swift:369-400` selects one Source Image, describes it as the first frame, exposes `imageStrength`, and maps both into the request at `875-895`.
- `GenerationService.swift:190-240` resolves the request and routes the official descriptor through `OfficialMLXAudioAdapter`; `VideoGenerationAdapter.swift:17-35` is a thin call into the same bridge.
- `LTXBridge.swift:391-418` launches `mlx_video.generate_av` and adds only `--image` and `--image-strength`. It never supplies `--image-frame-idx`, so the installed default of zero is always used by the app.
- Local API v1 also admits exactly one uploaded `assetID` and maps it to one `sourceImagePath` (`APIv1Handler.swift:122-159,183-211`).
- CharacterBible reference paths do not appear anywhere in `GenerationRequest`, `GenerationService`, `LTXBridge`, or the Python invocation. Storyboard/Hybrid therefore remain textual continuity only.

## Current I2V Implementation

Installed `generate_video_with_audio` at `mlx_video/generate_av.py:1151-1176` exposes the following relevant parameters:

```python
generate_video_with_audio(
    model_repo: str,
    text_encoder_repo: str | None,
    prompt: str,
    height: int = 512,
    width: int = 512,
    num_frames: int = 33,
    seed: int = 42,
    fps: int = 24,
    output_path: str = "output_av.mp4",
    output_audio_path: str | None = None,
    save_audio_separately: bool = False,
    negative_prompt: str | None = ...,
    cfg_scale: float = 3.0,
    verbose: bool = True,
    enhance_prompt: bool = False,
    use_uncensored_enhancer: bool = False,
    max_tokens: int = 512,
    temperature: float = 0.7,
    image: str | None = None,
    image_strength: float = 1.0,
    image_frame_idx: int = 0,
    tiling: str = "auto",
    num_inference_steps: int = 30,
    no_audio: bool = False,
)
```

There is no `images`, `reference_image(s)`, `first_image`, `last_image`, `keyframes`, user mask, character ID, face encoder, identity scale, or prompt-to-reference binding parameter.

The actual mechanism is explicit:

1. `generate_av.py:1560-1596` loads the one image at stage-1 and stage-2 sizes and VAE-encodes it. It does not compute a CLIP/SigLIP/face/identity embedding.
2. `generate_av.py:1612-1644` and `1722-1749` create one `VideoConditionByLatentIndex` for the selected temporal latent position and apply it at both stages.
3. `conditioning/latent.py:84-147` replaces that temporal slice with the image latent and gives it a denoise mask of `1 - strength`; `apply_denoise_mask` blends clean and denoised latent values. All spatial content in the encoded image participates.
4. Audio starts from noise and is jointly denoised through the same A/V transformer (`generate_av.py:1646-1665,1751-1775`). Image conditioning is video-side, but audio generation remains compatible.

The installed docstrings/CLI call `image_strength=1.0` “full denoise”, but the implementation sets the conditioned-frame mask to `1 - strength`; therefore the code's real behavior is the authority: `1.0` preserves the clean image latent most strongly. This control is a temporal I2V denoise/preservation control, **not** generic reference guidance strength.

The internal `apply_conditioning` helper accepts a list, but the public function constructs a list containing exactly one condition from exactly one `image` parameter. That internal collection type alone does not establish public multi-image support.

## Official LTX Capabilities

Official sources are used only to identify architecture/backend gaps; the installed MLX code remains the app capability source of truth.

- The official LTX-2 pipelines describe T2V, I2V, V2V, audio, keyframe interpolation, and retake pipelines: <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/README.md>.
- The official keyframe interpolation pipeline accepts `images: list[ImageConditioningInput]`, so official code can place multiple image conditions at temporal frame locations: <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/src/ltx_pipelines/keyframe_interpolation.py>.
- The earlier official inference implementation likewise pairs multiple `conditioning_media_paths`, strengths, and start frames. These are temporal media/keyframe conditions, not named-character identity references: <https://github.com/Lightricks/LTX-Video/blob/main/ltx_video/inference.py>.
- Official IC-LoRA is a separate pipeline that requires LoRA input and reference **video** conditioning, and can apply conditioning attention strength/masks. It is not present in the installed MLX package/model and is not evidence of native face-only identity conditioning: <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/src/ltx_pipelines/ic_lora.py>.

Official temporal multi-keyframe capability therefore does not imply a Front/Side/Back identity-reference set. No inspected official source established a native face identity encoder, face-only isolation, or prompt-entity identity binding for this installed model path.

## Current MLX Backend Capabilities

- T2V: implemented and previously rendered.
- One-image I2V at one temporal latent index: implemented and previously rendered.
- Arbitrary single `image_frame_idx`: present in Python/CLI, but it indexes the latent timeline, is not validated by the app, and has not been locally rendered at an end position.
- First + last / multiple temporal images: not exposed by the installed public function despite the lower-level list helper.
- Generic image reference, identity, face-only, multi-view subject set, expression-only, costume-only, regional reference, and multi-character binding: absent.
- Q4 + I2V + audio: implemented in the same function and already proven by the recorded baseline. Quantization is applied to transformer linear layers; the VAE image-conditioning route remains active.
- Extra encoders: Gemma provides text embeddings and the LTX VAE encodes the temporal image. No separate reference/vision/face encoder is loaded.

The installed package's upstream README advertises T2V and one-image I2V with synchronized audio, matching the inspected implementation: <https://github.com/james-see/mlx-video-with-audio>.

## App-exposed Capabilities

The app exposes T2V and one Source Image I2V on Generate, plus one uploaded I2V asset through API v1. It exposes the I2V denoise/preservation value. It does not expose `image_frame_idx`, so even the backend's internal arbitrary single-frame placement is unavailable and every app request targets latent index zero.

There is no field or UI for last frame, start+end images, multiple images, generic references, CharacterBible reference selection, face/identity mode, region mask, or reference-to-character binding. `GenerationSettingsResolver` does not create or discard such values; they do not exist in the request model.

## Local Experiments

**New generation count: 0.** Source inspection resolved the mechanism and absence questions conclusively. A face/full-body visual pair would only demonstrate visual influence and could not prove a dedicated identity mechanism. Avoiding it also prevents needless ~17–24 GiB generation memory use and temporary media.

Existing measured evidence is sufficient for supported baseline claims: `BENCHMARK_RESULTS.md` records the app's exact Q4 + Gemma 4-bit CLI running offline at 512×320/25 frames/15 steps. T2V audio ON/OFF and I2V audio ON/OFF all succeeded; I2V audio ON took 48 s and produced H.264 + AAC, while I2V audio OFF took 47 s and produced H.264.

## Capability Matrix

Status values describe the **current product capability**, with precise backend-only/upstream exceptions in the adjacent columns.

| Capability | Official LTX-2.3 | Current MLX Backend | App Exposed | Local Proven | Status |
|---|---|---|---|---|---|
| Text-to-Video | Yes | Yes | Yes | Yes, prior offline E2E | `SUPPORTED_AND_PROVEN` |
| Single-image I2V | Yes | Yes, one VAE latent image | Yes, one source path | Yes, audio ON/OFF | `SUPPORTED_AND_PROVEN` |
| First-frame conditioning | Yes | Yes, `image_frame_idx=0` | Yes, fixed default 0 | Yes, prior I2V E2E | `SUPPORTED_AND_PROVEN` |
| Last-frame conditioning | Yes, temporal keyframe | One arbitrary latent index is present | No | No | `SUPPORTED_IN_CODE_UNPROVEN` |
| First + last frame | Yes, keyframe pipeline | No public multi-image API | No | No | `UPSTREAM_ONLY` |
| Generic reference image | No native identity semantics shown; temporal/IC-LoRA routes differ | No | No | No | `NOT_SUPPORTED` |
| Multiple reference images | Multiple **temporal keyframes**, not identity set | No public multi-image API | No | No | `UPSTREAM_ONLY` (temporal only) |
| Character reference | No verified native named-character mechanism | No | No | No | `NOT_SUPPORTED` |
| Face identity reference | No verified native face-ID mechanism | No | No | No | `NOT_SUPPORTED` |
| Face-only conditioning | No verified native isolation | No | No | No | `NOT_SUPPORTED` |
| Front/Side/Back multi-view | No verified subject-reference-set mechanism | No | No | No | `NOT_SUPPORTED` |
| Expression reference | No dedicated mechanism verified | No | No | No | `NOT_SUPPORTED` |
| Costume reference | No dedicated mechanism verified | No | No | No | `NOT_SUPPORTED` |
| Regional/masked reference | Separate IC-LoRA route has attention mask; adapter required | No user regional/reference mask | No | No | `UPSTREAM_ONLY` |
| Reference strength control | Temporal/IC-LoRA controls exist, not generic identity weight | Only I2V temporal denoise mask | Only `imageStrength` for I2V | I2V default path proven | `NOT_SUPPORTED` for generic reference |
| Multiple-character identity binding | No verified image-to-named-subject binding | No | No | No | `NOT_SUPPORTED` |
| Audio + image conditioning | Yes | Yes, same A/V pipeline | Yes | Yes, prior I2V-A-ON E2E | `SUPPORTED_AND_PROVEN` |

Additional compatibility result: the selected Q4 model is `SUPPORTED_AND_PROVEN` for the existing single-image I2V path. That does not make Q4 identity-capable.

## Face Identity Findings

The answer to the primary Phase 3 question is **NO**. A 344×499 face crop is resized to the whole generation canvas, VAE-encoded, and injected as a temporal frame latent. There is no operation that extracts only facial identity or protects non-face degrees of freedom. Hair, clothes, pose, crop/framing, background, camera, and lighting are all part of the conditioned pixels.

Technically passing the Face PNG through Generate's Source Image picker is possible. Classification: `EXPERIMENTAL_WORKAROUND`, not a Face Reference capability. It must never be named Face Lock, Identity Lock, Same Person, or Face-only Conditioning.

## Multi-view Findings

The Front, Side, and Back PNGs cannot be sent together through the current public MLX function or Swift request. Even official multi-image keyframe APIs associate images with temporal positions, not with a common stable character identity. Phase 2 multi-view assets remain valuable local source material, but they are not current generation inputs.

## Expression / Costume Findings

There is no expression-only or costume-region reference input and no mask/entity association. Using either crop as the one I2V image would make the crop a whole temporal frame and may leak composition, colors, texture, or framing. Keep both asset types in the CharacterBible reference library; do not pass their paths into text prompts or generation requests.

## Risks

| Route or misuse | Identity accuracy | Leakage | Memory/dependency | Product risk |
|---|---|---|---|---|
| Face crop as one I2V starting image | Unspecified; no identity mechanism | Very high framing/hair/composition leakage | Uses current ~17–24 GiB generation path | Mislabeling visual resemblance as identity |
| Full-body Front as starting image | Unspecified | High pose/costume/background leakage | Current backend only | Shot composition becomes constrained by source |
| Port official temporal keyframes | Still not identity | Multiple frames become constrained | Backend engineering; Q4 compatibility must be re-proven | Could be mistaken for multi-view reference |
| Add IC-LoRA or identity backend later | Depends on adapter/training | Backend-specific | Separate adapter/weights and unmeasured memory | Requires an independent capability/security/license audit |

No memory estimate is claimed for absent adapters: no compatible checkpoint is installed and nothing was downloaded or loaded to measure it.

## Recommended Phase 4

1. **Recommended now — Reference Library UX only.** Keep Face/Front/Side/Back/Expression/Costume as project-owned, provenance-backed user references. Do not connect them automatically to LTX. Risk is lowest and current claims remain accurate.
2. **Optional narrow phase — “Starting Image” integration.** If users explicitly choose one asset, route it through the already-proven I2V path under the exact name **Starting Image**, with a warning that the complete frame/composition is conditioned. Never default to Face, never auto-select from CharacterBible, and never call it identity continuity.
3. **Separate backend research phase.** Evaluate either official temporal keyframe interpolation (for start/end control only) or a genuinely identity-capable adapter/backend. Require source proof, installed-model compatibility, Q4/audio/memory tests, and multi-character binding evidence before any Character Reference or Identity wording.

Accurate future UI terms today: **Reference Images** (library) and **Starting Image** (existing I2V). `Reference Image (Experimental)` is acceptable only for an explicitly experimental generic backend. **Identity Lock**, **Face Lock**, and **Same Character Guaranteed** are unsupported.

## Deferred / Unsupported

No Phase 3 change was made to FilmProject schema, CharacterReferenceAsset, CharacterBible, PromptCompiler, GenerationRequest, LTXBridge, Python package, or model cache. Face recognition, embeddings, face swap, IP-Adapter, IC-LoRA, new backend/model, multiple-reference UI, reference slider, and any automatic CharacterBible-to-generation connection remain deferred.

## Verification

- `swift build`: PASS
- `swift run LTXTests`: **543 passed / 0 failed**
- `xcodebuild -project LTXVideoGenerator/LTXVideoGenerator.xcodeproj -scheme LTXVideoGenerator -configuration Debug CODE_SIGNING_ALLOWED=NO build`: **BUILD SUCCEEDED**
- `git diff --check`: PASS
- Process cleanup: no `mlx_video` / `generate_av` process; Ollama `/api/ps` returned an empty model list
- Downloads/cloud/generation: none

## Evidence

Local source and state:

- `LTXVideoGenerator/Sources/Models/GenerationRequest.swift:173-209`
- `LTXVideoGenerator/Sources/Views/PromptInputView.swift:369-400,875-895`
- `LTXVideoGenerator/Sources/Services/GenerationService.swift:190-240`
- `LTXVideoGenerator/Sources/Services/VideoGenerationAdapter.swift:17-35`
- `LTXVideoGenerator/Sources/Services/LTXBridge.swift:122-169,198-230,391-418`
- `LTXVideoGenerator/Sources/Services/APIv1Handler.swift:122-159,183-211`
- `/Users/azimnb/ltx-venv/lib/python3.14/site-packages/mlx_video/generate_av.py:1151-1201,1560-1644,1722-1775,2072-2090`
- `/Users/azimnb/ltx-venv/lib/python3.14/site-packages/mlx_video/conditioning/latent.py:13-27,84-166`
- `docs/implementation/BENCHMARK_RESULTS.md`
- `/Users/azimnb/Library/Application Support/LTXVideoGenerator/Projects/07FA8292-0C89-4545-9D27-F1F64942C108.json`

Official primary sources:

- <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/README.md>
- <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/src/ltx_pipelines/keyframe_interpolation.py>
- <https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/src/ltx_pipelines/ic_lora.py>
- <https://github.com/Lightricks/LTX-Video/blob/main/ltx_video/inference.py>
- <https://github.com/james-see/mlx-video-with-audio>

Audit commands included `git status/log/diff`, app preference reads, `pip show`, direct source/AST/signature inspection, model-config/quantization/cache inspection, Phase 2 JSON/path/file inspection, and repository/package-wide capability searches. No cloud inference, model/package download, cache deletion, or production generation occurred.
