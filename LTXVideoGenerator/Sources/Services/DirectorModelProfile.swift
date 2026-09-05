import Foundation

/// Recognizes the family of a free-form local model identifier (an Ollama
/// tag such as "qwen3.6-claw-fast:latest" or "hf.co/.../Qwen3-8B-GGUF") for
/// display and observability purposes only.
///
/// This is deliberately NOT a routing mechanism: `LocalDirector` and
/// `StoryboardDirector` already treat every Ollama model identically (same
/// Structured JSON / Text Protocol negotiation, same `PromptCompiler`
/// boundary). No planning behavior branches on family. Matching is by
/// substring on the family name, never a specific installed tag, GGUF
/// filename, or private path — so any Qwen (or other) model a user pulls
/// locally, now or later, is recognized the same way without a code change.
enum DirectorModelFamily: String, Codable, Equatable, CaseIterable {
    case qwen
    case llama
    case gemma
    case mistral
    case deepseek
    case phi
    case other

    var displayName: String {
        switch self {
        case .qwen: return "Qwen"
        case .llama: return "Llama"
        case .gemma: return "Gemma"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .phi: return "Phi"
        case .other: return "Local"
        }
    }

    static func detect(modelIdentifier: String?) -> DirectorModelFamily {
        guard let raw = modelIdentifier?.lowercased(), !raw.isEmpty else { return .other }
        // "hf.co/Org/Repo-Name:tag" style identifiers carry the family name in
        // the repo segment, not the leading host/org, so match the whole
        // lowercased string rather than only the first path component.
        if raw.contains("qwen") { return .qwen }
        if raw.contains("llama") { return .llama }
        if raw.contains("gemma") { return .gemma }
        if raw.contains("mistral") || raw.contains("mixtral") { return .mistral }
        if raw.contains("deepseek") { return .deepseek }
        if raw.contains("phi") { return .phi }
        return .other
    }
}

/// A lightweight, display-only profile for the currently selected Director
/// model. Not a provider and not a networking layer — it wraps whatever
/// model identifier `DirectorEnvironmentService`/`OllamaDirectorProvider`
/// already resolved, purely for UI labeling and `FilmProject.directorProfile`
/// observability.
struct DirectorModelProfile: Equatable {
    var modelIdentifier: String
    var family: DirectorModelFamily

    /// e.g. "Qwen Director (qwen3.6-claw-fast:latest)". Unrecognized
    /// families fall back to the raw identifier so no installed model is
    /// ever hidden or mislabeled.
    var displayName: String {
        guard family != .other else { return modelIdentifier }
        return "\(family.displayName) Director (\(modelIdentifier))"
    }

    static func detect(modelIdentifier: String?) -> DirectorModelProfile? {
        guard let modelIdentifier, !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return DirectorModelProfile(modelIdentifier: modelIdentifier, family: .detect(modelIdentifier: modelIdentifier))
    }
}
