import Foundation

/// Local-first LLM provider used for director planning. Implementations MUST
/// release their memory in `terminate()` — the app never keeps a heavy LLM
/// resident while LTX renders (LLM plan → JSON saved → terminate → render).
protocol DirectorProvider {
    var name: String { get }
    /// Model identifier when the provider has one (nil for deterministic providers).
    var modelIdentifier: String? { get }
    /// True only for Basic/Template providers used after AI planning fails.
    var isFallbackProvider: Bool { get }
    /// User-facing reason when this provider cannot be used. Kept separate
    /// from transport diagnostics so Auto can explain a Basic fallback.
    var availabilityFailureReason: String? { get }
    func isAvailable() async -> Bool
    /// Single completion call. `system` frames the role; `prompt` is the task.
    func complete(system: String, prompt: String) async throws -> String
    /// Completion where the caller states whether it wants a JSON object.
    /// Backends that can constrain decoding must only do so when `expectsJSON`
    /// is true: constraining a plain-text protocol to JSON makes it impossible
    /// for the model to answer in that protocol at all.
    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String
    /// Unload/terminate the underlying model so LTX gets the memory back.
    func terminate() async
}

extension DirectorProvider {
    /// Providers that do not distinguish response formats answer both the same.
    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        try await complete(system: system, prompt: prompt)
    }

    var modelIdentifier: String? { nil }
    var isFallbackProvider: Bool { false }
    var availabilityFailureReason: String? { nil }
}

enum DirectorMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case localAI
    case basic

    static let userDefaultsKey = "storyboardDirectorMode"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .localAI: return "Local AI"
        case .basic: return "Basic"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Recommended"
        case .localAI: return "Use an installed local model"
        case .basic: return "No additional setup required"
        }
    }

    static func selected(userDefaults: UserDefaults = .standard) -> DirectorMode {
        DirectorMode(rawValue: userDefaults.string(forKey: userDefaultsKey) ?? "") ?? .auto
    }
}

enum DirectorAvailability: Equatable {
    case checking
    case localAIReady(model: String)
    case localAIModelMissing
    case localAIServerUnavailable
    case basicOnly
}

struct DirectorSetupSnapshot: Equatable {
    var requestedMode: DirectorMode
    var effectiveMode: DirectorMode
    var availability: DirectorAvailability
    var installedModels: [String]
    var configuredModel: String?
    var effectiveModel: String?
    var fallbackReason: String?

    static func checking(mode: DirectorMode) -> DirectorSetupSnapshot {
        DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .basic, availability: .checking,
                              installedModels: [], configuredModel: nil, effectiveModel: nil,
                              fallbackReason: nil)
    }

    var userStatus: String {
        switch availability {
        case .checking: return "Checking Director availability…"
        case .localAIReady: return "Local AI Director is ready."
        case .localAIModelMissing: return "Local AI model is not available. Basic Director will be used."
        case .localAIServerUnavailable: return "Local AI is unavailable. Basic Director will be used."
        case .basicOnly: return "Basic Director is ready. No additional setup required."
        }
    }

    var technicalStatus: String {
        switch availability {
        case .checking: return "checking"
        case .localAIReady(let model): return "ready: \(model)"
        case .localAIModelMissing: return "configured model missing"
        case .localAIServerUnavailable: return "local server unavailable"
        case .basicOnly: return "local AI bypassed by user selection"
        }
    }
}

protocol DirectorEnvironmentClient {
    func installedModels() async throws -> [String]
    func testModel(_ model: String) async throws
}

