import Foundation

public struct HuggingFaceCacheChecker {
    public static func isCached(repository: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hubDirectory = home.appendingPathComponent(".cache/huggingface/hub")
        return isCached(repository: repository, hubDirectory: hubDirectory)
    }

    /// Low-cost readiness check for a Hugging Face model cache. A repository
    /// directory alone can be left behind by an interrupted download, so a
    /// usable snapshot must contain both metadata and a non-empty weight file.
    /// This intentionally does not hash or load multi-gigabyte weights.
    static func isCached(repository: String, hubDirectory: URL) -> Bool {
        let repoName = repository.replacingOccurrences(of: "/", with: "--")
        let basePath = hubDirectory.appendingPathComponent("models--\(repoName)")

        guard FileManager.default.fileExists(atPath: basePath.path) else { return false }

        let snapshotsPath = basePath.appendingPathComponent("snapshots")
        guard let snapshots = try? FileManager.default.contentsOfDirectory(atPath: snapshotsPath.path),
              !snapshots.isEmpty else {
            return false
        }

        for snapshot in snapshots {
            let snapshotDir = snapshotsPath.appendingPathComponent(snapshot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: snapshotDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let files = try? FileManager.default.contentsOfDirectory(atPath: snapshotDir.path) else {
                continue
            }

            let hasMetadata = files.contains("config.json") || files.contains("model_index.json")
            let hasNonEmptySafetensors = files.contains { filename in
                guard filename.hasSuffix(".safetensors") else { return false }
                let weightURL = snapshotDir.appendingPathComponent(filename)
                let size = (try? weightURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return size > 0
            }

            if hasMetadata && hasNonEmptySafetensors {
                return true
            }
        }

        return false
    }
}

public class DefaultPythonChecker: PythonChecking {
    public init() {}
    public func check() async -> SetupStatus {
        let env = PythonEnvironment.shared
        
        // 1 & 2: User configured path validation
        if let savedPath = UserDefaults.standard.string(forKey: "pythonPath"), !savedPath.isEmpty {
            let result = await env.validateWithSubprocess(path: savedPath, automaticInstallAndUpgrade: false)
            if result.success {
                return .ready
            } else if result.pendingUserConsent {
                return .missing(result.message) // Needs pip install/upgrade
            } else {
                // Saved path is invalid; attempt auto-detection as a recovery path
                let autoResult = await env.autoDetectPython()
                if let autoPath = autoResult.path, autoResult.result.success {
                    UserDefaults.standard.set(autoPath, forKey: "pythonPath")
                    return .ready
                }
                return .invalid(result.message)
            }
        }
        
        // 3 & 4: Auto-detect candidates
        let autoResult = await env.autoDetectPython()
        if let path = autoResult.path, autoResult.result.success {
            UserDefaults.standard.set(path, forKey: "pythonPath")
            return .ready
        }
        
        // 5: Unresolved
        if let _ = autoResult.path {
            return .invalid(autoResult.result.message)
        }
        
        return .missing(autoResult.result.message)
    }
}

public class DefaultModelChecker: ModelChecking {
    public init() {}
    
    public func checkVideoModel() async -> SetupStatus {
        let modelID = UserDefaults.standard.string(forKey: LTXModelCatalog.selectedModelIDKey) ?? LTXModelCatalog.defaultModelID
        guard let model = ModelRegistry.shared.descriptor(id: modelID) else {
            return .invalid("Selected model '\(modelID)' is not registered.")
        }
        
        if HuggingFaceCacheChecker.isCached(repository: model.repository) {
            return .ready
        } else {
            return .missing("Model '\(model.displayName)' is not downloaded. Open Preferences > Models to download.")
        }
    }
    
    public func checkTextEncoder() async -> SetupStatus {
        let encoderID = UserDefaults.standard.string(forKey: LTXTextEncoderCatalog.selectedTextEncoderIDKey) ?? LTXTextEncoderCatalog.defaultTextEncoderID
        let encoder = LTXTextEncoderCatalog.resolvedTextEncoder(id: encoderID)
        
        if HuggingFaceCacheChecker.isCached(repository: encoder.repo) {
            return .ready
        } else {
            return .missing("Text encoder '\(encoder.displayName)' is not downloaded. Open Preferences > Models to download.")
        }
    }
}

public class DefaultOptionalServiceChecker: OptionalServiceChecking {
    public init() {}
    
    public func checkLocalDirector() async -> SetupStatus {
        // DirectorProvider might not have isOllamaRunning. Let's use URLSession to hit localhost:11434
        let isRunning = await Self.checkOllamaRunning()
        if isRunning {
            return .ready
        } else {
            return .missing("Ollama is not running. Local AI Director will use basic fallback.")
        }
    }
    
    public func checkVision() async -> SetupStatus {
        let isRunning = await Self.checkOllamaRunning()
        if isRunning {
            return .ready
        } else {
            return .missing("Ollama is not running. Character Sheet extraction will require manual input.")
        }
    }
    
    private static func checkOllamaRunning() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {}
        return false
    }
}
