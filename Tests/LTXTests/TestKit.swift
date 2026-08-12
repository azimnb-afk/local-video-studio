import Foundation

/// Repository-owned, synthetic media fixtures used by tests that exercise real
/// MP4 metadata and frame extraction. They are intentionally resolved from the
/// checkout rather than a developer-maintained /tmp directory.
enum TestFixtures {
    private static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/LTXTests/Fixtures", isDirectory: true)

    static let videoWithAudioA = directory.appendingPathComponent("video-with-audio-a.mp4").path
    static let videoWithAudioB = directory.appendingPathComponent("video-with-audio-b.mp4").path
    static let videoOnly = directory.appendingPathComponent("video-only.mp4").path
}

/// Minimal dependency-free test kit.
/// The Command Line Tools toolchain on this machine ships neither XCTest nor
/// Swift Testing, so tests run as a plain executable: `swift run LTXTests`.
/// Exit code is non-zero when any check fails.
final class TestKit {
    static let shared = TestKit()
    private(set) var failures: [String] = []
    private(set) var passed = 0
    private var currentSuite = ""

    func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        print("== \(name)")
        do {
            try body()
        } catch {
            failures.append("\(name): uncaught error \(error)")
            print("   FAIL (uncaught): \(error)")
        }
    }

    func check(_ condition: Bool, _ label: String,
               file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
            print("   ok \(label)")
        } else {
            failures.append("\(currentSuite) / \(label) (\(file):\(line))")
            print("   FAIL \(label) (\(file):\(line))")
        }
    }

    func checkEqual<T: Equatable>(_ a: T, _ b: T, _ label: String,
                                  file: StaticString = #file, line: UInt = #line) {
        check(a == b, "\(label) [\(a) == \(b)]", file: file, line: line)
    }

    func checkThrows<E: Error & Equatable>(_ expected: E, _ label: String,
                                           file: StaticString = #file, line: UInt = #line,
                                           _ body: () throws -> Void) {
        do {
            try body()
            check(false, "\(label) — expected throw \(expected), nothing thrown", file: file, line: line)
        } catch let err as E where err == expected {
            check(true, label, file: file, line: line)
        } catch {
            check(false, "\(label) — expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func finish() -> Never {
        print("")
        print("\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("Failures:")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
        exit(0)
    }
}
