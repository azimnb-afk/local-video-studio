import Foundation

/// Local-first LLM provider used for director planning. Implementations MUST
/// release their memory in `terminate()` — the app never keeps a heavy LLM
/// resident while LTX renders (LLM plan → JSON saved → terminate → render).
protocol DirectorProvider {
    var name: String { get }
    func isAvailable() async -> Bool
    /// Single completion call. `system` frames the role; `prompt` is the task.
    func complete(system: String, prompt: String) async throws -> String
    /// Unload/terminate the underlying model so LTX gets the memory back.
    func terminate() async
}

enum DirectorError: Error, Equatable {
    case noProviderAvailable
    case invalidPlanJSON(String)
    case planValidationFailed([String])
    case providerFailed(String)
}

/// Ollama over loopback (http://127.0.0.1:11434). Local-only: never any
/// non-loopback host. `terminate()` unloads via keep_alive: 0.
final class OllamaDirectorProvider: DirectorProvider {
    let name = "ollama"
    static let modelUserDefaultsKey = "directorOllamaModel"

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private var model: String {
        UserDefaults.standard.string(forKey: Self.modelUserDefaultsKey) ?? "qwen2.5:7b"
    }

    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func complete(system: String, prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "format": "json",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectorError.providerFailed("Ollama HTTP error")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw DirectorError.providerFailed("Ollama response missing 'response' field")
        }
        return text
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
        _ = try? await URLSession.shared.data(for: request)
    }
}

/// Deterministic no-LLM fallback so the Director feature degrades gracefully
/// when no local LLM is installed: the brief itself becomes the action and
/// sensible defaults fill the rest. Always available, uses no memory.
final class TemplateDirectorProvider: DirectorProvider {
    let name = "template"

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
        let plan = OneShotPlan(
            camera: "static medium shot, eye level",
            action: brief,
            acting: nil,
            motion: "natural, continuous motion",
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
