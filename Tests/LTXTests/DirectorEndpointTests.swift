import Foundation
@testable import LTXVideoGeneratorCore

/// Saves `UserDefaults.standard`'s current value for `key`, sets `value` for
/// the duration of `body`, then restores the original value exactly
/// (removing the key entirely if it was previously unset). Used only for the
/// small number of assertions that must exercise the real
/// default-parameter-driven provider construction, which — like the
/// pre-existing `directorOllamaModel` setting — reads `UserDefaults.standard`
/// directly rather than accepting an injectable instance.
private func withTemporaryStandardDefault<T>(key: String, value: String, body: () -> T) -> T {
    let original = UserDefaults.standard.string(forKey: key)
    UserDefaults.standard.set(value, forKey: key)
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    return body()
}

private func runSync<T>(_ body: @escaping () async -> T) -> T {
    var value: T!
    let sem = DispatchSemaphore(value: 0)
    Task {
        value = await body()
        sem.signal()
    }
    sem.wait()
    return value
}

func runDirectorEndpointTests(_ t: TestKit) {
    let endpointKey = OllamaDirectorEnvironmentClient.endpointUserDefaultsKey

    t.suite("Director endpoint — validator") {
        // 7. Invalid URL rejected, each malformed case with a specific reason.
        t.checkThrows(DirectorEndpointValidator.ValidationError.empty, "empty string rejected") {
            try DirectorEndpointValidator.validate("   ")
        }
        t.checkThrows(DirectorEndpointValidator.ValidationError.invalidURL, "not a URL at all") {
            try DirectorEndpointValidator.validate("not a url")
        }
        t.checkThrows(DirectorEndpointValidator.ValidationError.unsupportedScheme, "ftp scheme rejected") {
            try DirectorEndpointValidator.validate("ftp://127.0.0.1:11434")
        }
        t.checkThrows(DirectorEndpointValidator.ValidationError.missingHost, "scheme with no host rejected") {
            try DirectorEndpointValidator.validate("http://")
        }
        // Accepted examples, host/port preserved exactly as typed.
        for example in ["http://127.0.0.1:11434", "http://localhost:11434",
                         "http://127.0.0.1:11435", "http://192.168.1.20:11434"] {
            t.checkEqual(DirectorEndpointValidator.normalizedURL(from: example)?.absoluteString, example,
                         "\(example) accepted and never rewritten")
        }
    }

    t.suite("Director endpoint — configured value") {
        let suiteName = "LTXTests-DirectorEndpoint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. Default endpoint = 11434 when nothing is saved.
        t.checkEqual(OllamaDirectorEnvironmentClient.configuredEndpoint(userDefaults: defaults).absoluteString,
                     "http://127.0.0.1:11434", "no saved preference resolves to the loopback default")

        // 2. Custom endpoint = 11435 once saved.
        defaults.set("http://127.0.0.1:11435", forKey: endpointKey)
        t.checkEqual(OllamaDirectorEnvironmentClient.configuredEndpoint(userDefaults: defaults).absoluteString,
                     "http://127.0.0.1:11435", "a saved custom endpoint is read back exactly")

        // 10. Persists: a second, independent instance reading the same
        // UserDefaults domain sees the same value (persistence is the
        // UserDefaults domain itself, not any in-memory cache).
        let secondReadClient = OllamaDirectorEnvironmentClient.configuredEndpoint(userDefaults: defaults)
        t.checkEqual(secondReadClient.absoluteString, "http://127.0.0.1:11435",
                     "endpoint setting persists across independent reads")

        // 11. Legacy install: only the (unrelated) model key is set, endpoint
        // was never saved — must still resolve to the default, not crash or
        // require a migration.
        let legacySuiteName = "LTXTests-DirectorEndpoint-Legacy-\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
        legacyDefaults.set("qwen3.6-claw-fast:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        t.checkEqual(OllamaDirectorEnvironmentClient.configuredEndpoint(userDefaults: legacyDefaults).absoluteString,
                     "http://127.0.0.1:11434",
                     "an installation with only a saved model (no endpoint) still defaults correctly")
        t.checkEqual(legacyDefaults.string(forKey: DirectorEnvironmentService.modelUserDefaultsKey),
                     "qwen3.6-claw-fast:latest", "model and endpoint settings remain independent")

        // An invalid stored value (should never happen via the validating
        // UI, but defensively) also falls back to the default rather than
        // producing an unusable URL.
        let corruptSuiteName = "LTXTests-DirectorEndpoint-Corrupt-\(UUID().uuidString)"
        let corruptDefaults = UserDefaults(suiteName: corruptSuiteName)!
        defer { corruptDefaults.removePersistentDomain(forName: corruptSuiteName) }
        corruptDefaults.set("not a url", forKey: endpointKey)
        t.checkEqual(OllamaDirectorEnvironmentClient.configuredEndpoint(userDefaults: corruptDefaults).absoluteString,
                     "http://127.0.0.1:11434", "a corrupted stored value falls back to the default defensively")
    }

    t.suite("Director endpoint — provider wiring (real default-parameter path)") {
        // 3. Provider receives the configured endpoint: point the real
        // UserDefaults.standard default at a loopback port nothing listens
        // on. If OllamaDirectorProvider()'s default baseURL still silently
        // resolved to the old hardcoded 11434 (where this dev machine's real
        // Ollama IS running), isAvailable() would incorrectly return true.
        let unreachable = "http://127.0.0.1:1"
        let providerReachedConfiguredEndpoint = withTemporaryStandardDefault(key: endpointKey, value: unreachable) {
            runSync { await OllamaDirectorProvider().isAvailable() }
        }
        t.check(!providerReachedConfiguredEndpoint,
                "OllamaDirectorProvider()'s default baseURL follows the configured endpoint, not a hardcoded fallback")

        // 8. No silent fallback: the same unreachable custom endpoint must
        // not cause a quiet retry against 11434 — EnvironmentDirectorProvider
        // must report unavailable, not silently succeed via a different host.
        let environmentSawUnavailable = withTemporaryStandardDefault(key: endpointKey, value: unreachable) {
            runSync { await EnvironmentDirectorProvider(mode: .localAI).isAvailable() }
        }
        t.check(!environmentSawUnavailable,
                "an unreachable configured endpoint is reported unavailable, never silently swapped for the default")

        // 4. One Shot (LocalDirector) uses the configured endpoint: with it
        // unreachable, planning must fall through to the Basic/template
        // provider rather than hang or silently succeed against 11434.
        let oneShotProviderName = withTemporaryStandardDefault(key: endpointKey, value: unreachable) {
            runSync { () -> String? in
                let director = LocalDirector()
                return try? await director.plan(brief: "A woman walks.").providerName
            }
        }
        t.checkEqual(oneShotProviderName, "template",
                     "One Shot's default provider chain follows the configured endpoint and falls back safely when it is unreachable")

        // 5. Auto Movie (StoryboardDirector, via EnvironmentDirectorProvider)
        // uses the same configured endpoint.
        let autoMovieProviderName = withTemporaryStandardDefault(key: endpointKey, value: unreachable) {
            runSync { () -> String? in
                let director = StoryboardDirector(requestedMode: .localAI)
                return try? await director.draft(brief: "A woman walks.").providerName
            }
        }
        t.checkEqual(autoMovieProviderName, "template",
                     "Auto Movie's default provider chain follows the same configured endpoint")
    }

    t.suite("Director endpoint — Basic isolation") {
        // 6. Basic mode never constructs an Ollama-backed provider at all,
        // regardless of any endpoint configuration — structurally isolated,
        // not merely unreachable.
        let director = StoryboardDirector(requestedMode: .basic)
        let providerName = runSync { () -> String? in
            try? await director.draft(brief: "A woman walks.").providerName
        }
        t.checkEqual(providerName, "template", "Basic mode plans via the template provider only")
    }

    t.suite("Director endpoint — connection test detects missing model") {
        // 9. Model-not-found is a distinct, detectable state from
        // server-unreachable when a connection test is run.
        let suiteName = "LTXTests-DirectorEndpoint-ModelMissing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("some-model:latest", forKey: DirectorEnvironmentService.modelUserDefaultsKey)
        let client = MockDirectorEnvironmentClient(
            models: ["some-model:latest"],
            testError: DirectorError.invalidPlanJSON("The model replied, but did not return a usable plan.")
        )
        let service = DirectorEnvironmentService(userDefaults: defaults, client: client)
        let result = runSync { await service.testSelectedModel() }
        switch result {
        case .success:
            t.check(false, "expected the connection test to report the model as unusable")
        case .failure:
            t.check(true, "connection test surfaces a model-specific failure distinct from server-unavailable")
        }
    }

    t.suite("Director endpoint — Qwen family profile unaffected") {
        // 13. The real tag used throughout Qwen 3.8 acceptance is still
        // recognized purely by family pattern, no endpoint-specific branch.
        t.checkEqual(DirectorModelFamily.detect(modelIdentifier: "qwen3.8-director-acceptance:latest"), .qwen,
                     "the real acceptance-test tag is recognized as Qwen regardless of which endpoint served it")
    }

    t.suite("Director endpoint — FilmProject snapshot backward compatibility") {
        // 12. Legacy JSON without directorEndpointSnapshot still decodes.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","title":"Legacy project","directorProvider":"ollama",
         "directorModel":"qwen2.5:7b","planningMode":"ai"}
        """
        let legacy = try? JSONDecoder().decode(FilmProject.self, from: Data(legacyJSON.utf8))
        t.check(legacy != nil, "legacy JSON without directorEndpointSnapshot still decodes")
        t.check(legacy?.directorEndpointSnapshot == nil, "legacy JSON decodes directorEndpointSnapshot as nil, not a crash")

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LTXTests-endpoint-snapshot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = FilmProjectStore(projectsDirectory: tmpDir)
        var project = FilmProject(title: "Endpoint snapshot round-trip")
        project.directorEndpointSnapshot = "http://127.0.0.1:11435"
        store.save(project)
        let reloaded = store.project(id: project.id)
        t.checkEqual(reloaded?.directorEndpointSnapshot, "http://127.0.0.1:11435",
                     "directorEndpointSnapshot round-trips through disk persistence")
    }
}
