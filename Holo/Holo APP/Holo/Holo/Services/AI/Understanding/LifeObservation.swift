//
//  LifeObservation.swift
//  Holo
//
//  理解引擎 M2.1：尚未被解释的线索（2026-11-13 方案 §2.1 / 07-M2施工图）。
//
//  观察索引是本机可重建的工作材料：原始记录 → 语义投影 → 主题聚类 → 提案取证。
//  它不进 CloudKit、不进正式记忆；来源修订变化即失效重投影。
//

import Foundation

/// 观察来源域。与个人情境分页域（HoloLifeSourceObservation）同轴，外加 profile 由明确表达通道维护。
nonisolated enum ObservationDomain: String, Codable, Sendable, CaseIterable, Equatable {
    case finance, health, thought, task, habit, goal, chat

    var displayName: String {
        switch self {
        case .finance: return "财务"
        case .health: return "健康"
        case .thought: return "想法"
        case .task: return "任务"
        case .habit: return "习惯"
        case .goal: return "目标"
        case .chat: return "对话"
        }
    }
}

/// 时间精度：midnightDefault 不可当真实发生时刻用（M1.2 补账案例的教训固化为类型约束）。
nonisolated enum ObservationTimePrecision: String, Codable, Sendable, Equatable {
    case minute       // 精确到分钟（含秒级记录取整口径）
    case day          // 只知日期
    case window       // 时间段（如「近28天」「转班后7天」）
    case midnightDefault // 系统默认午夜（补账/导入常见，禁止当发生时刻）
    case unknown
}

/// 主体归属：unknown 时不得默认是本人的（M1.6 药名反推病名案例的制度化）。
nonisolated enum ObservationAttribution: String, Codable, Sendable, Equatable {
    case self_ = "self"   // 明确本人（备注/上下文/任务归属）
    case proxy            // 明确代办（「帮X带」「代购」）
    case thirdParty       // 明确他人/第三方
    case unknown
}

/// 业务状态：区分计划/完成/否定/转述/AI派生——派生内容不构成独立证据（M1.1 caseA-counter）。
nonisolated enum ObservationBusinessState: String, Codable, Sendable, Equatable {
    case planned
    case done
    case negation     // 否定/取消/退款
    case quote        // 用户原话（想法/聊天自述）
    case derived      // AI 派生（OCR/摘要/转述）
    case plain        // 普通事件记录
}

/// 覆盖说明：数据可观测情况，供查证资格判定（checkCoverage 的输入）。
nonisolated struct ObservationCoverageNote: Codable, Sendable, Equatable {
    var kind: Kind
    var note: String

    nonisolated enum Kind: String, Codable, Sendable {
        case unavailableUnknown   // 无读数原因未知（HealthKit 不披露授权状态）
        case deviceChanged        // 来源设备更换，口径不可比
        case gap                  // 已知断档
        case batchBackfill        // 批量补账（发生时间≠记录时间）
    }
}

/// 一条未被解释的线索。字段按工程稿 §2.1 六组裁剪为样板期最小集。
nonisolated struct LifeObservation: Codable, Sendable, Equatable, Identifiable {
    /// 稳定标识：domain:sourceRef:revisionDigest 派生（同源同修订幂等）。
    var id: String { "\(domain.rawValue):\(sourceRef):\(sourceRevision)" }

    var domain: ObservationDomain
    /// 原记录可回查 ID（如交易 UUID、Thought UUID）。
    var sourceRef: String
    /// 来源修订摘要：变化即失效，触发重投影。
    var sourceRevision: String
    var sourceKind: String      // transaction/userNote/checkin/goal…（域内细分，投影器自定）
    var occurredAt: Date?       // 实际发生时间；nil = 不可知
    var recordedAt: Date
    var timePrecision: ObservationTimePrecision
    /// 非敏感概念（「猫粮」级，两字也算——不按长度丢弃，M1.1 caseA 教训）。
    var concepts: [String]
    /// 行为语义（购买/照料/打卡/补账/表达…）。
    var action: String?
    var attribution: ObservationAttribution
    var businessState: ObservationBusinessState
    var coverage: ObservationCoverageNote?
    /// 本机原文引用（备注/想法原句）。上送时按授权范围裁剪，不随视图默认外发。
    var quote: String?

    /// 概念是否可上送（语义证据视图的成员资格）：敏感等级样板期由投影器保证——
    /// 金额、精确数值、健康原始值不进 concepts；本类型本身不含任何数值字段。
    var isShareable: Bool { !concepts.isEmpty }
}
