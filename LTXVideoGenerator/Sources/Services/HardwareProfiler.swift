import Foundation

/// Static hardware description used as the prior for Auto Quality and as the
/// key for historical success records.
struct HardwareProfile: Codable, Equatable {
    var modelIdentifier: String    // "Mac16,11"
    var chipDescription: String    // "Apple M4 Pro"
    var physicalMemoryGB: Int      // 48

    /// Key for HistoricalSuccessStore records.
    var signature: String { "\(modelIdentifier)/\(physicalMemoryGB)GB" }

    enum MemoryTier: String, Codable {
        case tier16 = "16GB"
        case tier24 = "24GB"
        case tier32 = "32GB"
        case tier48 = "48GB"
        case tier64plus = "64GB+"
    }

    var memoryTier: MemoryTier {
        switch physicalMemoryGB {
        case ..<24: return .tier16
        case 24..<32: return .tier24
        case 32..<48: return .tier32
        case 48..<64: return .tier48
        default: return .tier64plus
        }
    }
}

enum HardwareProfiler {
    static func current() -> HardwareProfile {
        HardwareProfile(
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            chipDescription: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            physicalMemoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
