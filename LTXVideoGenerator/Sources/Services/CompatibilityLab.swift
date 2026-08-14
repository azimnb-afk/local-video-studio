import Foundation

// MARK: - Verification gate

/// The full checklist a derived model must pass before `verified=true`.
/// One missing or failed check keeps the model unverified and blocked from
/// generation (enforced in ModelRegistry.validateForGeneration).
enum VerificationCheck: String, CaseIterable, Codable {
    case licenseVerified
    case provenanceVerified
    case revisionPinned
    case manifestValid
    case backendLoadSuccess
    case t2vSmokeTest
    case i2vSmokeTest
    case audioTest
    case unloadReclaimTest
    case memoryBenchmark
    case adultClassificationEvidence
}

struct CheckStatus: Codable, Equatable {
    enum State: String, Codable {
        case pending
        case passed
        case failed
    }
    var state: State
    var note: String?
    var recordedAt: Date?

    static let pending = CheckStatus(state: .pending, note: nil, recordedAt: nil)
}

struct VerificationReport: Codable, Equatable {
    var modelID: String
    var checks: [String: CheckStatus]   // keyed by VerificationCheck.rawValue
    var updatedAt: Date

    init(modelID: String) {
        self.modelID = modelID
        var initial: [String: CheckStatus] = [:]
        for check in VerificationCheck.allCases {
            initial[check.rawValue] = .pending
        }
        self.checks = initial
        self.updatedAt = Date()
    }

    var allPassed: Bool {
        VerificationCheck.allCases.allSatisfy { checks[$0.rawValue]?.state == .passed }
    }

    var summary: String {
        let passed = VerificationCheck.allCases.filter { checks[$0.rawValue]?.state == .passed }.count
        let failed = VerificationCheck.allCases.filter { checks[$0.rawValue]?.state == .failed }.count
        return "\(passed)/\(VerificationCheck.allCases.count) passed, \(failed) failed"
    }
}

// MARK: - Compatibility Lab

/// Tracks derived-model verification state on disk. This is infrastructure:
/// runtime checks (load/smoke/memory) are executed by scripts/compat_lab_smoke.sh
/// against locally installed weights and their outcomes recorded here.
/// The lab never downloads weights on its own.
final class CompatibilityLab {
    static let shared = CompatibilityLab()

    private let storeURL: URL
    private(set) var reports: [String: VerificationReport] = [:]

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let dir = AppStorageDirectory.root
            self.storeURL = dir.appendingPathComponent("compat_lab.json")
        }
        load()
    }

    func report(for modelID: String) -> VerificationReport {
        reports[modelID] ?? VerificationReport(modelID: modelID)
    }

    func record(_ check: VerificationCheck, _ state: CheckStatus.State, note: String? = nil, for modelID: String) {
        var report = report(for: modelID)
        report.checks[check.rawValue] = CheckStatus(state: state, note: note, recordedAt: Date())
        report.updatedAt = Date()
        reports[modelID] = report
        save()
    }

    /// True only when every gate check passed. This value gates
    /// RuntimeCompatibility.verified promotion — never set verified=true directly.
    func isVerified(modelID: String) -> Bool {
        reports[modelID]?.allPassed ?? false
    }

    /// Applies lab verification state onto a registry descriptor.
    /// Returns the descriptor with runtime.verified promoted iff all checks passed.
    func applyVerification(to descriptor: ModelDescriptor) -> ModelDescriptor {
        var updated = descriptor
        if !descriptor.isOfficial {
            updated.runtime.verified = isVerified(modelID: descriptor.id)
        }
        return updated
    }

    // MARK: Persistence (atomic)

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: VerificationReport].self, from: data) else {
            return
        }
        reports = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

extension CompatibilityLab {
    /// Records the user's explicit acceptance of a model's declared license.
    ///
    /// `licenseVerified` is the one gate check that is not a runtime
    /// measurement: whether a license permits a given use is a decision for
    /// whoever runs the app, not something this code can determine. Every other
    /// check is recorded from an observed result; this one is recorded from an
    /// explicit human action, and the note keeps what was accepted.
    func recordLicenseAcknowledgement(for descriptor: ModelDescriptor) {
        let license = descriptor.license
        let source = license.url ?? "no URL declared"
        record(.licenseVerified, .passed,
               note: "Accepted by the user in Preferences: \"\(license.name)\" (\(source)). "
                   + "Recorded as an acknowledgement, not as an independent legal determination.",
               for: descriptor.id)
    }

    /// True when the user has accepted this model's license.
    func hasLicenseAcknowledgement(for modelID: String) -> Bool {
        report(for: modelID).checks[VerificationCheck.licenseVerified.rawValue]?.state == .passed
    }
}
