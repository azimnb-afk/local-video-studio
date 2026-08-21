import Foundation

/// Machine-local, cross-profile coordination for MiniMax H3 generation.
///
/// Personal (com.localvideostudio.personal) and Dev (com.localvideostudio.dev)
/// intentionally use isolated Application Support trees and different managed
/// H3 ports (11237 / 11236), but both load the same multi-gigabyte quantized
/// H3 model into the same machine's unified memory. A controlled test on this
/// Mac — one short Personal H3 generation, then one short Dev H3 generation
/// started while Personal's was still active — drove free memory from tens of
/// gigabytes down to a few dozen megabytes (`memory_pressure`: Pages free
/// dropped to ~4160, i.e. ~65MB, on a 48GB machine) and made Dev's server take
/// roughly 180x longer to reach Ready than it does alone. A separate real
/// session under the same dual-generation condition saw a Ready Personal
/// server disappear mid-request ("network connection was lost"). Different
/// ports do not imply the hardware can safely run two H3 generations at once.
///
/// This lease does not merge or share Personal/Dev storage, and it never
/// blocks anything except the resource-heavy H3 generation call itself — not
/// Settings, Archive, Director planning, model selection, runtime install, or
/// LTX generation. It lives outside both profiles' Application Support
/// (machine-local, not per-profile) so it can coordinate across them, and it
/// intentionally stores only non-private coordination metadata.
enum MiniMaxH3GenerationLease {
    static let lockPath = "/private/tmp/LocalVideoStudio-MiniMaxH3.lock"

    struct Owner: Codable, Equatable {
        let pid: Int32
        let bundleID: String
        let startedAt: Date
    }

    enum LeaseError: Error, LocalizedError, Equatable {
        case heldByAnotherProcess(bundleID: String)

        var errorDescription: String? {
            switch self {
            case .heldByAnotherProcess:
                return "MiniMax H3 is already being used by another Local Video Studio process on this Mac. Wait for that generation to finish or cancel it before starting another H3 generation."
            }
        }
    }

    /// Acquires the lease, throwing `.heldByAnotherProcess` if a still-alive
    /// process already holds it. A lock left behind by a process whose PID no
    /// longer exists (crash, force-quit, force-kill) is treated as stale and
    /// safely replaced — H3 must never be permanently blocked by a dead app.
    @discardableResult
    static func acquire(
        lockPath: String = MiniMaxH3GenerationLease.lockPath,
        bundleID: String = Bundle.main.bundleIdentifier ?? "unknown",
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        fileManager: FileManager = .default
    ) throws -> Owner {
        let owner = Owner(pid: pid, bundleID: bundleID, startedAt: Date())
        let data = (try? JSONEncoder().encode(owner)) ?? Data()

        if createExclusive(at: lockPath, contents: data) {
            return owner
        }

        // Someone already holds the path. Only steal it if its owner is
        // provably gone — never on an unreadable/ambiguous lock, and never
        // just because acquisition raced.
        if let existing = readOwner(at: lockPath, fileManager: fileManager) {
            if processExists(existing.pid) {
                throw LeaseError.heldByAnotherProcess(bundleID: existing.bundleID)
            }
            // Stale: the recorded owner is confirmed gone.
            unlink(lockPath)
            if createExclusive(at: lockPath, contents: data) {
                return owner
            }
        }

        // Lost a race against another fresh acquisition, or the lock is
        // unreadable garbage. Re-check once rather than silently proceeding
        // unlocked.
        if let existing = readOwner(at: lockPath, fileManager: fileManager),
           processExists(existing.pid) {
            throw LeaseError.heldByAnotherProcess(bundleID: existing.bundleID)
        }
        throw LeaseError.heldByAnotherProcess(bundleID: "unknown")
    }

    /// Releases the lease only if this process is still its recorded owner —
    /// never clears a lock a different process has since (legitimately)
    /// acquired after taking over a stale one.
    static func release(
        lockPath: String = MiniMaxH3GenerationLease.lockPath,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        fileManager: FileManager = .default
    ) {
        guard let existing = readOwner(at: lockPath, fileManager: fileManager),
              existing.pid == pid else { return }
        unlink(lockPath)
    }

    /// `open(O_CREAT | O_EXCL)` is atomic at the filesystem level, avoiding
    /// the TOCTOU race a plain "check then write" JSON existence check would
    /// have between two processes acquiring at nearly the same instant.
    private static func createExclusive(at path: String, contents: Data) -> Bool {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        contents.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, raw.count)
        }
        return true
    }

    private static func readOwner(at path: String, fileManager: FileManager) -> Owner? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }

    /// Conservative: only reports "gone" when the kernel confirms no such
    /// process (ESRCH). Any other outcome (alive, or a permission edge case)
    /// is treated as "still there" so a live process is never stolen from.
    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
