# TEST_MATRIX

Updated: 2026-08-08. Runner: `swift run LTXTests` (331 checks, all passing).
Tests run through the repository's dependency-free SPM executable
(`Tests/LTXTests/TestKit.swift`); the full app is also compiled separately by Xcode.

## Unit (swift run LTXTests)
| Area | Checks | Status |
|---|---|---|
| Catalog / 64-px floor | 2 | PASS |
| ModelRegistry seeding (official verified, lab unverified) | 12 | PASS |
| Adult policy matrix (all 5 cases + unregistered + unverified) | 6 | PASS |
| Selectable models × feature flags | 4 | PASS |
| Adapter routing (official/derived) | 2 | PASS |
| Codable migration (legacy request/result JSON, round-trip) | 7 | PASS |
| Feature flags (defaults OFF, rollback) | 11 | PASS |
| Verification gate (11 checks, persistence, promotion) | 9 | PASS |
| Manifest validator (descriptor, snapshot, injection guard) | 8 | PASS |
| Model installer (disk preflight, license ack, revision pin) | 7 | PASS |
| Memory monitor / hardware profiler (live syscalls) | 6 | PASS |
| Hardware tiers | 5 | PASS |
| Auto Quality priors / ladder / advanced-refusal | 7 | PASS |
| User-facing Preset mapping + manual→Custom + preset reapplication | 10 | PASS |
| Historical success (promote/demote, per-hardware, persistence) | 4 | PASS |
| Auto history cap evidence + explicit fallback reasons | 4 | PASS |
| Failure classification + profile application | 8 | PASS |
| Exact Quick / Standard / High final requests + Custom precedence | 17 | PASS |
| LowRAM adapter gating | 4 | PASS |
| One Shot plan parsing/validation | 5 | PASS |
| Director lifecycle (terminate-before-render, repair, fallback) | 8 | PASS |
| Prompt compiler (Japanese native/romanized, frames 8n+1) | 14 | PASS |
| Director request pipeline | 4 | PASS |
| One Shot preset/source/target propagation + Custom frames | 6 | PASS |
| FilmProject persistence (schema guard, backup, delete) | 7 | PASS |
| Storyboard Project Settings persistence (preset/resolution/frames/audio) | 4 | PASS |
| Take planning 1–20 (seeds, linkage, jobs) + selection | 14 | PASS |
| Preview Take retention + High Quality append regeneration | 4 | PASS |
| Resume reconciliation (real MP4 = source of truth) | 5 | PASS |
| Continuity transitions + directive grammar | 8 | PASS |
| Continuity validation (silent changes, injuries, props) | 4 | PASS |
| Shot monotony rules | 4 | PASS |
| Storyboard pipeline (scripted + template fallback) | 16 | PASS |
| Hybrid state / short-shot split / compiled prompts / shared Preset | 6 | PASS |
| Storyboard/Hybrid target duration through final profile resolution | 6 | PASS |
| API token auth (constant-time, bearer) | 8 | PASS |
| API asset sandbox (traversal/absolute/non-UUID rejected) | 6 | PASS |
| API job validation (variations cap, i2v asset, task whitelist) | 10 | PASS |
| API adult policy (client cannot override app) | 4 | PASS |
| API request building | 6 | PASS |
| API preset/source/target and final Standard resolution | 5 | PASS |
| HTTP framing (Content-Length) | 4 | PASS |

## Integration (real binaries/files)
| Test | Status |
|---|---|
| Official T2V audio ON via exact app CLI (benchmark harness) | PASS (49 s, 23.66 GB peak) |
| Official T2V audio OFF | PASS (46 s, 17.23 GB) |
| Official I2V audio ON / OFF | PASS (48 s / 47 s) |
| Render-time network egress | PASS (HF_HUB_OFFLINE=1, generation fully offline) |
| MediaProbe on real MP4 | PASS (in LTXTests) |
| FFmpeg assembly stream-copy of 2 real MP4s | PASS (in LTXTests) |
| FFmpeg normalize+reencode plan (mixed audio) | PASS (plan-level) |
| Queue soak (3-take short validation) | see BENCHMARK_RESULTS |
| Queue soak (full 20-take) | HARNESS READY (scripts/queue_soak.sh 20, ≈17 min) |
| REST API end-to-end over socket (real .app) | **PASS** (2026-08-08: job POST → auto-quality compact C2 → real generation → completed + actual metadata 512×320/65f/2.708s; ffprobe re-verified) |
| App .app bundle build (xcodebuild) | **PASS** (Xcode 26.6: BUILD SUCCEEDED, Debug arm64, ad-hoc; app launches & runs) |
| Final GUI-first acceptance | **PASS** (running final .app: four production modes, Preset UX, One Shot, Storyboard Project Settings + Custom controls, Hybrid creation sheet) |
| Preset propagation GUI audit | **PASS** (old Quick=C3/Standard=C3 regression reproduced in Archive; High=H0; final One Shot preset is independent from Generate) |
| Fresh post-fix Quick/High real render | **BLOCKED BY ENVIRONMENT** (Debug app: MLX Environment Not Ready; sandbox Python: no Metal device). Mandatory resolved-request comparison passed. |

## Security (socket-level checks 2026-08-08 against the running .app)
| Test | Status |
|---|---|
| Loopback-only bind | **PASS** (lsof: listener bound to 127.0.0.1:8421 only) |
| Missing token → 401 / invalid token → 401 | **PASS** (curl) + unit |
| Path traversal / absolute path / invalid assetID | PASS (unit) |
| Oversized upload caps | ENFORCED (413 path; caps unit-visible) |
| Arbitrary repo injection | PASS (registry lookup + repo-id charset guard) |
| Adult model while adultMode OFF via API → 403 | **PASS** (curl) + unit at each layer |
| variations=21 → 400 | **PASS** (curl) + unit |
| No CORS headers in v1 responses | **PASS** (curl header inspection) |

## Regression
| Test | Status |
|---|---|
| Flags-OFF legacy path unchanged | PASS by construction (flag-gated branches) + code review |
| Post-change T2V baseline re-run (same seed/settings) | see BENCHMARK_RESULTS (REGRESSION row) |