/// Loopback-only Ollama environment client. It never starts Ollama, invokes a
/// shell, downloads a model, or contacts a cloud service.
final class OllamaDirectorEnvironmentClient: DirectorEnvironmentClient {
    static let endpoint = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func installedModels() async throws -> [String] {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectorError.providerFailed("Local AI model list is unavailable")
        }
        return try Self.modelNames(from: data)
    }

    static func modelNames(from data: Data) throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable {
                var name: String?
                var model: String?
                var capabilities: [String]?
            }
            var models: [Model]
        }
        let names: [String] = try JSONDecoder().decode(Tags.self, from: data).models.compactMap { entry -> String? in
            if let capabilities = entry.capabilities, !capabilities.isEmpty,
               !capabilities.contains("completion") {
                return nil
            }
            let value = entry.name ?? entry.model
            return value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Probe shaped like the real planning task rather than a trivial JSON
    /// echo. Reaching the server and returning *some* JSON does not predict
    /// whether a model can actually plan: a model that happily answers
    /// `{"ready":true}` can still return `{}` or free prose for the real
    /// storyboard request, which then fails schema validation and silently
    /// drops Auto Movie to the Basic Director. Asking for the smallest
    /// plan-shaped object — an object containing a non-empty `shots` array of
    /// objects — is what distinguishes the two, so "Ready" means the model can
    /// actually produce a plan.
    static let readinessProbeSystemPrompt = """
    You plan short films. Respond with ONLY a JSON object of the form
    {"logline":"one sentence","shots":[{"index":0,"summary":"what happens"}]}.
    Include at least one shot.
    """
    static let readinessProbePrompt = "BRIEF: A woman walks through a hallway."

    func testModel(_ model: String) async throws {
        let provider = OllamaDirectorProvider(model: model, session: session)
        let response: String
        do {
            response = try await provider.complete(
                system: Self.readinessProbeSystemPrompt,
                prompt: Self.readinessProbePrompt
            )
            await provider.terminate()
        } catch {
            await provider.terminate()
            throw error
        }
        guard Self.probeResponseLooksLikeAPlan(response) else {
            throw DirectorError.invalidPlanJSON(
                "The model replied, but did not return a usable plan.")
        }
    }

    /// True when the probe response is a JSON object carrying a non-empty
    /// `shots` array of objects. Deliberately structural only: the probe is a
    /// capability check, not a content check.
    static func probeResponseLooksLikeAPlan(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shots = object["shots"] as? [Any],
              !shots.isEmpty,
              shots.first is [String: Any] else {
            return false
        }
        return true
    }
}

/// One source of truth for requested mode, installed models, preferred model,
/// and the effective Director selected for the next planning attempt.
final class DirectorEnvironmentService {
    static let modelUserDefaultsKey = OllamaDirectorProvider.modelUserDefaultsKey

    private let userDefaults: UserDefaults
    private let client: DirectorEnvironmentClient

    init(userDefaults: UserDefaults = .standard,
         client: DirectorEnvironmentClient = OllamaDirectorEnvironmentClient()) {
        self.userDefaults = userDefaults
        self.client = client
    }

    func refresh(mode requestedMode: DirectorMode? = nil) async -> DirectorSetupSnapshot {
        let mode = requestedMode ?? DirectorMode.selected(userDefaults: userDefaults)
        let configured = userDefaults.string(forKey: Self.modelUserDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = configured.flatMap { $0.isEmpty ? nil : $0 }

        guard mode != .basic else {
            return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .basic,
                                          availability: .basicOnly, installedModels: [],
                                          configuredModel: preferred, effectiveModel: nil,
                                          fallbackReason: nil)
        }

        let installed: [String]
        do {
            installed = try await client.installedModels()
        } catch {
            return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .basic,
                                          availability: .localAIServerUnavailable,
                                          installedModels: [], configuredModel: preferred,
                                          effectiveModel: nil,
                                          fallbackReason: "localAIServerUnavailable")
        }

