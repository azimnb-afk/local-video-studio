import Foundation
@testable import LTXVideoGeneratorCore

func runHuggingFaceCacheCheckerTests(_ t: TestKit) {
    t.suite("Hugging Face cache readiness") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-hf-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func snapshot(_ name: String) -> URL {
            root
                .appendingPathComponent("models--example--model/snapshots", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }

        t.check(!HuggingFaceCacheChecker.isCached(repository: "example/model", hubDirectory: root),
                "missing cache is not ready")

        let configOnly = snapshot("config-only")
        try? FileManager.default.createDirectory(at: configOnly, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: configOnly.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        t.check(!HuggingFaceCacheChecker.isCached(repository: "example/model", hubDirectory: root),
                "metadata without weights is not ready")

        let weightOnly = snapshot("weight-only")
        try? FileManager.default.createDirectory(at: weightOnly, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: weightOnly.appendingPathComponent("model.safetensors").path, contents: Data([1]))
        t.check(!HuggingFaceCacheChecker.isCached(repository: "example/model", hubDirectory: root),
                "weights without metadata are not ready")

        let incomplete = snapshot("incomplete")
        try? FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: incomplete.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: incomplete.appendingPathComponent("model.safetensors").path, contents: Data())
        t.check(!HuggingFaceCacheChecker.isCached(repository: "example/model", hubDirectory: root),
                "zero-byte partial weight is not ready")

        let complete = snapshot("complete")
        try? FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: complete.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: complete.appendingPathComponent("model.safetensors").path, contents: Data([1, 2, 3]))
        t.check(HuggingFaceCacheChecker.isCached(repository: "example/model", hubDirectory: root),
                "metadata plus non-empty weight is ready")
    }

    // Post-Phase-3 regression: selection change must re-evaluate availability
    // per selected repository, not reuse a previously-installed model's
    // status. Uses the real HuggingFaceCacheChecker against a fixture
    // directory containing two distinct repos, one installed and one not.
    t.suite("Hugging Face cache readiness — selection change") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltx-hf-cache-selection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func snapshot(_ repo: String, _ name: String) -> URL {
            let repoName = repo.replacingOccurrences(of: "/", with: "--")
            return root
                .appendingPathComponent("models--\(repoName)/snapshots", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }

        // Encoder A is fully installed.
        let installedA = snapshot("mlx-community/gemma-3-12b-it-4bit", "rev-a")
        try? FileManager.default.createDirectory(at: installedA, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installedA.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: installedA.appendingPathComponent("model.safetensors").path, contents: Data([1, 2, 3]))

        // Encoder B has never been downloaded — no directory at all for it.

        t.check(HuggingFaceCacheChecker.isCached(repository: "mlx-community/gemma-3-12b-it-4bit", hubDirectory: root),
                "A installed -> A reports cached")
        t.check(!HuggingFaceCacheChecker.isCached(repository: "mlx-community/gemma-3-4b-it-bf16", hubDirectory: root),
                "A installed does not make unrelated selection B report cached — selection != installed")

        // Now B gets downloaded too (simulating a completed download after selection).
        let installedB = snapshot("mlx-community/gemma-3-4b-it-bf16", "rev-b")
        try? FileManager.default.createDirectory(at: installedB, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: installedB.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: installedB.appendingPathComponent("model.safetensors").path, contents: Data([4, 5, 6]))

        t.check(HuggingFaceCacheChecker.isCached(repository: "mlx-community/gemma-3-4b-it-bf16", hubDirectory: root),
                "B installed -> B reports cached without needing A's state")
        t.check(HuggingFaceCacheChecker.isCached(repository: "mlx-community/gemma-3-12b-it-4bit", hubDirectory: root),
                "A remains cached independently of B's state")
    }
}
