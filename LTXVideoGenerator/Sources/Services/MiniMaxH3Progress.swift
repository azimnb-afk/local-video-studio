import Foundation

// MARK: - MiniMax H3 Runtime Telemetry Events

enum MiniMaxH3RuntimeEvent: Equatable, Sendable {
    case configuring(width: Int, height: Int, frames: Int, steps: Int)
    case keyframeConditioning
    case textConditioning
    case ditLoaded
    case samplingStep(current: Int, total: Int, stepMs: Int?)
    case samplingDone(totalMs: Int?)
    case videoDecoding(totalMs: Int?)
    case audioDecoding(samples: Int?, sampleRate: Int?)
    case generationOutput(frames: Int, width: Int, height: Int)
    case cancelled
}

// MARK: - MiniMax H3 Progress Parser

struct MiniMaxH3ProgressParser: Sendable {
    
    static func parseLine(_ line: String) -> MiniMaxH3RuntimeEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        // 1. Sampling Step: "[minimax-h3] step 6/10 sigma 0.9231 (35468 ms)" or "(cached velocity, 2 ms)"
        if trimmed.contains("[minimax-h3] step ") {
            if let match = parseStepLine(trimmed) {
                return .samplingStep(current: match.current, total: match.total, stepMs: match.ms)
            }
        }
        
        // 2. Sampling Done: "[minimax-h3] sampling done in 213623 ms, DiT released"
        if trimmed.contains("[minimax-h3] sampling done") {
            let ms = parseTrailingMs(trimmed, prefix: "in ")
            return .samplingDone(totalMs: ms)
        }
        
        // 3. Video Decoded: "[minimax-h3] video decoded in 77095 ms (load+decode)"
        if trimmed.contains("[minimax-h3] video decoded") {
            let ms = parseTrailingMs(trimmed, prefix: "in ")
            return .videoDecoding(totalMs: ms)
        }
        
        // 4. Audio Decoded: "[minimax-h3] audio decoded: 120000 samples/ch at 32000 Hz (2675 ms)"
        if trimmed.contains("[minimax-h3] audio decoded") {
            let samples = parseAudioSamples(trimmed)
            let rate = parseAudioSampleRate(trimmed)
            return .audioDecoding(samples: samples, sampleRate: rate)
        }
        
        // 5. Keyframe Conditioning: "[video] minimax-h3 first keyframe conditioning engaged" or "[minimax-h3] 1 keyframe(s)"
        if trimmed.contains("first keyframe conditioning engaged") || trimmed.contains("keyframe(s) +") {
            return .keyframeConditioning
        }
        
        // 6. Text Conditioning: "[minimax-h3] text encoded"
        if trimmed.contains("text encoded") {
            return .textConditioning
        }
        
        // 7. DiT Loaded: "[minimax-h3] dit loaded"
        if trimmed.contains("dit loaded") {
            return .ditLoaded
        }
        
        // 8. Output Ready: "[video] -> 90f 288x512"
        if trimmed.contains("[video] -> ") {
            if let output = parseOutputLine(trimmed) {
                return .generationOutput(frames: output.frames, width: output.width, height: output.height)
            }
        }
        
        // 9. Config: "[video] minimax-h3 512x288 90f/window ... steps=10"
        if trimmed.contains("[video] minimax-h3 ") && trimmed.contains("steps=") {
            if let config = parseConfigLine(trimmed) {
                return .configuring(width: config.width, height: config.height, frames: config.frames, steps: config.steps)
            }
        }
        
        // 10. Cancellation: "[video] generation cancelled"
        if trimmed.contains("generation cancelled") {
            return .cancelled
        }
        
