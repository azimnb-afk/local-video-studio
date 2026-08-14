# Model Licenses

**This file is about model weights, not source code.** This repository's own source code is MIT-licensed (see [LICENSE](LICENSE)). The models below are separate works, downloaded independently by each user from Hugging Face, and are governed by their own licenses — not by this repository's MIT license, and not necessarily by each other's licenses either.

None of the models below are bundled in this repository or in a built app — they are downloaded by the user, on demand, into `~/.cache/huggingface/`. This document records what could and could not be confirmed from official sources (the model's own Hugging Face page/model card, or the upstream vendor's own license page) as of this audit. Anything not confirmable there is marked **Needs external verification** rather than guessed — do not treat an unmarked cell as a license clearance.

## Official video models

The app's default/official catalog contains three video models, all served from `notapalindrome`'s Hugging Face account (an MLX conversion of Lightricks' LTX-2 family, not an account controlled by this project).

| Model | Repository | Declared license (as of audit) | Notes |
|:---|:---|:---|:---|
| LTX-2 Unified | [`notapalindrome/ltx2-mlx-av`](https://huggingface.co/notapalindrome/ltx2-mlx-av) | Hugging Face's license tag on this repo reads `mit`, but the repository's own model-card text states *"This model inherits the LTX-Video license from Lightricks."* These two statements conflict. **Needs external verification** — do not treat this as a plain MIT-licensed weight release; check the repository directly and treat the Lightricks LTX-2 Community License (below) as the operative terms unless you can confirm otherwise. |
| LTX-2.3 Unified (Beta) | [`notapalindrome/ltx23-mlx-av`](https://huggingface.co/notapalindrome/ltx23-mlx-av) | No model card and no license tag published on the repository at time of audit. **Needs external verification.** |
| LTX-2.3 Distilled Q4 (Beta, app default) | [`notapalindrome/ltx23-mlx-av-q4`](https://huggingface.co/notapalindrome/ltx23-mlx-av-q4) | No model card and no license tag published on the repository at time of audit. **Needs external verification.** |

### Underlying upstream license (Lightricks)

The original LTX-2 weights and code are published by Lightricks under the **LTX-2 Community License Agreement** ([Lightricks/LTX-2, `LICENSE`](https://huggingface.co/Lightricks/LTX-2/blob/main/LICENSE)). Based on that license text: it permits free use for non-commercial purposes and for commercial entities under a revenue threshold, requires a separate paid commercial license above that threshold, and prohibits a specific list of use cases (including, among others, harm to minors, deepfakes without disclosure, medical advice, military applications, and malware generation) regardless of revenue. It governs the trained model weights and inference code, not just source code. **This project has not independently confirmed whether the three `notapalindrome` repositories above carry these same terms forward, weaker terms, or different terms — that is exactly the "Needs external verification" gap noted above.** If you plan to use this app's output or these weights beyond personal experimentation, read the Lightricks license yourself and confirm which terms actually apply to the specific repository you are pulling from.

## Text encoders (used for prompt embeddings during generation)

| Preset | Repository | Declared license | Notes |
|:---|:---|:---|:---|
| Gemma 12B bf16 (default) | [`mlx-community/gemma-3-12b-it-bf16`](https://huggingface.co/mlx-community/gemma-3-12b-it-bf16) | `gemma` (Google's [Gemma Terms of Use](https://ai.google.dev/gemma/terms)) | MLX conversion of Google's `google/gemma-3-12b-it`; the Gemma Terms of Use govern redistribution and use restrictions, not this repository's MIT license |
| Gemma 4B bf16 | `mlx-community/gemma-3-4b-it-bf16` | `gemma` (Gemma Terms of Use, same as above) | Not independently re-confirmed per-repository in this pass; assumed consistent with the same MLX Community conversion pattern — **spot-check before relying on this if it matters to you** |
| Gemma 12B 4-bit | `mlx-community/gemma-3-12b-it-4bit` | `gemma` (Gemma Terms of Use, same as above) | Same caveat as above |
| Custom | user-specified | Whatever the user's chosen repository declares | Not this project's responsibility to track — the user is choosing an arbitrary repository |

The Gemma Terms of Use permit commercial use, but require passing the same terms (and Google's Prohibited Use Policy) on to anyone you distribute the model or its outputs to, and require notice if you've modified the model. They are not a permissive license like MIT or Apache — read them if you plan to redistribute anything built on Gemma.

## User-Configured Custom Models (ltx-2-mlx compatible)

The application supports user-configured arbitrary fine-tuned models compatible with the `ltx-2-mlx` backend. These models are configured locally in Preferences:

- The application source code does not distribute or pre-bundle any third-party fine-tuned weights.
- When configuring a custom repository or local directory path, it is the user's responsibility to review and comply with the specific license terms and acceptable use policies governing those weights.
- Custom models execute via the isolated `ltx-2-mlx` backend on local hardware.

## What this document is not

This is not legal advice, and it is not a substitute for reading the actual license text of any model you use beyond casual personal experimentation. Where this document says "Needs external verification," that means exactly that — nobody on this project has resolved the question, and you should not assume a favorable answer.
