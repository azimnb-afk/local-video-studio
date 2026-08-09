# First Run / Dependency Onboarding (Phase A1)

## Overview
The LTX Video Generator requires several external dependencies to function correctly. Instead of failing silently or using confusing legacy alerts, the application now utilizes a centralized `DependencyHealthManager` and `SetupWizardView` to guide new users through dependency resolution. 

This flow is explicitly designed to:
- Avoid modifying the user's system without consent.
- Never use `sudo pip` or run silent Homebrew installations.
- Only block actual Generation actions; UI exploration remains accessible.

## Architecture

### 1. DependencyHealthManager
A `@MainActor` singleton (`DependencyHealthManager.shared`) that aggregates the status of all dependencies. It holds the current `.isGenerationReady` state and triggers `.showSetupWizard` when required.

### 2. SetupStatus & Checking Protocols
Dependencies are split into independent checkers conforming to `SetupChecking`:
- `PythonChecking`
- `FFmpegChecking`
- `ModelChecking`
- `OptionalServiceChecking`

Each checker returns a `SetupStatus`:
- `.ready`
- `.missing(message)`
- `.invalid(message)`

### 3. SetupWizardView
Presented as a full-screen sheet over the app content when generation is requested but dependencies are lacking. It presents actionable UI to the user based on which dependencies report as `.missing` or `.invalid`.

## Gating Generation
Generation is guarded across all core views (`PromptInputView`, `ContentView` (Director), `StoryboardView`):
```swift
if !DependencyHealthManager.shared.isGenerationReady {
    DependencyHealthManager.shared.showSetupWizard = true
    return
}
```

## Testing
Tested via `Tests/LTXTests/Dependencies/DependencyHealthTests.swift`. Dependency checkers are mocked with `FakeCheckers` to ensure test independence from the local Mac environment. tests use `RunLoop.main.run` to wait for actor execution synchronously to avoid test suite deadlocks.
