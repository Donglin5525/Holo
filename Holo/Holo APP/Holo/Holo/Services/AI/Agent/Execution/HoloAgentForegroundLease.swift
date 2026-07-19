//
//  HoloAgentForegroundLease.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 5（§6.3）
//  前台执行租约：App 活跃时的默认租约。前台没有需要向系统申请/释放的资源，
//  App 内状态直接从 Job/Checkpoint 推导，因此 report/finish 均为空操作。
//

import Foundation

/// 前台执行租约（§6.3 实现表的 ForegroundLease）。
nonisolated struct HoloAgentForegroundLease: HoloAgentExecutionLease {
    let kind: HoloAgentExecutionLeaseKind = .foreground

    /// 前台无需上报（系统无前台进度 UI；App 内 UI 直接读 job 状态）
    func report(_ progress: HoloAgentProgressSnapshot) async {}

    /// 前台无系统资源需释放；finish 由 Scheduler 在 job 终态时调用以闭合租约生命周期
    func finish(success: Bool) async {}
}