        return nil
    }
    
    private static func parseStepLine(_ line: String) -> (current: Int, total: Int, ms: Int?)? {
        guard let stepRange = line.range(of: "step ") else { return nil }
        let afterStep = line[stepRange.upperBound...]
        let parts = afterStep.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard let fractionPart = parts.first else { return nil }
        let slashParts = fractionPart.split(separator: "/")
        guard slashParts.count == 2,
              let current = Int(slashParts[0]),
              let total = Int(slashParts[1]),
              current >= 1, total >= 1 else { return nil }
        
        var stepMs: Int? = nil
        if let msRange = line.range(of: " ms)", options: .backwards) {
            let beforeMs = line[..<msRange.lowerBound]
            var digits = ""
            for ch in beforeMs.reversed() {
                if ch.isNumber {
                    digits.insert(ch, at: digits.startIndex)
                } else if !digits.isEmpty {
                    break
                }
            }
            if !digits.isEmpty {
                stepMs = Int(digits)
            }
        }
        return (current, total, stepMs)
    }
    
    private static func parseTrailingMs(_ line: String, prefix: String) -> Int? {
        guard let prefixRange = line.range(of: prefix) else { return nil }
        let afterPrefix = line[prefixRange.upperBound...]
        guard let msRange = afterPrefix.range(of: " ms") else { return nil }
        let numStr = afterPrefix[..<msRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(numStr)
    }
    
    private static func parseAudioSamples(_ line: String) -> Int? {
        guard let colonRange = line.range(of: "decoded:") else { return nil }
        let afterColon = line[colonRange.upperBound...]
        guard let samplesRange = afterColon.range(of: " samples") else { return nil }
        let numStr = afterColon[..<samplesRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(numStr)
    }
    
    private static func parseAudioSampleRate(_ line: String) -> Int? {
        guard let atRange = line.range(of: " at ") else { return nil }
        let afterAt = line[atRange.upperBound...]
        guard let hzRange = afterAt.range(of: " Hz") else { return nil }
        let numStr = afterAt[..<hzRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(numStr)
    }
    
    private static func parseOutputLine(_ line: String) -> (frames: Int, width: Int, height: Int)? {
        guard let arrowRange = line.range(of: "-> ") else { return nil }
        let afterArrow = line[arrowRange.upperBound...]
        let parts = afterArrow.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let framesStr = parts[0].replacingOccurrences(of: "f", with: "")
        guard let frames = Int(framesStr) else { return nil }
        let dims = parts[1].split(separator: "x")
        guard dims.count == 2,
              let w = Int(dims[0]),
              let h = Int(dims[1]) else { return nil }
        return (frames, w, h)
    }
    
    private static func parseConfigLine(_ line: String) -> (width: Int, height: Int, frames: Int, steps: Int)? {
        // "[video] minimax-h3 512x288 90f/window ... steps=10"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        var width = 512
        var height = 288
        var frames = 90
        var steps = 10
        for p in parts {
            if p.contains("x") && !p.contains("=") && !p.contains("/") {
                let dims = p.split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                    width = w
                    height = h
                }
            } else if p.hasSuffix("f/window") {
                let fStr = p.replacingOccurrences(of: "f/window", with: "")
                if let f = Int(fStr) { frames = f }
            } else if p.hasPrefix("steps=") {
                let sStr = p.replacingOccurrences(of: "steps=", with: "")
                if let s = Int(sStr) { steps = s }
            }
        }
        return (width, height, frames, steps)
    }
}

// MARK: - MiniMax H3 Progress Session

final class MiniMaxH3ProgressSession: @unchecked Sendable {
    private let lock = NSLock()
    private let request: GenerationRequest
    private let progressHandler: (Double, String) -> Void
    
    private var currentProgress: Double = 0.03
    private var currentStep: Int = 0
    private var totalSteps: Int
    private var stepDurationsMs: [Int] = []
    private var isSampling: Bool = false
    private var isFinished: Bool = false
    private let startTime: Date = Date()
    
    // Sampling fraction range: 0.15 ... 0.90
    private let samplingStartFraction: Double = 0.15
    private let samplingEndFraction: Double = 0.90
    
    init(
        request: GenerationRequest,
        progressHandler: @escaping (Double, String) -> Void
    ) {
        self.request = request
        self.progressHandler = progressHandler
        self.totalSteps = max(1, request.parameters.numInferenceSteps)
        
        // Initial state
        let initialMsg = MiniMaxH3ProgressPresentation.generatingMessage(for: request)
        progressHandler(0.03, initialMsg)
    }
    
    func handleLine(_ line: String) {
        guard let event = MiniMaxH3ProgressParser.parseLine(line) else { return }
        handleEvent(event)
    }
    
    func handleEvent(_ event: MiniMaxH3RuntimeEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        
        switch event {
        case .configuring(_, _, _, let steps):
            if steps > 0 { self.totalSteps = steps }
            emit(progress: max(currentProgress, 0.04), message: "Preparing MiniMax H3…")
            
        case .keyframeConditioning:
            emit(progress: max(currentProgress, 0.08), message: "Preparing source image conditioning…")
            
        case .textConditioning:
            let msg = request.isImageToVideo ? "Encoding prompt & source conditioning…" : "Preparing text conditioning…"
            emit(progress: max(currentProgress, 0.12), message: msg)
            
        case .ditLoaded:
            emit(progress: max(currentProgress, 0.14), message: "Starting DiT sampling…")
            
        case .samplingStep(let current, let total, let stepMs):
            self.isSampling = true
            self.currentStep = current
            if total > 0 { self.totalSteps = total }
            if let stepMs, stepMs > 0 {
                self.stepDurationsMs.append(stepMs)
            }
            
            let stepFraction = Double(current) / Double(totalSteps)
            let calculated = samplingStartFraction + stepFraction * (samplingEndFraction - samplingStartFraction)
            let newProgress = max(currentProgress, min(samplingEndFraction, calculated))
            
            let eta = calculateETA(current: current, total: totalSteps)
            let etaSuffix = eta != nil ? " · \(eta!)" : ""
            let message = "Generating video · Step \(current) of \(totalSteps)\(etaSuffix)"
            emit(progress: newProgress, message: message)
            
        case .samplingDone:
            emit(progress: max(currentProgress, 0.90), message: "Sampling complete · Decoding video…")
            
        case .videoDecoding:
            emit(progress: max(currentProgress, 0.94), message: "Video decoded · Processing audio…")
            
        case .audioDecoding:
            emit(progress: max(currentProgress, 0.96), message: "Audio decoded · Finalizing output…")
            
        case .generationOutput:
            emit(progress: max(currentProgress, 0.97), message: "Finalizing video container…")
            
        case .cancelled:
            self.isFinished = true
        }
    }
    
    func recordMuxing() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        emit(progress: max(currentProgress, 0.98), message: "Muxing final video and audio…")
    }
    
    func recordComplete() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        self.isFinished = true
        emit(progress: 1.0, message: "MiniMax H3 generation complete.")
    }
    
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        self.isFinished = true
    }
    
    private func emit(progress: Double, message: String) {
        currentProgress = max(currentProgress, progress)
        progressHandler(currentProgress, message)
    }
    
    private func calculateETA(current: Int, total: Int) -> String? {
        guard stepDurationsMs.count >= 2, current < total else { return nil }
        // Use average of last observed steps
        let recent = stepDurationsMs.suffix(3)
        let avgMs = Double(recent.reduce(0, +)) / Double(recent.count)
        let remainingSteps = total - current
        let remainingSeconds = Int((Double(remainingSteps) * avgMs / 1000.0).rounded())
        guard remainingSeconds > 0 else { return nil }
        
        let mins = (remainingSeconds + 59) / 60
        if mins > 1 {
            return "About \(mins) min remaining"
        } else {
            return "About 1 min remaining"
        }
    }
}

