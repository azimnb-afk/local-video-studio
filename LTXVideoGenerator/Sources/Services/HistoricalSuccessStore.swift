import Foundation

struct HistoricalSuccessRecord: Codable, Equatable {
    var hardwareSignature: String
    var modelID: String
    var profileID: String
    var succeeded: Bool
    var peakMemoryBytes: Int64?
    var wallSeconds: Double?
    var recordedAt: Date
}

/// Per-hardware, per-model history of which quality profiles actually worked.
/// Auto Quality prefers the highest profile with a known success and avoids
/// profiles with recent failures.
final class HistoricalSuccessStore {
    static let shared = HistoricalSuccessStore()

    private let storeURL: URL
    private(set) var records: [HistoricalSuccessRecord] = []
    /// Only the most recent N records are kept per (hardware, model, profile).
    private let maxRecordsPerKey = 5

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("LTXVideoGenerator", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storeURL = dir.appendingPathComponent("quality_history.json")
        }
        load()
    }

    func record(_ record: HistoricalSuccessRecord) {
        records.append(record)
        // Trim old records per key.
        let key: (HistoricalSuccessRecord) -> String = { "\($0.hardwareSignature)|\($0.modelID)|\($0.profileID)" }
        let recordKey = key(record)
        let matching = records.filter { key($0) == recordKey }.sorted { $0.recordedAt > $1.recordedAt }
        if matching.count > maxRecordsPerKey {
            let keep = Set(matching.prefix(maxRecordsPerKey).map(\.recordedAt))
            records.removeAll { key($0) == recordKey && !keep.contains($0.recordedAt) }
        }
        save()
    }

    /// Latest outcome per profile for the given hardware+model.
    func latestOutcomes(hardwareSignature: String, modelID: String) -> [String: Bool] {
        var outcome: [String: (Date, Bool)] = [:]
        for r in records where r.hardwareSignature == hardwareSignature && r.modelID == modelID {
            if let existing = outcome[r.profileID], existing.0 > r.recordedAt { continue }
            outcome[r.profileID] = (r.recordedAt, r.succeeded)
        }
        return outcome.mapValues(\.1)
    }

    /// Highest-ranked profile whose latest outcome was success.
    func highestKnownSafeProfile(hardwareSignature: String, modelID: String) -> QualityProfile? {
        let outcomes = latestOutcomes(hardwareSignature: hardwareSignature, modelID: modelID)
        return QualityProfileLadder.all
            .filter { outcomes[$0.id] == true }
            .max { $0.rank < $1.rank }
    }

    /// Returns true when the latest recorded attempt for this concrete profile
    /// failed. A success at a lower profile alone is not evidence that higher
    /// profiles are unsafe.
    func latestAttemptFailed(
        profileID: String,
        hardwareSignature: String,
        modelID: String
    ) -> Bool {
        latestOutcomes(hardwareSignature: hardwareSignature, modelID: modelID)[profileID] == false
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([HistoricalSuccessRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
