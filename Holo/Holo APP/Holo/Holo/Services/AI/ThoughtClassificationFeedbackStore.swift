//
//  ThoughtClassificationFeedbackStore.swift
//  Holo
//
//  P1 分类反馈事件（方案 §4.3）：记录用户对 AI 建议的确认/拒绝/治理动作，
//  作为一切算法升级（含 P2 语义候选评估）的本地验收地基。
//  存储：Application Support 下受数据保护 JSON（对齐 V3 缓存范式），不进 Core Data/CloudKit、不外发；
//  上限 2000 条 LRU；文件损坏直接丢弃重建。
//

import Foundation

/// P2 语义候选三档模式（off 不计算 / shadow 计算记录不注入 / inject 注入）。
/// 定义于此使 FeedbackStore 可独立编译（standalone 测试）；引擎侧直接引用。
nonisolated enum ThoughtSemanticCandidateMode: String, CaseIterable {
    case off
    case shadow
    case inject

    static let storageKey = "thoughtAI.semanticCandidates.mode"

    static var current: ThoughtSemanticCandidateMode {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? off.rawValue
        return ThoughtSemanticCandidateMode(rawValue: raw) ?? .off
    }
}

/// 反馈事件（ Codable 落盘结构）
struct ThoughtClassificationFeedbackEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let thoughtId: UUID
    /// 归一化标签 key（主题类动作记录主题名 key）
    let tagKey: String
    let action: ThoughtClassificationFeedbackAction
    /// 动作发生时该标签是否已为用户认可标签（对 ai 建议的动作恒为 false）
    let wasRecognizedTag: Bool
    /// 建议时的主题置信度（若有）
    let topicConfidence: Double?
    /// P2：本次建议是否注入了语义候选
    let semanticCandidatesUsed: Bool
    let occurredAt: Date
    let policyVersion: Int
}

enum ThoughtClassificationFeedbackAction: String, Codable, Sendable {
    case confirm            // 保留标签（ai → confirmedAI）
    case rejectCurrent      // 仅本条不适合
    case suppressGlobal     // 以后不要推荐（全局抑制）
    case rename             // 改名后采用
    case merge              // 合并到已有标签
    case deleteGlobal       // 全局删除
    case topicConfirm       // 低置信主题「放这里」
    case topicChange        // 手动更换主题
    case retry              // 重新整理
}

actor ThoughtClassificationFeedbackStore {

    static let shared = ThoughtClassificationFeedbackStore()
    static let maxEvents = 2000

    private let fileURL: URL
    private var events: [ThoughtClassificationFeedbackEvent] = []
    private var loaded = false

    /// - Parameter directory: 落盘目录（默认 Application Support/ThoughtAI；测试注入临时目录）
    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ThoughtAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("classification-feedback.json")
    }

    // MARK: - 写入

    func append(_ event: ThoughtClassificationFeedbackEvent) {
        loadIfNeeded()
        events.append(event)
        if events.count > Self.maxEvents {
            events = Array(events.suffix(Self.maxEvents))
        }
        persist()
    }

    /// 便捷打点（UI 动作处调用；fire-and-forget，不阻塞主线程）
    /// semanticCandidatesUsed 默认按打点时的全局语义模式记录（inject=used），供 A/B 分段对比
    static func log(
        _ action: ThoughtClassificationFeedbackAction,
        thoughtId: UUID,
        tagName: String,
        wasRecognizedTag: Bool = false,
        topicConfidence: Double? = nil,
        semanticCandidatesUsed: Bool = ThoughtSemanticCandidateMode.current == .inject
    ) {
        let event = ThoughtClassificationFeedbackEvent(
            id: UUID(),
            thoughtId: thoughtId,
            tagKey: ThoughtTagNormalizer.key(tagName),
            action: action,
            wasRecognizedTag: wasRecognizedTag,
            topicConfidence: topicConfidence,
            semanticCandidatesUsed: semanticCandidatesUsed,
            occurredAt: Date(),
            policyVersion: ThoughtOrganizationPresentationPolicy.version
        )
        Task { await shared.append(event) }
    }

    // MARK: - 读取（Debug 聚合）

    func allEvents() -> [ThoughtClassificationFeedbackEvent] {
        loadIfNeeded()
        return events
    }

    /// 聚合：确认率 = confirm / (confirm + rejectCurrent + suppressGlobal)
    func acceptanceSummary() -> (confirmed: Int, rejected: Int, acceptanceRate: Double) {
        loadIfNeeded()
        let confirmed = events.filter { $0.action == .confirm }.count
        let rejected = events.filter { $0.action == .rejectCurrent || $0.action == .suppressGlobal }.count
        let total = confirmed + rejected
        let rate = total > 0 ? Double(confirmed) / Double(total) : 0
        return (confirmed, rejected, rate)
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ThoughtClassificationFeedbackEvent].self, from: data) else {
            return  // 文件缺失/损坏：从空开始，不视为错误
        }
        events = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL, options: .completeFileProtection)
    }

    /// 删除账户数据时调用（方案 §4.3 隐私规则）
    func destroy() {
        events = []
        loaded = true
        try? FileManager.default.removeItem(at: fileURL)
    }
}
