# DECISION_LOG

## D-001 (2026-08-08) Source acquisition by cloning upstream
No app source existed on this machine (docs only in ~/ltx23appdev; installed DMG 2.3.66). Cloned MIT-licensed `james-see/ltx-video-mac` @ a441dc2 into /Users/azimnb/ltx23appdev/ltx-video-mac. Upstream git history retained; `origin` remote points at upstream — NEVER push. Baseline = upstream main.

## D-002 (2026-08-08) Repo-local git identity
No global git identity configured. Set repo-local user.name=azimnb, user.email=azimnb@gmail.com (user's real address from session context, not fabricated; not set globally).

## D-003 (2026-08-08) SPM harness instead of xcodebuild
No Xcode.app installed; only CLT (Swift 6.3.3 + macOS 26.5 SDK). Added root `Package.swift` compiling app sources as a library + unit-test target so build/test discipline is possible. `.xcodeproj` untouched; Xcode users unaffected. Producing a signed .app remains a Remaining Human Action (install Xcode).

## D-004 (2026-08-08) Docs are spec-first, code-first on conflict
Deep Research claims re-verified against a441dc2 code; all key claims confirmed (see BASELINE.md table). No conflicts found requiring override.

## D-005 (2026-08-08) Baseline profile choice
Full-default generation (768x512x121f/30steps) takes very long on Q4+12b-4bit; baseline uses the app's own "Low Memory Preview" profile (512x320/25f/15steps/24fps, seed pinned) with audio ON/OFF as the reproducible reference, matching the master prompt's allowance to take one known-good generation plus a harness for the rest.

## D-006 (2026-08-08) useLocalMlxVideoRepo pref is stale
User pref useLocalMlxVideoRepo=1 but ~/projects/mlx-video-with-audio does not exist; bridge logic falls back to pip package (0.1.36). No action needed; noted for support.
