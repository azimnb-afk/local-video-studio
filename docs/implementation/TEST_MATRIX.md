# TEST_MATRIX

Status legend: PASS / FAIL / PENDING / N-A (not runnable in this environment)

## Unit (swift test via SPM harness)
| Area | Test | Status |
|---|---|---|
| ModelRegistry | descriptor lookup, official seeding | PENDING |
| Policy | adult mode matrix (5 cases) | PENDING |
| Manifest validator | valid/incomplete/unpinned | PENDING |
| AutoQuality | profile selection + fallback order + max 3 attempts | PENDING |
| HistoricalSuccessStore | save/promote/demote | PENDING |
| Continuity | state transition + contradiction detection | PENDING |
| Codable migration | legacy GenerationRequest/Result JSON decodes | PENDING |
| API validation | assetID, size limit, token, variations cap | PENDING |

## Integration
| Test | Status |
|---|---|
| Official T2V smoke (audio ON) via benchmark harness | PENDING |
| Official T2V smoke (audio OFF) | PENDING |
| I2V smoke | PENDING |
| MediaProbe on real MP4 | PENDING |
| FFmpeg assembly (concat) | PENDING |
| Persistence + resume | PENDING |
| REST API curl smoke | PENDING (needs running app; harness-level handler tests instead) |

## Security
| Test | Status |
|---|---|
| non-loopback rejected | PENDING |
| missing/invalid token | PENDING |
| path traversal on assets | PENDING |
| oversized upload | PENDING |
| adult model ID while adultMode=false rejected | PENDING |

## Regression
| Test | Status |
|---|---|
| Baseline vs post-change generation (same seed/settings) | PENDING |

## Queue soak
| Test | Status |
|---|---|
| 20-take sequential memory stability | PLANNED (design + harness; full run is hours) |
