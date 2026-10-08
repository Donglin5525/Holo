//
//  HoloHangDiagnosticCollector.swift
//  Holo
//
//  卡顿取证装置（2026-10-08 掉帧诊断批次）
//
//  背景：东林真机反馈「各功能模块阶段性卡几秒自愈」，代码侧最大嫌疑是
//  CloudKit 分批导入触发的全 App 数据刷新连锁，但按「日志先行」纪律需
//  卡顿时刻的真实主线程调用树才能定罪动手。
//
//  原理：MetricKit 会在主线程挂起 ≥250ms 时自动生成 MXHangDiagnostic
//  （含完整调用树），本采集器只订阅、落盘、打日志，不改变任何运行行为。
//  报告写入 Documents/HangDiagnostics/*.json，真机用
//  devicectl copy from --domain-type appDataContainer 拉回符号化分析。
//  与 CloudImportRelay 的同步批次 os_log 对时，即可回答
//  「卡顿发生时是否恰有 iCloud 导入批次在落地」。
//

import Foundation
import MetricKit
import os.log

final class HoloHangDiagnosticCollector: NSObject, MXMetricManagerSubscriber {

    static let shared = HoloHangDiagnosticCollector()

    private let logger = Logger(subsystem: "com.holo.app", category: "HangMonitor")

    /// 已落盘报告数（日志侧对账用）
    private var savedCount = 0

    private var storageDirectory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("HangDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        super.init()
    }

    /// 幂等启动（HoloApp.init 调用；hosted test 宿主不装配）
    private var started = false
    func startIfNeeded() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        logger.notice("卡顿取证已启动，既有报告将由系统择机回调")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // 系统择机回调（通常下次启动后），时间戳用收到时刻即可——精确时长在报告内
        let hangs = payloads.compactMap(\.hangDiagnostics).flatMap { $0 }
        guard !hangs.isEmpty else { return }
        for hang in hangs {
            save(hang)
        }
        logger.notice("收到卡顿报告 \(hangs.count) 份（累计落盘 \(self.savedCount)），拉取路径 Documents/HangDiagnostics")
    }

    /// didReceive 在后台线程回调（MXMetricManager 约定），落盘本身线程安全
    private func save(_ hang: MXHangDiagnostic) {
        let durationMs = Int(hang.hangDuration.converted(to: .seconds).value * 1000)
        let stamp = Self.fileStamp.string(from: Date())
        let file = storageDirectory
            .appendingPathComponent("hang-\(stamp)-\(durationMs)ms.json")
        do {
            try hang.jsonRepresentation().write(to: file, options: .atomic)
            savedCount += 1
            // 关键字段同步打日志：不拉文件也能先做粗判（挂起时长 + 落盘文件名对时）
            logger.notice("卡顿 \(durationMs)ms 调用树已落 \(file.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("卡顿报告落盘失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