        let candidates = Self.compatibleCandidates(from: installed)
        if let preferred, installed.contains(preferred) {
            return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .localAI,
                                          availability: .localAIReady(model: preferred),
                                          installedModels: installed, configuredModel: preferred,
                                          effectiveModel: preferred, fallbackReason: nil)
        }
        if preferred != nil, mode == .localAI {
            return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .basic,
                                          availability: .localAIModelMissing,
                                          installedModels: installed, configuredModel: preferred,
                                          effectiveModel: nil,
                                          fallbackReason: "localAIModelMissing")
        }
        if let candidate = candidates.first {
            return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .localAI,
                                          availability: .localAIReady(model: candidate),
                                          installedModels: installed, configuredModel: preferred,
                                          effectiveModel: candidate,
                                          fallbackReason: preferred == nil ? nil : "configuredModelMissingUsingInstalledAlternative")
        }
        return DirectorSetupSnapshot(requestedMode: mode, effectiveMode: .basic,
                                      availability: .localAIModelMissing,
                                      installedModels: installed, configuredModel: preferred,
                                      effectiveModel: nil,
                                      fallbackReason: "localAIModelMissing")
    }

    func testSelectedModel() async -> Result<String, Error> {
        let snapshot = await refresh()
        guard let model = snapshot.effectiveModel else {
            return .failure(DirectorError.noProviderAvailable)
        }
        do {
            try await client.testModel(model)
            return .success(model)
        } catch {
            return .failure(error)
        }
    }

    /// Negotiates which Director protocol this model can actually drive and
    /// caches the verdict, so Auto Movie can start with a protocol already
    /// known to work instead of discovering it mid-run.
    func testCompatibility(
        compatibility: LocalDirectorCompatibilityService = LocalDirectorCompatibilityService()
    ) async -> (model: String?, capability: LocalDirectorCapability) {
        let snapshot = await refresh()
        guard let model = snapshot.effectiveModel else {
            return (nil, .unavailable("No Local AI model is configured."))
        }
        return (model, await compatibility.negotiate(model: model))
    }

    static func compatibleCandidates(from models: [String]) -> [String] {
        models.filter { model in
            let value = model.lowercased()
            return !value.contains("embed") && !value.contains("embedding") && !value.contains("rerank")
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func friendlyFallbackReason(_ reason: String?) -> String {
        switch reason {
        case "localAIServerUnavailable": return "Local AI was unavailable."
        case "localAIModelMissing": return "The selected Local AI model was unavailable."
        case "configuredModelMissingUsingInstalledAlternative": return "The preferred model was unavailable; another installed model was used."
        case nil: return "Basic Director was selected."
        // These are reached with the server up and the model loaded: the model
        // answered but its reply was not a usable plan. Say so, rather than
        // implying a connection problem the user would go looking for.
        case "schemaValidationFailed", "codableDecodeFailed":
            return "Local AI replied, but the plan was missing required details. Try a different Local AI model in Settings."
        case "jsonSyntaxInvalid", "jsonExtractionFailed":
            return "Local AI replied, but not in the required format. Try a different Local AI model in Settings."
        default: return "Local AI could not complete the plan."
        }
    }
}

enum DirectorError: Error, Equatable {
    case noProviderAvailable
    case noResponse(String)
    case invalidPlanJSON(String)
    case planValidationFailed([String])
    case providerFailed(String)
    case basicNormalizationFailed(String)
    case unsupportedRenderLanguage(String)
}

extension DirectorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noProviderAvailable:
            return "No local director provider is available"
        case .noResponse(let message), .invalidPlanJSON(let message), .providerFailed(let message):
            return message
        case .planValidationFailed(let issues):
            return "Director plan validation failed: \(issues.joined(separator: ", "))"
        case .basicNormalizationFailed(let message):
            return message
        case .unsupportedRenderLanguage(let message):
            return message
        }
    }
}

/// Ollama over loopback (http://127.0.0.1:11434). Local-only: never any
/// non-loopback host. `terminate()` unloads via keep_alive: 0.
final class OllamaDirectorProvider: DirectorProvider {
    let name = "ollama"
    static let modelUserDefaultsKey = "directorOllamaModel"

    private let baseURL: URL
    private let session: URLSession
    private let explicitModel: String?
    private var model: String {
        explicitModel ?? UserDefaults.standard.string(forKey: Self.modelUserDefaultsKey) ?? "qwen2.5:7b"
    }
    var modelIdentifier: String? { model }

