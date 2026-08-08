# IMPLEMENTATION_PLAN

GUI-first macOS app; OpenClaw optional via localhost REST API. Local-only video generation, no cloud fallback. Protect the Official fast path (SwiftUI → GenerationService → LTXBridge → python → mlx_video.generate_av → MP4).

## Phases
0. Audit/Baseline — DONE (BASELINE.md) + benchmark harness `scripts/benchmark_baseline.sh`
1. Official Model Registry: ModelDescriptor/ModelRegistry/ContentClassification/PolicyMetadata; VideoGenerationAdapter protocol; OfficialMLXAudioAdapter delegating to existing LTXBridge; FeatureFlags; backward-compatible request/result metadata (modelRevision, quantization, qualityMode, adultMode, filmProjectID, shotID, takeID; result: effective/actual resolution, actualFPS, actualDuration, peakMemory).
2. 10Eros Compatibility Lab: descriptor entries verified=false, manifest validator, verification gate checklist, installer foundation (no auto-download), AdultContentPolicy enforced at Service+API+selection.
3. Auto Quality: HardwareProfiler, MemoryMonitor, QualityProfile ladder (Auto/High/Compact/Advanced), AutoQualityEngine with fallback ladder (memoryOpt → frames → resolution → optional features → Compact → Unsupported, max 3 attempts), HistoricalSuccessStore, LowRAMMLXAdapter boundary (Runtime Verification Pending on 16GB).
4. One Shot Director: LocalDirector provider protocol (local-first), OneShotPlan JSON (Codable), PromptCompiler (chronological flowing description; I2V image = source of truth; Japanese native + optional romanization), DialogueNormalizer, LLM terminate-before-render lifecycle.
5. FilmProject/Shot/Take: data models incl. full Take metadata, 1–20 sequential takes (GenerationConcurrency=1), versioned atomic persistence in Application Support, resume of in-flight jobs at startup.
6. Storyboard/Continuity/Assembly: StoryBible/CharacterBible, deterministic ContinuityState + validator, shot monotony rules, MediaProbe (ffprobe = source of truth), FinalAssemblyService (concat stream-copy when compatible, else normalize+reencode; hard cuts MVP).
7. Local REST API v1: /v1/assets, /v1/jobs, /v1/models, /v1/system, /v1/history; loopback bind, installation token, no wildcard CORS, size limits, assetID indirection, max 20 variations; extras/openclaw examples.
8. Advanced (capability-driven only): not enabled unless backend-verified.

## Testing
Unit (registry/policy/autoquality/continuity/migration/API validation), integration (T2V smoke via harness), security (loopback/token/traversal), regression vs Phase 0 baseline, queue soak plan.

## Checkpoints
Commit at each phase completion on branch `director-extensions`. Never push.
