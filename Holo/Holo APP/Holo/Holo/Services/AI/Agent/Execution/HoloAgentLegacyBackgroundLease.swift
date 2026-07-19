//
//  HoloAgentLegacyBackgroundLease.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 5（§6.3/§6.4/§9.6，iOS 17–25 fallback）
//  Legacy 后台租约：包装 `beginBackgroundTask`，**绑定具体 jobID**。
//  - job 完成（finish）立即 `endBackgroundTask` 释放，不等待场景回前台或系统 expiration；
//  - expiration handler 只做三件事（§6.4）：置 expired flag → 通知 Scheduler 取消对应 Task
//    → 尽快调系统完成接口；不承担 checkpoint 保存（正常推进中已持续落盘）。
//

import UIKit
import Foundation

@MainActor
final class HoloAgentLegacyBackgroundLease: HoloAgentExecutionLease {

    let kind: HoloAgentExecutionLeaseKind = .legacyBackground
    /// 绑定的 jobID（scene-sweep 为场景兜底租约的约定 ID，不对应真实 job）
    let jobID: String

    private let client: any HoloBackgroundTaskClient
    private let onExpiration: @Sendable (String) -> Void
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var didExpire = false
    private var didFinish = false

    /// 诊断用：当前是否仍持有系统后台时间
    var isHoldingBackgroundTime: Bool { taskID != .invalid }

    init(jobID: String,
         client: any HoloBackgroundTaskClient,
         onExpiration: @escaping @Sendable (String) -> Void) {
        self.jobID = jobID
        self.client = client
        self.onExpiration = onExpiration
        // 后台任务名只带 jobID 短标识（不含任何用户内容，§7.4 锁屏隐私）
        let shortID = String(jobID.prefix(8))
        self.taskID = client.beginBackgroundTask(named: "HoloAgentJob-\(shortID)") { [weak self] in
            guard let self else { return }
            Task { @MainActor [self] in
                self.expire()
            }
        }
    }

    deinit {
        let taskID = taskID
        let client = client
        guard taskID != .invalid else { return }
        Task { @MainActor in
            client.endBackgroundTask(taskID)
        }
    }

    /// legacy 无系统进度 UI（Phase 6 continued 才需要真实进度上报），空操作。
    func report(_ progress: HoloAgentProgressSnapshot) async {}

    /// job 终态/场景回收：立即释放系统后台时间（§6.3：不等待场景回前台或 expiration）。
    func finish(success: Bool) async {
        endBackgroundTime()
    }

    /// §6.4 expiration 语义：只做——置 expired、通知 Scheduler 取消对应 Task、尽快释放。
    /// 幂等：系统回调与 finish 并发时只生效一次。
    private func expire() {
        guard !didExpire, !didFinish else { return }
        didExpire = true
        onExpiration(jobID)
        endBackgroundTime()
    }

    private func endBackgroundTime() {
        guard taskID != .invalid else { return }
        client.endBackgroundTask(taskID)
        taskID = .invalid
        didFinish = true
    }
}
