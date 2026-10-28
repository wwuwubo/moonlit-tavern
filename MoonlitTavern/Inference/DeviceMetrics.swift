import Foundation
import os

/// 设备与进程内存的真实读数。
enum DeviceMetrics {
    /// 系统允许本进程再分配的内存（MB）。这是 iPadOS 给单个应用的实际上限，不等于物理内存。
    static func availableMemoryMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }

    /// 本进程当前的物理内存占用（MB），与 Xcode 内存仪表一致的 phys_footprint。
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    static var physicalMemoryMB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576
    }

    static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "微热"
        case .serious: return "偏热"
        case .critical: return "过热"
        @unknown default: return "未知"
        }
    }

    static var isThermallyStressed: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }
}

/// 推理引擎日志（llama.cpp 输出 + 本应用事件），保存在内存里，设置页可查看和复制。
/// 不记录任何 API Key 或聊天内容。
final class EngineLog: @unchecked Sendable {
    static let shared = EngineLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 600
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        lines.append("[\(formatter.string(from: Date()))] \(trimmed)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
