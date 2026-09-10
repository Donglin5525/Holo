//
//  ThoughtTopicLink+CoreDataClass.swift
//  Holo
//
//  想法-主题显式关系实体（语义图谱 V3 Phase 1）
//  取代 Thought.topics 裸多对多作为长期事实源：表达来源、状态、可见性、
//  正文版本与用户反馈；旧 relationship 迁移期保留并双写（方案 §7.1/§18）。
//

import CryptoKit
import CoreData
import Foundation

@objc(ThoughtTopicLink)
class ThoughtTopicLink: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<ThoughtTopicLink> {
        NSFetchRequest<ThoughtTopicLink>(entityName: "ThoughtTopicLink")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    /// 关系来源：谁建立了这条关系。user/manual、user/acceptedSuggestion、
    /// ai/v3（V3 引擎）、legacy/ai（V2 及更早 AI 通道）、legacy/unknown（存量迁移无法判定）
    @NSManaged var source: String
    /// active / rejected（用户拒绝墓碑）/ superseded（被新版本取代）
    @NSManaged var state: String
    /// internal（仅内部索引）/ weakVisible（卡片弱展示）/ userVisible（用户确认）
    @NSManaged var visibility: String
    /// 建立关系时的正文版本；正文变更后 AI 关系失效（用户关系为空）
    @NSManaged var basisTextHash: String?
    @NSManaged var engineVersion: String?
    /// high/medium/low 决策分层（本地多信号裁决结果，非模型自报 confidence）
    @NSManaged var decisionTier: String?
    /// 本地可解释证据范围（禁止复制整段原文）
    @NSManaged var evidenceRange: String?
    /// 授权代数：撤回授权后旧 generation 的迟到结果落库前作废
    @NSManaged var consentGeneration: Int64
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var rejectedAt: Date?

    // MARK: - Relationships

    @NSManaged var thought: Thought?
    @NSManaged var topic: Topic?
}

// MARK: - 枚举与判定

extension ThoughtTopicLink {

    enum LinkSource: String {
        case userManual = "user/manual"
        case userAcceptedSuggestion = "user/acceptedSuggestion"
        case aiV3 = "ai/v3"
        case legacyAI = "legacy/ai"
        case legacyUnknown = "legacy/unknown"
    }

    enum LinkState: String {
        case active
        case rejected
        case superseded
    }

    enum LinkVisibility: String {
        case internalOnly = "internal"
        case weakVisible
        case userVisible
    }

    var sourceEnum: LinkSource {
        get { LinkSource(rawValue: source) ?? .legacyUnknown }
        set { source = newValue.rawValue }
    }

    var stateEnum: LinkState {
        get { LinkState(rawValue: state) ?? .active }
        set { state = newValue.rawValue }
    }

    var visibilityEnum: LinkVisibility {
        get { LinkVisibility(rawValue: visibility) ?? .internalOnly }
        set { visibility = newValue.rawValue }
    }

    /// 用户决定（手动或接受建议）。优先级最高，AI 不可覆盖（方案核心不变量 3）。
    var isUserDecision: Bool {
        let s = sourceEnum
        return s == .userManual || s == .userAcceptedSuggestion
    }

    /// 确定性 ID：同一 (thoughtID, topicID) 组合在任何设备上生成相同 UUID，
    /// 防止 CloudKit 多设备产生重复 pair（方案 §7.1/§15）。
    static func deterministicID(thoughtID: UUID, topicID: UUID) -> UUID {
        var payload = Data(capacity: 32)
        withUnsafeBytes(of: thoughtID.uuid) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: topicID.uuid) { payload.append(contentsOf: $0) }
        let digest = SHA256.hash(data: payload)
        var bytes = [UInt8](digest.prefix(16))
        // RFC 4122 version/variant 位设为随机型 UUID，避免被当作其他版本解析
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// 同 pair 并存多行时的投影优先级（数值小者胜，方案 §7.1）：
    /// user active > user rejected 墓碑 > ai/v3 active > legacy active > 其他。
    /// rejected 墓碑压过同 pair 的 AI active 是「用户移除后 AI 不得重建」的落地。
    var projectionRank: Int {
        switch (sourceEnum, stateEnum) {
        case (.userManual, .active), (.userAcceptedSuggestion, .active):
            return 0
        case (_, .rejected):
            return 1
        case (.aiV3, .active):
            return 2
        case (.legacyAI, .active), (.legacyUnknown, .active):
            return 3
        default:
            return 4
        }
    }
}

// MARK: - Relationships Accessors

extension ThoughtTopicLink {
    // to-one 关系无需集合 accessor；两端对象访问用 thought / topic。
}