    init(model: String? = nil,
         baseURL: URL = OllamaDirectorEnvironmentClient.endpoint,
         session: URLSession = .shared) {
        self.explicitModel = model
        self.baseURL = baseURL
        self.session = session
    }

    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func complete(system: String, prompt: String) async throws -> String {
        try await complete(system: system, prompt: prompt, expectsJSON: true)
    }

    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            // Thinking-capable models may otherwise put the requested JSON in
            // Ollama's `thinking` field and leave `response` empty.
            "think": false,
            // A multi-shot plan with camera, dialogue and continuity fields can
            // exceed Ollama's default response budget and come back as
            // truncated JSON, which then burns the repair attempts and drops the
            // run to the Basic Director. Observed at the default limit with a
            // four-shot plan.
            "options": ["num_predict": 4096],
        ]
        if expectsJSON {
            // Ollama's grammar constraint. Correct for the Structured JSON
            // protocol, and actively harmful for a plain-text protocol.
            body["format"] = "json"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectorError.providerFailed("Ollama HTTP error")
        }
        return try Self.completionText(from: data)
    }

    /// Extracts structured content from Ollama's outer response envelope.
    /// `response` is canonical. `thinking` is accepted only as compatibility
    /// for models/servers that ignore `think: false` and return an empty
    /// response while placing the requested JSON in the thinking channel.
    static func completionText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectorError.providerFailed("Ollama response envelope was not a JSON object")
        }
        let response = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !response.isEmpty { return response }
        let thinking = (json["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !thinking.isEmpty { return thinking }
        throw DirectorError.noResponse("Ollama response contained no completion text")
    }

    func terminate() async {
        // keep_alive: 0 asks Ollama to unload the model immediately,
        // recovering unified memory before LTX rendering starts.
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "keep_alive": 0]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: request)
    }
}

/// Mode-aware Local AI provider used by Storyboard. Auto selects an installed
/// model through DirectorEnvironmentService; Basic bypasses local AI entirely.
final class EnvironmentDirectorProvider: DirectorProvider {
    let name = "ollama"
    private let mode: DirectorMode
    private let environment: DirectorEnvironmentService
    private let session: URLSession
    private var provider: OllamaDirectorProvider?
    private var selectedModel: String?
    private(set) var availabilityFailureReason: String?

    var modelIdentifier: String? { selectedModel }

    init(mode: DirectorMode, environment: DirectorEnvironmentService = DirectorEnvironmentService(), session: URLSession = .shared) {
        self.mode = mode
        self.environment = environment
        self.session = session
    }

    func isAvailable() async -> Bool {
        let snapshot = await environment.refresh(mode: mode)
        availabilityFailureReason = snapshot.fallbackReason
        guard snapshot.effectiveMode == .localAI, let model = snapshot.effectiveModel else {
            return false
        }
        selectedModel = model
        provider = OllamaDirectorProvider(model: model, session: session)
        return true
    }

    func complete(system: String, prompt: String) async throws -> String {
        guard let provider else { throw DirectorError.noProviderAvailable }
        return try await provider.complete(system: system, prompt: prompt)
    }

    func complete(system: String, prompt: String, expectsJSON: Bool) async throws -> String {
        guard let provider else { throw DirectorError.noProviderAvailable }
        return try await provider.complete(system: system, prompt: prompt, expectsJSON: expectsJSON)
    }

    func terminate() async {
        await provider?.terminate()
        provider = nil
    }
}

/// Local fallback director provider: provides template-based shot planning
/// when no local LLM is installed. Uses RenderTextNormalizer for renderer-safe English
/// descriptions. Always available, uses minimal memory.
final class TemplateDirectorProvider: DirectorProvider {
    let name = "template"
    let isFallbackProvider = true
    let normalizer: RenderTextNormalizer

    init(normalizer: RenderTextNormalizer = BasicRenderLanguageNormalizer()) {
        self.normalizer = normalizer
    }

    func isAvailable() async -> Bool { true }

    func complete(system: String, prompt: String) async throws -> String {
        // Extract the brief from the task prompt (after the "BRIEF:" marker
        // LocalDirector uses); fall back to the whole prompt.
        let brief: String
        if let range = prompt.range(of: "BRIEF:") {
            brief = String(prompt[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            brief = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Normalize user brief into renderer-safe English action
        let normalizedAction = try await normalizer.normalizeDescriptionToEnglish(brief)

        // Strict renderer-language validation gate
        try RenderLanguageValidator.validateRendererAction(normalizedAction)

        let plan = OneShotPlan(
            camera: "static medium shot, eye level",
            action: normalizedAction,
            acting: nil,
            motion: "natural and continuous",
            lighting: "soft natural lighting",
            dialogue: [],
            audioCues: [],
            durationIntentSeconds: 5
        )
        let data = try JSONEncoder().encode(plan)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func terminate() async {}
}