// MARK: - MiniMax H3 Log Tailer

final class MiniMaxH3LogTailer: @unchecked Sendable {
    private let lock = NSLock()
    private let logFileURL: URL
    private let lineHandler: @Sendable (String) -> Void
    private var isRunning: Bool = false
    private var fileOffset: UInt64 = 0
    private var pollingTask: Task<Void, Never>?
    private var lineBuffer: String = ""
    
    init(
        endpoint: String,
        lineHandler: @escaping @Sendable (String) -> Void
    ) {
        self.lineHandler = lineHandler
        let port = MiniMaxH3Configuration.endpointURL(endpoint)?.port ?? 11236
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logFileURL = home.appendingPathComponent(".mlx-serve/logs/mlx-serve-\(port).log")
    }
    
    init(
        fileURL: URL,
        lineHandler: @escaping @Sendable (String) -> Void
    ) {
        self.logFileURL = fileURL
        self.lineHandler = lineHandler
    }
    
    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        
        // Seek to the end of current log file so previous job logs are skipped
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64 {
            self.fileOffset = size
        } else {
            self.fileOffset = 0
        }
        lock.unlock()
        
        pollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.poll()
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }
    }
    
    func stop() {
        lock.lock()
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        lock.unlock()
    }
    
    private func poll() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else {
            lock.unlock()
            return
        }
        defer {
            try? handle.close()
            lock.unlock()
        }
        
        do {
            try handle.seek(toOffset: fileOffset)
            let data = handle.readDataToEndOfFile()
            if !data.isEmpty {
                fileOffset += UInt64(data.count)
                if let text = String(data: data, encoding: .utf8) {
                    processIncomingText(text)
                }
            }
        } catch {
            // Log file might be rotating or locked; ignore and retry next poll
        }
    }
    
    private func processIncomingText(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer.removeSubrange(..<newlineRange.upperBound)
            if !line.isEmpty {
                lineHandler(line)
            }
        }
    }
}

