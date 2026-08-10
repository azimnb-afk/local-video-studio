import Foundation

/// Disk persistence for the global production queue.
///
/// Two properties matter more than anything else here: the file is written
/// atomically so a crash mid-write cannot leave a half-file that stops the app
/// launching, and a single unreadable record is dropped rather than taking the
/// whole queue with it. Losing one malformed job is recoverable; losing the
/// user's overnight queue because of it is not.
final class ProductionQueueStore {

    static let shared = ProductionQueueStore()

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.ltx.productionqueue.io")

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LTXVideoGenerator", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("production_queue.json")
        }
    }

    /// Decoded per-record so one bad entry cannot discard the rest.
    func load() -> [ProductionJob] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Whole-file decode first; it is the normal path.
        if let jobs = try? decoder.decode([ProductionJob].self, from: data) {
            return jobs
        }
        // Something in the file is malformed. Salvage every record that still
        // decodes rather than starting the user's queue from empty.
        guard let raw = try? decoder.decode([FailableJob].self, from: data) else { return [] }
        return raw.compactMap(\.value)
    }

    func save(_ jobs: [ProductionJob]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        let url = fileURL
        ioQueue.async {
            // .atomic writes to a temporary file and renames, so a crash never
            // leaves a truncated queue behind.
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Flushes any queued write. Used by tests and at termination.
    func flush() {
        ioQueue.sync {}
    }

    /// Decodes to nil instead of throwing, so `compactMap` can drop it.
    private struct FailableJob: Decodable {
        let value: ProductionJob?
        init(from decoder: Decoder) throws {
            value = try? ProductionJob(from: decoder)
        }
    }
}
