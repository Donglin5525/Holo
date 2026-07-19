//
//  HoloAgentExecutionModels.swift
//  Holo
//
//  Holo Agent 稳定执行 — Phase 2（§6.1）
//  Scheduler 唯一执行权的接口模型：启动请求 / 恢复原因 / 取消来源 / 恢复触发 / 暂停原因。
//  注：waitReason 一等公民（HoloAgentWaitReason）属 Phase 3，本批次只建接口签名需要的最小枚举。
//

import Foundation

/// 启动一个新 Agent job 的请求（§6.1 `createAndRun` 入参）。
struct HoloAgentStartRequest: Sendable {
    var question: String
    /// 必须保留真实触发来源；自动任务不得伪装成用户主动任务申请 Continued Processing。
    var trigger: HoloAgentTrigger = .userQuestion
    var systemTemplate: String = ""
    var toolDescriptions: String = ""
    var sourceMessageID: UUID? = nil
    var now: Date = Date()
}

/// 恢复/启动原因（§6.1 `runOrAttach` 入参；只作日志与诊断，不驱动业务分支）。
enum HoloAgentResumeReason: String, Codable, Sendable {
    /// 用户新发起（createAndRun）
    case userInitiated
    /// Observer、定时刷新等自动触发的新任务
    case automaticInitiated
    /// 冷启动 orphan 恢复（进程被杀后带旧 generation 的非终态 job）
    case appLaunch
    /// 回前台/重新进入页面恢复
    case foregroundReturn
    /// 后台执行时间到期后的恢复
    case backgroundExpiryRecovery
}

/// 取消来源（§6.1 `cancel` 入参；用户取消与系统取消不混为一谈）。
enum HoloAgentCancellationSource: String, Codable, Sendable {
    /// 用户主动取消
    case user
    /// 系统回收（后台到期、资源压力等）
    case system
    /// 被新 P0 任务抢占（P0 并发上限 1，旧任务让位）
    case superseded
}

/// 批量恢复触发场景（§6.1 `resumeEligibleJobs` 入参）。
enum HoloAgentResumeTrigger: String, Codable, Sendable {
    case appLaunch
    case foreground

    /// 映射到单 job 的恢复原因（日志用）。
    var resumeReason: HoloAgentResumeReason {
        switch self {
        case .appLaunch: return .appLaunch
        case .foreground: return .foregroundReturn
        }
    }
}

/// 暂停原因（最小集合；Phase 3 并入 HoloAgentWaitReason 一等公民）。
/// 本批次语义效果统一为 `waitingForForeground`（§6.4：只做取消信号 + 状态标记）。
enum HoloAgentPauseReason: String, Codable, Sendable {
    /// 系统后台执行时间到期
    case backgroundTimeExpired
    /// 用户或产品明确暂停
    case userRequested
}

/// 等待原因一等公民（§5.2 Phase 3）：设备锁定、网络断开、等待前台、系统容量不足
/// 不能显示成同一句「暂停」。持久化在 `HoloAgentJob.waitReason`。
enum HoloAgentWaitReason: String, Codable, CaseIterable, Sendable {
    /// 后台执行时间到期（配合 waitingForForeground）
    case backgroundTimeExpired
    /// 设备锁定，HealthKit/受保护数据不可读（配合 waitingForCondition）
    case deviceUnlock
    /// 数据保护类数据暂不可读（配合 waitingForCondition）
    case protectedData
    /// 网络中断，等待恢复（配合 waitingForCondition）
    case network
    /// 系统容量不足（iOS 26 持续处理未获准等）
    case systemCapacity
    /// 用户或产品明确暂停（配合 paused，不自动恢复）
    case userPaused
    /// 输入已变化，被新任务取代（配合 superseded 终态）
    case inputChanged
}
