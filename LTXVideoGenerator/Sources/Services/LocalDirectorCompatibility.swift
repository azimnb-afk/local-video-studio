import Foundation

/// What a specific local model, at a specific endpoint, was last observed to
/// be capable of. Cached so Auto Movie does not re-probe on every run.
///
/// Stores identity and outcome only — never a prompt, a model reply, a token
/// or a filesystem path.
struct LocalDirectorCompatibilityProfile: Codable, Equatable {
    /// Bumped when the probes change meaning, so an old "ready" verdict is
    /// never trusted by newer code that asks a harder question.
    static let currentProbeVersion = 1

    var providerKind: String       // e.g. "ollama"
    var endpoint: String           // absolute endpoint string, e.g. "http://127.0.0.1:11434"
    var modelID: String
    var selectedProtocol: LocalDirectorProtocol?
    var probeVersion: Int
    var testedAt: Date
    /// Short, non-sensitive summary when no protocol worked.
    var failureSummary: String?

    var isCompatible: Bool { selectedProtocol != nil }

    /// A profile is only reusable for the exact provider+endpoint+model it was
    /// measured on, and only while the probes still mean the same thing.
    func matches(providerKind: String, endpoint: String, modelID: String) -> Bool {
        self.providerKind == providerKind
            && self.endpoint == endpoint
            && self.modelID == modelID
            && self.probeVersion == Self.currentProbeVersion
    }
}

/// Result of asking a local model what it can do.
enum LocalDirectorCapability: Equatable {
    case ready(LocalDirectorProtocol)
    /// Reachable and the model answered, but no protocol produced a usable plan.
    case incompatible(String)
    /// Could not reach the server or the model at all.
    case unavailable(String)
}

/// Sends one protocol's smallest representative planning request and reports
/// whether the reply survives that protocol's real parser.
protocol LocalDirectorProbing {
    func probe(_ planProtocol: LocalDirectorProtocol, model: String) async -> Result<Void, Error>
}

/// Negotiates and caches the protocol to use for a local model.
///
/// Deliberately model-name agnostic: nothing here inspects the model string
/// beyond using it as a cache key, so a user's own local model is judged by
/// what it produces rather than by what it is called.
final class LocalDirectorCompatibilityService {
    static let profileUserDefaultsKey = "localDirectorCompatibilityProfile"

    private let userDefaults: UserDefaults
    private let prober: LocalDirectorProbing
    private let providerKind: String
    private let endpoint: String

    init(userDefaults: UserDefaults = .standard,
         prober: LocalDirectorProbing? = nil,
         providerKind: String = "ollama",
         endpoint: String = OllamaDirectorEnvironmentClient.endpoint.absoluteString) {
        self.userDefaults = userDefaults
        self.prober = prober ?? OllamaLocalDirectorProber()
        self.providerKind = providerKind
        self.endpoint = endpoint
    }

    // MARK: Profile storage

    func loadProfile() -> LocalDirectorCompatibilityProfile? {
        guard let data = userDefaults.data(forKey: Self.profileUserDefaultsKey),
              let profile = try? JSONDecoder().decode(LocalDirectorCompatibilityProfile.self, from: data)
        else { return nil }
        return profile
    }

    /// The cached profile, but only if it was measured for exactly this model
    /// and endpoint under the current probe version.
    func validProfile(for model: String) -> LocalDirectorCompatibilityProfile? {
        guard let profile = loadProfile(),
              profile.matches(providerKind: providerKind, endpoint: endpoint, modelID: model)
        else { return nil }
        return profile
    }

    func save(_ profile: LocalDirectorCompatibilityProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        userDefaults.set(data, forKey: Self.profileUserDefaultsKey)
    }

    /// Records the protocol a production run actually succeeded with, so a
    /// runtime downgrade is remembered instead of being rediscovered every time.
    func recordSuccessfulProtocol(_ planProtocol: LocalDirectorProtocol, model: String) {
        save(LocalDirectorCompatibilityProfile(
            providerKind: providerKind, endpoint: endpoint, modelID: model,
            selectedProtocol: planProtocol,
            probeVersion: LocalDirectorCompatibilityProfile.currentProbeVersion,
            testedAt: Date(), failureSummary: nil))
    }

    // MARK: Negotiation

    /// Tries each protocol richest-first and caches the outcome.
    @discardableResult
    func negotiate(model: String) async -> LocalDirectorCapability {
        var failures: [String] = []
        for planProtocol in LocalDirectorProtocol.negotiationOrder {
            switch await prober.probe(planProtocol, model: model) {
            case .success:
                recordSuccessfulProtocol(planProtocol, model: model)
                return .ready(planProtocol)
            case .failure(let error):
                if case DirectorError.providerFailed = error {
                    // Transport-level: no protocol can succeed, and this is not
                    // evidence about the model's capability, so nothing is cached.
                    return .unavailable(error.localizedDescription)
                }
                failures.append("\(planProtocol.displayName): \(Self.shortReason(error))")
            }
        }
        let summary = failures.joined(separator: "; ")
        save(LocalDirectorCompatibilityProfile(
            providerKind: providerKind, endpoint: endpoint, modelID: model,
            selectedProtocol: nil,
            probeVersion: LocalDirectorCompatibilityProfile.currentProbeVersion,
            testedAt: Date(), failureSummary: summary))
        return .incompatible(summary)
    }

    /// The protocol to start a production run with: the cached one when it is
    /// still valid, otherwise the richest, letting the run's own downgrade
    /// path discover the truth without paying for a separate probe first.
    func startingProtocol(for model: String) -> LocalDirectorProtocol {
        validProfile(for: model)?.selectedProtocol ?? .structuredJSON
    }

    static func shortReason(_ error: Error) -> String {
        switch error {
        case DirectorError.invalidPlanJSON(let message): return message
        case DirectorError.planValidationFailed(let issues): return issues.joined(separator: ", ")
        default: return error.localizedDescription
        }
    }
}

/// Probes a real Ollama model by sending the protocol's own smallest planning
/// request through the production provider and running the production parser
/// over the reply. No schema checking is duplicated here.
struct OllamaLocalDirectorProber: LocalDirectorProbing {
    private let session: URLSession
    init(session: URLSession = OllamaDirectorProvider.defaultSession) { self.session = session }

    static let probeBrief = "A woman walks through a hallway."

    func probe(_ planProtocol: LocalDirectorProtocol, model: String) async -> Result<Void, Error> {
        let provider = OllamaDirectorProvider(model: model, session: session)
        // Reachability first, so an unreachable server is reported as
        // unavailable rather than as the model being incapable.
        guard await provider.isAvailable() else {
            await provider.terminate()
            return .failure(DirectorError.providerFailed("Local AI is not reachable"))
        }
        // Exactly the production planning attempt for this protocol, including
        // its bounded repair, then the production validator.
        let director = StoryboardDirector(providers: [provider], requestedMode: .localAI)
        do {
            let draft = try await director.draftUsingProtocol(
                planProtocol, provider: provider, brief: Self.probeBrief)
            await provider.terminate()
            let issues = StoryboardDirector.validate(draft)
            guard issues.isEmpty else {
                return .failure(DirectorError.planValidationFailed(issues))
            }
            return .success(())
        } catch {
            await provider.terminate()
            return .failure(error)
        }
    }
}
