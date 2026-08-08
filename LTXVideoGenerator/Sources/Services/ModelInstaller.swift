import Foundation

/// Install planning for registry models. This type NEVER starts a download on
/// its own: it produces a plan (disk preflight, license acknowledgement,
/// pinned-revision command) that the user must explicitly execute or approve.
final class ModelInstaller {

    struct InstallPlan: Equatable {
        var modelID: String
        var repository: String
        var revision: String?
        var estimatedSizeBytes: Int64
        var availableDiskBytes: Int64
        var requiresLicenseAcknowledgement: Bool
        /// Suggested manual command (mirrors what the app's downloader runs).
        var downloadCommand: String
        var diskPreflightPassed: Bool
    }

    enum InstallError: Error, Equatable {
        case modelNotRegistered(String)
        case insufficientDisk(requiredGB: Double, availableGB: Double)
        case licenseNotAcknowledged(String)
        case revisionNotPinned(String)
        case manifestInvalid(String)
    }

    private let registry: ModelRegistry
    private let recordsURL: URL
    private(set) var records: [ModelInstallRecord] = []

    init(registry: ModelRegistry = .shared, recordsURL: URL? = nil) {
        self.registry = registry
        if let recordsURL {
            self.recordsURL = recordsURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("LTXVideoGenerator", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.recordsURL = dir.appendingPathComponent("model_installs.json")
        }
        load()
    }

    /// Builds an install plan with disk preflight. Throws when the model is
    /// unregistered or (for derived models) has no pinned revision.
    func planInstall(modelID: String, availableDiskBytesOverride: Int64? = nil) throws -> InstallPlan {
        guard let model = registry.descriptor(id: modelID) else {
            throw InstallError.modelNotRegistered(modelID)
        }
        if !model.isOfficial && model.revision == nil {
            throw InstallError.revisionNotPinned(modelID)
        }
        let descriptorIssues = ManifestValidator.validateDescriptor(model)
        if ManifestValidator.hasBlockingIssues(descriptorIssues) {
            throw InstallError.manifestInvalid(descriptorIssues.map(\.description).joined(separator: "; "))
        }

        let estimated = Int64((model.estimatedModelSizeGB ?? 0) * 1_000_000_000)
        let available = availableDiskBytesOverride ?? Self.availableDiskBytes()
        // Require headroom: model size + 10 GB working space.
        let required = estimated + 10_000_000_000
        let revisionArg = model.revision.map { " --revision \($0)" } ?? ""

        return InstallPlan(
            modelID: modelID,
            repository: model.repository,
            revision: model.revision,
            estimatedSizeBytes: estimated,
            availableDiskBytes: available,
            requiresLicenseAcknowledgement: model.license.requiresAcknowledgement,
            downloadCommand: "hf download \(model.repository)\(revisionArg)",
            diskPreflightPassed: available > required
        )
    }

    /// Records a completed install (after the user explicitly downloaded the
    /// model). License acknowledgement is mandatory when the license requires it.
    func recordInstall(modelID: String, revision: String?, licenseAcknowledged: Bool, checksumVerified: Bool) throws {
        guard let model = registry.descriptor(id: modelID) else {
            throw InstallError.modelNotRegistered(modelID)
        }
        if model.license.requiresAcknowledgement && !licenseAcknowledged {
            throw InstallError.licenseNotAcknowledged(modelID)
        }
        records.removeAll { $0.modelID == modelID }
        records.append(ModelInstallRecord(
            modelID: modelID,
            installedAt: Date(),
            revision: revision,
            licenseAcknowledgedAt: licenseAcknowledged ? Date() : nil,
            checksumVerified: checksumVerified
        ))
        save()
    }

    func installRecord(modelID: String) -> ModelInstallRecord? {
        records.first { $0.modelID == modelID }
    }

    static func availableDiskBytes() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([ModelInstallRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }
}
