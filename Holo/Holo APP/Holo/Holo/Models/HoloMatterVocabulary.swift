//
//  HoloMatterVocabulary.swift
//  Holo
//
//  Matter「进行中的事」词汇层：纯枚举与工具，无外部依赖。
//
//  单独成文件的原因：HoloWidgets target 共享 Core Data 模型（createDataModel），
//  实体工厂依赖这些枚举做默认值；词汇层不含 HoloContextPlanDraft 等 app 侧类型，
//  可安全同时挂进主 app 与 widget 两个 target。
//

import Foundation

// MARK: - 生命周期

/// 生命周期。合法迁移见 `canTransition(to:)`；系统不得自动触发 candidate→active 或 active→completed。
nonisolated enum HoloMatterLifecycleStatus: String, Codable, CaseIterable, Sendable {
    case candidate
    case active
    case completed
    case archived
    case dismissed

    /// 合法迁移表（方案 §5.1）。非法迁移一律拒绝，由 Repository 抛错。
    func canTransition(to target: HoloMatterLifecycleStatus) -> Bool {
        switch (self, target) {
        case (.candidate, .active),
             (.candidate, .dismissed),
             (.active, .completed),
             (.completed, .active),
             (.completed, .archived),
             (.archived, .active):
            return true
        default:
            return false
        }
    }
}

// MARK: - 进行阶段

/// 进行阶段。Matter 可处于 .doing 同时包含某个 .waiting 的 Open Loop——局部等待不代表整体等待。
nonisolated enum HoloMatterPhase: String, Codable, CaseIterable, Sendable {
    case planning
    case doing
    case waiting

    var displayLabel: String {
        switch self {
        case .planning: return String(localized: "规划中")
        case .doing: return String(localized: "进行中")
        case .waiting: return String(localized: "等待中")
        }
    }
}

// MARK: - 关注状态

/// 关注状态。唯一计算入口是 `HoloMatterAttentionPolicy`（确定性规则）；模型只能给出解释文字。
nonisolated enum HoloMatterAttention: String, Codable, CaseIterable, Sendable {
    case onTrack
    case needsAttention
    case atRisk
    case waiting
    case unknown
}

// MARK: - Open Loop 词汇

/// 认识论状态：问题是被用户确认过的，还是 AI 猜的。二者在 UI 上永远分开展示。
nonisolated enum HoloMatterOpenLoopEpistemic: String, Codable, CaseIterable, Sendable {
    case confirmed
    case suggested
}

nonisolated enum HoloMatterOpenLoopState: String, Codable, CaseIterable, Sendable {
    case open
    case waiting
    case resolved
    case dismissed
}

nonisolated enum HoloMatterOpenLoopPriority: String, Codable, CaseIterable, Sendable {
    case critical
    case high
    case normal
    case low
}

// MARK: - Link 词汇

/// 跨域链接类型白名单。首版只启用前四个；其余预留但不产生数据。
nonisolated enum HoloMatterLinkEntityType: String, Codable, CaseIterable, Sendable {
    case contextPlan
    case chatMessage
    case todoTask
    case thought
    // 预留不开启（方案 §9.1）：
    case transaction
    case calendarEvent
    case memory
    case goal
    case habit
    case webResource

    /// 首版允许写入的白名单。
    static var writable: [HoloMatterLinkEntityType] {
        [.contextPlan, .chatMessage, .todoTask, .thought]
    }
}

nonisolated enum HoloMatterLinkRole: String, Codable, CaseIterable, Sendable {
    case evidence
    case action
    case resource
    case conversation
    case origin
}

nonisolated enum HoloMatterLinkOrigin: String, Codable, CaseIterable, Sendable {
    case explicit
    case inferred
    case system
}

nonisolated enum HoloMatterLinkStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case linked
    case rejected
    case unlinked
}

// MARK: - Event 词汇

nonisolated enum HoloMatterActor: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
    case system
}

/// 事件种类。最近变化列表只读事件流，不从当前状态倒推。
nonisolated enum HoloMatterEventKind: String, Codable, CaseIterable, Sendable {
    case activated
    case titleChanged
    case openLoopAdded
    case openLoopConfirmed
    case openLoopResolved
    case openLoopDismissed
    case openLoopReopened
    case linkAdded
    case linkRemoved
    case projectionRefreshed
    case completed
    case archived
    case reopened
    case reverted
}

// MARK: - Matter 来源

nonisolated enum HoloMatterOrigin: String, Codable, CaseIterable, Sendable {
    case contextPlan
    case manual
    case suggestion
}

// MARK: - 幂等键

/// 幂等键生成（方案 §10.2）。重复动作必须返回同一结果而非创建副本。
nonisolated enum HoloMatterIdempotencyKey {
    static func activate(contextPlanMessageID: UUID) -> String {
        "activate:\(contextPlanMessageID.uuidString)"
    }

    static func link(matterID: UUID, entityType: HoloMatterLinkEntityType, entityID: String) -> String {
        "link:\(matterID.uuidString):\(entityType.rawValue):\(entityID)"
    }

    static func resolve(matterID: UUID, openLoopID: UUID, sourceRevision: String) -> String {
        "resolve:\(matterID.uuidString):\(openLoopID.uuidString):\(sourceRevision)"
    }
}

// MARK: - JSON 编解码辅助

extension JSONEncoder {
    /// Matter 域统一编码器：ISO8601 日期，稳定输出。
    static let holoMatter: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    /// Matter 域统一解码器。未知字段忽略；未知枚举由调用方用 `decodeMatterEnum` 兜底。
    static let holoMatter: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 解码可能含未知 raw 值的枚举：未知值回落到 fallback，不启动崩溃（方案 §15.4）。
nonisolated func decodeMatterEnum<T: RawRepresentable & CaseIterable>(_ type: T.Type, from raw: String?, fallback: T) -> T
where T.RawValue == String {
    guard let raw else { return fallback }
    return T(rawValue: raw) ?? fallback
}

// MARK: - schema 默认值

/// schema 层面默认值（仅满足 CloudKit 非空约束；语义真值由 Repository 显式写入）。
nonisolated enum MatterSchemaDefaults {
    static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
