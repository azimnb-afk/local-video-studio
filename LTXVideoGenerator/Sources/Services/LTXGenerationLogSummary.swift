import Foundation

enum LTXGenerationLogSummary {
    static let defaultLogPath = "/tmp/ltx_generation.log"

    static func appendToLog(path: String = defaultLogPath, lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Tail excerpt prioritizing stderr / native / MLX failure lines for bug reports.
    static func userFacingExcerpt(path: String = defaultLogPath, maxTailChars: Int = 32_000) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty
        else {
            return "(Log missing or empty at \(path).)"
        }
        let full = String(data: data, encoding: .utf8) ?? ""
        let tail = full.count > maxTailChars ? String(full.suffix(maxTailChars)) : full
        let lines = tail.components(separatedBy: .newlines)

        let keywordPredicates: [(String) -> Bool] = [
            { $0.contains("[stderr]") },
            { $0.contains("runtimeerror") },
            { $0.contains("libc++abi") },
            { $0.contains("uncaught exception") },
            { $0.contains("impacting interactivity") },
            { $0.contains("kiogpucommandbuffer") },
            { $0.contains("text_encoder") },
            { $0.contains("eval_chunk") },
            { $0.contains("sigkill") },
            { $0.contains("code -9") },
            { $0.contains("code -6") },
            { $0.contains("signal 9") },
            { $0.contains("diagnostic_") },
        ]

        var matched: [String] = []
        for line in lines {
            let low = line.lowercased()
            if keywordPredicates.contains(where: { $0(low) }) {
                matched.append(line)
            }
        }
        if matched.count > 16 {
            matched = Array(matched.suffix(16))
        }

        let lastSignificant = lines.reversed().first { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            let low = t.lowercased()
            return low.contains("error")
                || low.contains("traceback")
                || low.contains("failed")
                || low.contains("exception")
                || low.contains("metal")
                || low.contains("sig")
        } ?? lines.reversed().first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var parts: [String] = []
        if !matched.isEmpty {
            parts.append("Relevant log lines:\n" + matched.joined(separator: "\n"))
        }
        if let last = lastSignificant {
            parts.append("Last notable line:\n\(last)")
        }
        if parts.isEmpty {
            parts.append(String(tail.suffix(2500)))
        }
        return parts.joined(separator: "\n\n")
    }
}
