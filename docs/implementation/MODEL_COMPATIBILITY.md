# MODEL_COMPATIBILITY

Backend: james-see/mlx-video-with-audio 0.1.36 (pip), MLX 0.32.0, Python 3.14.5.

| Model | Repo | Class | Backend status | Registry state |
|---|---|---|---|---|
| LTX-2 Unified | notapalindrome/ltx2-mlx-av | general | Working per upstream catalog | official, verified |
| LTX-2.3 Unified | notapalindrome/ltx23-mlx-av | general | Working per upstream catalog | official, verified |
| LTX-2.3 Distilled Q4 | notapalindrome/ltx23-mlx-av-q4 | general | Working — cached locally (20GB), user has generated with it via app 2.3.66 | official, verified (default) |
| 10Eros v1.2 MLX Q8 | MLXBits/ltx-2.3-10eros-v1.2-mlx-q8 | adultVerified(claimed) | UNKNOWN — packaged for dgrauet/ltx-2-mlx, direct compat with mlx-video-with-audio unverified | lab, verified=false |
| 10Eros v1.3 DMD MLX Q4 | MLXBits (v1.3 dmd q4) | adultVerified(claimed) | UNKNOWN | lab, verified=false |

Key: MLX artifact exists ≠ compatible with current backend. Verification gate in Phase 2 must pass (license, provenance, pinned revision, manifest, load, T2V/I2V/audio smoke, unload, memory bench, adult classification evidence) before verified=true.

10Eros weights are NOT downloaded on this machine (no user authorization yet; tens of GB). Lab infrastructure ships without weights; Runtime Verification Pending.
