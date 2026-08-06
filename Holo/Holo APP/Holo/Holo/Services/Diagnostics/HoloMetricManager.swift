//
//  HoloMetricManager.swift
//  Holo
//
//  MetricKit 订阅：收集崩溃、卡顿、CPU 异常，写入诊断日志。
//  零第三方依赖，系统每天批量交付一次（非实时）。
//

import Foundation
import MetricKit

/// MetricKit 订阅器。收集崩溃/卡顿/CPU 异常，转存到本地诊断日志。
final class HoloMetricManager: NSObject, MXMetricManagerSubscriber {

    static let shared = HoloMetricManager()

    private override init() {
        super.init()
    }

    // MARK: - 订阅生命周期

    /// 启动订阅。在 App 启动时调用一次。
    func start() {
        let manager = MXMetricManager.shared
        // 避免重复订阅
        manager.remove(self)
        manager.add(self)
        HoloDiagnosticLogger.shared.cleanExpiredLogs()
        HoloDiagnosticLogger.shared.append(category: "MetricManager", "订阅启动，日志保留 7 天")
    }

    // MARK: - MXMetricManagerSubscriber

    /// 每日批量交付的性能指标（常规性能，首版只记录不下钻）。
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let ts = payload.timeStampBegin ?? Date()
            HoloDiagnosticLogger.shared.append(
                category: "Metric",
                "性能报告：\(ts)（含 CPU/内存/磁盘/网络概览）"
            )
        }
    }

    /// 诊断交付：崩溃、卡顿、CPU 异常等。这是最关键的一类。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            handleDiagnosticPayload(payload)
        }
    }

    // MARK: - 诊断处理

    private func handleDiagnosticPayload(_ payload: MXDiagnosticPayload) {
        let ts = payload.timeStampBegin ?? Date()

        // 崩溃
        if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
            for crash in crashes {
                let reason = crash.exceptionReason?.description ?? crash.terminationReason ?? "未知原因"
                HoloDiagnosticLogger.shared.append(
                    category: "Crash",
                    "崩溃 @ \(ts)：\(reason)（共 \(crashes.count) 条）"
                )
                logCallStack(crash.callStackTree, category: "Crash")
            }
        }

        // 卡顿（主线程阻塞）
        if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
            for hang in hangs {
                let duration = hang.hangDuration.description
                HoloDiagnosticLogger.shared.append(
                    category: "Hang",
                    "卡顿 @ \(ts)：\(duration)（主线程阻塞）"
                )
            }
        }

        // CPU 异常占用
        if let cpuExceptions = payload.cpuExceptionDiagnostics, !cpuExceptions.isEmpty {
            for cpu in cpuExceptions {
                HoloDiagnosticLogger.shared.append(
                    category: "CPUException",
                    "CPU 异常 @ \(ts)：\(cpu.totalCPUTime.description)"
                )
            }
        }

        // 磁盘写入异常
        if let diskExceptions = payload.diskWriteExceptionDiagnostics, !diskExceptions.isEmpty {
            for disk in diskExceptions {
                HoloDiagnosticLogger.shared.append(
                    category: "DiskWrite",
                    "磁盘写入异常 @ \(ts)：\(disk.totalWritesCaused.description)"
                )
            }
        }
    }

    /// 把调用栈以 JSON 形式写入日志（截断到 2000 字符，够定位又不太长）。
    /// MXCallStackTree 没有公开的属性访问，只能通过 JSONRepresentation 拿完整数据。
    private func logCallStack(_ tree: MXCallStackTree, category: String) {
        let jsonData = tree.jsonRepresentation()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "(无法解析调用栈 JSON)"
        let truncated = jsonString.count > 2000
            ? String(jsonString.prefix(2000)) + "…(已截断)"
            : jsonString
        HoloDiagnosticLogger.shared.append(category: "\(category)Stack", truncated)
    }
}
