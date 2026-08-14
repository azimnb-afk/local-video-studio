import Foundation
import Darwin

struct MemorySnapshot: Codable, Equatable {
    var physicalBytes: UInt64
    var approximateAvailableBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var thermalState: String
    var capturedAt: Date

    var physicalGB: Double { Double(physicalBytes) / 1_073_741_824 }
    var availableGB: Double { Double(approximateAvailableBytes) / 1_073_741_824 }
    var swapUsedGB: Double { Double(swapUsedBytes) / 1_073_741_824 }
}

/// Point-in-time memory readings plus a live memory-pressure listener.
/// Builds on the existing MacOSSystemMemory helpers.
final class MemoryMonitor {
    static let shared = MemoryMonitor()

    private var pressureSource: DispatchSourceMemoryPressure?
    /// Latest pressure event seen (.normal until an event fires).
    private(set) var lastPressureEvent: DispatchSource.MemoryPressureEvent = []

    func snapshot() -> MemorySnapshot {
        let swap = Self.swapUsage()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return MemorySnapshot(
            physicalBytes: MacOSSystemMemory.physicalMemoryBytes,
            approximateAvailableBytes: MacOSSystemMemory.approximateAvailableBytes(),
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            thermalState: thermal,
            capturedAt: Date()
        )
    }

    /// vm.swapusage via sysctl.
    static func swapUsage() -> (total: UInt64, used: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return (0, 0) }
        return (usage.xsu_total, usage.xsu_used)
    }

    /// Current process physical footprint (task_info); matches Activity Monitor's
    /// "Real Memory" more closely than resident_size for MLX workloads.
    static func currentProcessFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    func startPressureMonitoring(handler: ((DispatchSource.MemoryPressureEvent) -> Void)? = nil) {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            let event = source.data
            self?.lastPressureEvent = event
            handler?(event)
        }
        source.resume()
        pressureSource = source
    }

    func stopPressureMonitoring() {
        pressureSource?.cancel()
        pressureSource = nil
    }
}
