//
//  DomainCapability.swift
//  Holo
//
//  理解引擎 M2.1：七域能力目录（07-M2施工图）。
//
//  「七域都能接入」≠「每域支持所有查证操作」：取证路由（M2.3）按本目录判定，
//  不支持的请求返回 capabilityUnavailable，不生成占位数据（工程稿 §3.3）。
//

import Foundation

/// 查证操作（工程稿 §3.3 七种）。模型只能请求这些；请求字段必须来自能力目录。
nonisolated enum EvidenceOp: String, Codable, Sendable, CaseIterable, Equatable {
    case retrieveRelated      // 查同主题原记录/原话/归属
    case checkOwnership       // 区分本人/代购/他人/未知
    case comparePeriods       // 当前与个人历史比较
    case compareConditions    // 两可比条件下的结果对比
    case alignEvents          // 行为与当晚/后续阶段对齐
    case searchCounterEvidence// 反例/替代解释/偏离样例
    case checkCoverage        // 比较是否有资格进行
}

/// 覆盖语义：各域「无数据」的已知原因类别（checkCoverage 判定用）。
nonisolated enum CoverageSemantics: String, Codable, Sendable, Equatable {
    case healthkitOpaque      // HealthKit 不披露授权状态 → unavailableUnknown
    case deviceBounded        // 读数依赖佩戴/设备在位
    case manualEntry          // 手动记录，缺勤≠未发生
    case autoSync             // 自动同步，缺勤大概率=未发生
}

/// 单域能力声明。版本随投影器/查证实现升级递增。
nonisolated struct DomainCapability: Codable, Sendable, Equatable {
    var domain: ObservationDomain
    var version: Int
    /// 该域能提供的语义字段（capability 目录用，M2.3 判 support）。
    var supportedFields: [String]
    var timePrecision: ObservationTimePrecision
    var coverageSemantics: [CoverageSemantics]
    var supportedOperations: [EvidenceOp]

    func supports(_ op: EvidenceOp) -> Bool { supportedOperations.contains(op) }
}

/// 七域目录（样板期）：finance/thought 为首批真接入；其余域先登记保守能力（空 op），
/// 防止「未登记=默认全支持」的隐性放水——M2.3 路由对未登记 op 一律 capabilityUnavailable。
nonisolated enum DomainCapabilityCatalog {
    static let finance = DomainCapability(
        domain: .finance,
        version: 1,
        supportedFields: ["concept", "action", "attribution", "occurredAt", "recordedAt", "note"],
        timePrecision: .minute,
        coverageSemantics: [.manualEntry],
        supportedOperations: [.retrieveRelated, .checkOwnership, .comparePeriods, .compareConditions, .alignEvents, .searchCounterEvidence]
    )

    static let thought = DomainCapability(
        domain: .thought,
        version: 1,
        supportedFields: ["quote", "recordedAt"],
        timePrecision: .minute,
        coverageSemantics: [.manualEntry],
        supportedOperations: [.retrieveRelated, .searchCounterEvidence]
    )

    static let health = DomainCapability(
        domain: .health,
        version: 1,
        supportedFields: [], // 数值/序列留本机，M2.1 样板期不声明（待 M2.3 真接通时登记）
        timePrecision: .minute,
        coverageSemantics: [.healthkitOpaque, .deviceBounded],
        supportedOperations: [] // 样板期待接：comparePeriods/alignEvents/checkCoverage
    )

    static let placeholder = DomainCapability(
        domain: .task,
        version: 0,
        supportedFields: [],
        timePrecision: .unknown,
        coverageSemantics: [],
        supportedOperations: []
    )

    /// 目录查询：未登记域返回 nil（路由层转 capabilityUnavailable）。
    static func capability(for domain: ObservationDomain) -> DomainCapability? {
        switch domain {
        case .finance: return finance
        case .thought: return thought
        case .health: return health
        case .task, .habit, .goal, .chat: return nil
        }
    }
}
