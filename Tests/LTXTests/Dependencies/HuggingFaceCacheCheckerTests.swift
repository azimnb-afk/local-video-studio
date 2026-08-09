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
}
