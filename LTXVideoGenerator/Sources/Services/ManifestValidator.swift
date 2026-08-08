import Foundation

/// Static validation of model descriptors and local snapshots.
/// Never touches the network; arbitrary repos are validated before anything
/// is ever passed to the Python backend.
enum ManifestValidator {

    struct Issue: Equatable, CustomStringConvertible {
        enum Severity: String { case error, warning }
        var severity: Severity
        var message: String
        var description: String { "[\(severity.rawValue)] \(message)" }
    }

    /// Files a unified LTX MLX snapshot must contain to be loadable by
    /// mlx-video-with-audio (top-level layout observed in official repos).
    static let requiredSnapshotEntries = [
        "config.json",
    ]
    /// At least one weight shard must exist with one of these extensions.
    static let weightExtensions = ["safetensors", "npz", "gguf"]

    /// Descriptor-level checks (no filesystem access).
    static func validateDescriptor(_ model: ModelDescriptor) -> [Issue] {
        var issues: [Issue] = []
        if model.repository.trimmingCharacters(in: .whitespaces).isEmpty && model.localPath == nil {
            issues.append(Issue(severity: .error, message: "No repository or local path."))
        }
        if !model.isOfficial {
            if model.revision == nil && model.localPath == nil {
                issues.append(Issue(severity: .error, message: "Derived model revision is not pinned."))
            }
            if model.license.name.lowercased().contains("unknown") {
                issues.append(Issue(severity: .error, message: "License unknown — Stop Condition for this model."))
            }
            if model.policy.contentClassification == .unknown {
                issues.append(Issue(severity: .error, message: "Content classification unknown."))
            }
            if model.policy.contentClassification == .adultVerified,
               (model.policy.classificationEvidence ?? "").isEmpty {
                issues.append(Issue(severity: .error, message: "Adult classification lacks evidence."))
            }
        }
        if model.runtime.backend != "mlx-video-with-audio" {
            issues.append(Issue(severity: .warning, message: "Backend '\(model.runtime.backend)' is not the official backend; requires its own adapter."))
        }
        // Repo id shape guard: refuse shell-metacharacter injection into the backend.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        if model.repository.rangeOfCharacter(from: allowed.inverted) != nil {
            issues.append(Issue(severity: .error, message: "Repository id contains disallowed characters."))
        }
        return issues
    }

    /// Snapshot-level checks against an installed local directory.
    static func validateSnapshot(at path: String) -> [Issue] {
        var issues: [Issue] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return [Issue(severity: .error, message: "Snapshot directory does not exist: \(path)")]
        }
        guard let contents = try? fm.subpathsOfDirectory(atPath: path) else {
            return [Issue(severity: .error, message: "Snapshot directory unreadable: \(path)")]
        }
        for required in requiredSnapshotEntries where !contents.contains(where: { $0.hasSuffix(required) }) {
            issues.append(Issue(severity: .error, message: "Missing required file: \(required)"))
        }
        let hasWeights = contents.contains { entry in
            weightExtensions.contains { entry.hasSuffix(".\($0)") }
        }
        if !hasWeights {
            issues.append(Issue(severity: .error, message: "No weight shards (\(weightExtensions.joined(separator: "/"))) found."))
        }
        // Zero-byte shards indicate an interrupted download.
        for entry in contents where weightExtensions.contains(where: { entry.hasSuffix(".\($0)") }) {
            let full = (path as NSString).appendingPathComponent(entry)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? Int64, size == 0 {
                issues.append(Issue(severity: .error, message: "Zero-byte weight shard: \(entry)"))
            }
        }
        return issues
    }

    static func hasBlockingIssues(_ issues: [Issue]) -> Bool {
        issues.contains { $0.severity == .error }
    }
}