// MARK: - Auto Movie Multi-Shot Weighted Progress

struct AutoMovieShotWorkload: Equatable, Sendable {
    let shotIndex: Int
    let frames: Int
    let steps: Int
    let width: Int
    let height: Int
    
    init(shotIndex: Int, frames: Int, steps: Int, width: Int = 512, height: Int = 288) {
        self.shotIndex = shotIndex
        self.frames = max(1, frames)
        self.steps = max(1, steps)
        self.width = max(1, width)
        self.height = max(1, height)
    }
    
    var computeWeight: Double {
        Double(frames * steps)
    }
}

struct AutoMovieProgressWeightCalculator: Sendable {
    
    static func calculateOverallProgress(
        shots: [AutoMovieShotWorkload],
        currentShotIndex: Int,
        currentShotFraction: Double,
        isAssembling: Bool = false,
        isCompleted: Bool = false
    ) -> Double {
        if isCompleted { return 1.0 }
        guard !shots.isEmpty else { return isAssembling ? 0.98 : 0.0 }
        
        let totalShotsWeight = shots.reduce(0.0) { $0 + $1.computeWeight }
        guard totalShotsWeight > 0 else { return 0.0 }
        
        // Reserve 4% for final assembly & file persistence
        let totalJobWeight = totalShotsWeight / 0.96
        
        if isAssembling {
            return min(0.99, 0.96 + 0.02)
        }
        
        let clampedCurrentIndex = max(0, min(currentShotIndex, shots.count - 1))
        var completedWeight = 0.0
        for i in 0..<clampedCurrentIndex {
            completedWeight += shots[i].computeWeight
        }
        
        let currentWeight = shots[clampedCurrentIndex].computeWeight
        let clampedFraction = max(0.0, min(1.0, currentShotFraction))
        
        let currentEffectiveWeight = completedWeight + (clampedFraction * currentWeight)
        let overallFraction = currentEffectiveWeight / totalJobWeight
        
        return max(0.0, min(0.96, overallFraction))
    }
}
