//
//  ReceiptBackgroundProbeIntent.swift
//  Holo
//
//  图片快捷指令自动记账 M0 · 后台执行探针（2026-09-14 完整方案 §22.3/§28-M0）
//  目的：在真机上验证「Holo 不在前台时，系统快捷指令能否让主 App 后台执行
//  5/15/25 秒级任务、如何被取消、锁屏下表现如何」——这是自动记账链路的
//  系统能力前提，必须先于 M2 拿到真机证据。
//
//  铁律：本探针不读写任何账目、不发起视觉请求；仅 DEBUG 构建存在，
//  正式包与快捷指令模板都不包含它。
//

#if DEBUG

import AppIntents
import Foundation
import os.log

struct ReceiptBackgroundProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "图片记账后台探针"
    static let description = IntentDescription(
        "开发诊断用：验证 Holo 在后台/锁屏时能否执行指定时长的任务。不读写任何账目。"
    )
    // M0 探针核心问题：后台运行是否拉起 App、最长存活多久
    static let openAppWhenRun = false

    @Parameter(title: "耗时秒数", description: "探针空转的秒数（建议 5/15/25）", default: 10, inclusiveRange: (1, 25))
    var seconds: Int

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let log = Logger(subsystem: "com.holo.app", category: "ReceiptBookingProbe")
        let started = Date()
        log.notice("probe start requestedSeconds=\(self.seconds)")
        // 系统取消（用户停止快捷指令/超时）会让 sleep 抛 CancellationError，
        // 探针以失败结束——这正是要观察的行为之一
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        let elapsed = Int(Date().timeIntervalSince(started).rounded())
        log.notice("probe done requestedSeconds=\(self.seconds) elapsedSeconds=\(elapsed)")
        return .result(value: "探针完成：请求 \(seconds) 秒，实际 \(elapsed) 秒")
    }
}

#endif
