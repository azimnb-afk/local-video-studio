import Foundation

/// Conservative validation for a user-supplied Local AI Director endpoint.
/// Never rewrites the host or port the user typed — only rejects clearly
/// malformed input and trims incidental whitespace/trailing slash so
/// `.appendingPathComponent("api/tags")` behaves consistently. No HTTPS
/// certificate handling: TLS trust is left entirely to URLSession's system
/// defaults.
enum DirectorEndpointValidator {
    enum ValidationError: Error, LocalizedError, Equatable {
        case empty
        case invalidURL
        case unsupportedScheme
        case missingHost

        var errorDescription: String? {
            switch self {
            case .empty: return "Enter an Ollama endpoint."
            case .invalidURL: return "This isn't a valid URL."
            case .unsupportedScheme: return "The endpoint must start with http:// or https://."
            case .missingHost: return "The endpoint needs a host, e.g. 127.0.0.1 or a hostname."
            }
        }
    }

    /// Nil for anything that fails `validate`. Used where a caller wants a
    /// silent fallback-to-default rather than a surfaced error (e.g. reading
    /// a persisted value that turned out to be unusable).
    static func normalizedURL(from raw: String) -> URL? {
        try? validate(raw)
    }

    /// Throws a specific, user-facing reason for invalid input. Callers that
    /// need to show the user why their endpoint was rejected — rather than
    /// silently falling back to a default — should use this directly.
    @discardableResult
    static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw ValidationError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValidationError.missingHost
        }
        guard let url = components.url else { throw ValidationError.invalidURL }
        // A trailing slash on the bare origin would double up when path
        // components are appended later ("http://host//api/tags").
        if url.path == "/", url.absoluteString.hasSuffix("/") {
            return URL(string: String(url.absoluteString.dropLast())) ?? url
        }
        return url
    }
}
