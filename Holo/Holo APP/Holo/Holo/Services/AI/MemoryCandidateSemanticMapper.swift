//
//  MemoryCandidateSemanticMapper.swift
//  Holo
//
//  LLM 记忆候选输出 → HoloLongTermMemory 候选的本地校验与转换
//  校验 semanticType、补默认值、降级处理
//

import Foundation
import os.log

enum MemoryCandidateSemanticMapper {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryCandidateMapper")

    // 允许输出 memoryCandidate 的卡片类型
    private static let eligibleCardTypes: Set<MemoryInsightCardType> = [
        .habit, .finance, .task, .milestone
    ]

    // MARK: - 主入口：校验 LLM 输出并转换为 HoloLongTermMemory 候选

    /// 校验 LLM 输出并转换为 HoloLongTermMemory 候选
    /// - Returns: 合法候选返回 HoloLongTermMemory，非法或不应晋升返回 nil
    static func validateAndMap(
        candidate: MemoryCandidatePayload,
        card: MemoryInsightCard,
        evidence: [HoloLongTermMemoryEvidence]
    ) -> HoloLongTermMemory? {
        // 1. 卡片类型检查
        guard eligibleCardTypes.contains(card.type) else {
            logger.info("卡片类型 \(card.type.rawValue) 不允许晋升，跳过")
            return nil
        }

        // 2. semanticType 校验
        guard let semanticType = HoloMemorySemanticType(rawValue: candidate.semanticType) else {
            logger.warning("非法 semanticType: \(candidate.semanticType)，丢弃候选 \(card.id)")
            return nil
        }

        guard let subjectKey = HoloSemanticMemoryIdentity.normalizeSubjectKey(candidate.subjectKey) else {
            logger.warning("非法 subjectKey: \(candidate.subjectKey)，丢弃候选 \(card.id)")
            return nil
        }

        guard shouldPromote(semanticType: semanticType, card: card, candidate: candidate, evidenceCount: evidence.count) else {
            logger.info("候选 \(card.id) 不满足语义晋升边界，跳过")
            return nil
        }

        // 3. 摘要降级
        let displaySummary = candidate.displaySummary.isEmpty
            ? card.body
            : candidate.displaySummary
        let aiUseSummary = candidate.aiUseSummary.isEmpty
            ? displaySummary
            : candidate.aiUseSummary

        // 4. 构建候选
        let useScopes = defaultUseScopes(for: semanticType)
        let sensitivity = resolveSensitivity(
            llmValue: nil,
            localKeywords: classifySensitivity(title: card.title, summary: displaySummary)
        )
        let prohibitedInferences = defaultProhibitedInferences(
            for: semanticType,
            sensitivity: sensitivity
        )
        let confidence = resolveConfidence(
            llmValue: nil,
            evidenceCount: evidence.count
        )

        return HoloLongTermMemory(
            id: HoloSemanticMemoryIdentity.makeID(
                semanticType: semanticType,
                domain: card.type.rawValue,
                subjectKey: subjectKey
            ),
            subjectKey: subjectKey,
            title: card.title,
            confidence: confidence,
            confirmationState: .candidate,
            sensitivity: sensitivity,
            evidence: evidence,
            createdAt: Date(),
            updatedAt: Date(),
            expiresAt: defaultExpiresAt(for: semanticType),
            semanticType: semanticType,
            displaySummary: displaySummary,
            aiUseSummary: aiUseSummary,
            useScopes: useScopes,
            prohibitedInferences: prohibitedInferences
        )
    }

    // MARK: - 默认值映射

    /// semanticType → useScopes 默认映射
    static func defaultUseScopes(for type: HoloMemorySemanticType) -> [HoloMemoryUseScope] {
        switch type {
        case .phaseShift:
            return [.coreContext, .recentInsight, .goalPlanning]
        case .stablePattern:
            return [.coreContext, .recentInsight]
        case .driftSignal:
            return [.recentInsight]
        case .lifeEvent:
            return [.coreContext, .goalPlanning, .retrospective]
        case .statMilestone:
            return [.displayOnly, .retrospective]
        }
    }

    static func shouldPromote(
        semanticType: HoloMemorySemanticType,
        card: MemoryInsightCard,
        candidate: MemoryCandidatePayload,
        evidenceCount: Int
    ) -> Bool {
        let text = "\(card.title) \(card.body) \(candidate.displaySummary) \(candidate.aiUseSummary)"
        let mixedMarkers = ["同时", "并且", "以及", "支出偏高", "消费偏高", "任务清零"]
        let looksMixed = mixedMarkers.filter { text.contains($0) }.count >= 2
        if looksMixed { return false }

        if card.type == .crossDomain || card.type == .overview || card.type == .anomaly {
            return false
        }

        switch semanticType {
        case .phaseShift:
            return evidenceCount >= 2 && !isSingleDaySpike(text)
        case .stablePattern:
            return evidenceCount >= 3
        case .driftSignal:
            return evidenceCount >= 2
        case .lifeEvent:
            return evidenceCount >= 1
        case .statMilestone:
            return evidenceCount >= 1
        }
    }

    static func defaultExpiresAt(for type: HoloMemorySemanticType) -> Date? {
        switch type {
        case .driftSignal:
            return Calendar.current.date(byAdding: .day, value: 30, to: Date())
        case .phaseShift, .stablePattern, .lifeEvent, .statMilestone:
            return nil
        }
    }

    /// semanticType + sensitivity → prohibitedInferences 默认映射
    static func defaultProhibitedInferences(
        for type: HoloMemorySemanticType,
        sensitivity: HoloMemorySensitivity
    ) -> [String] {
        var inferences: [String] = []
        switch type {
        case .phaseShift:
            inferences.append("不要在没有新证据时假设变化仍在持续")
        case .stablePattern:
            inferences.append("不要表述为强制偏好")
            inferences.append("不要在没有后续证据时推断一直持续")
        case .driftSignal:
            inferences.append("不要归因为懒惰、放弃或失败")
            inferences.append("不要假设用户不再关注该目标")
        case .lifeEvent:
            inferences.append("不要主动暴露敏感细节除非用户话题相关")
        case .statMilestone:
            inferences.append("不用于推断用户当前效率或性格")
        }

        // 敏感数据追加额外边界
        if sensitivity == .sensitive {
            inferences.append("不要在非相关场景主动提及")
        }

        return inferences
    }

    /// 合并 confidence：LLM 优先，缺失时按 evidence 数量 fallback
    static func resolveConfidence(
        llmValue: HoloMemoryConfidence?,
        evidenceCount: Int
    ) -> HoloMemoryConfidence {
        if let llm = llmValue { return llm }

        if evidenceCount >= 3 { return .high }
        if evidenceCount >= 2 { return .medium }
        return .low
    }

    /// 合并 sensitivity：LLM 值为基准，本地关键词只允许升级
    static func resolveSensitivity(
        llmValue: HoloMemorySensitivity?,
        localKeywords: HoloMemorySensitivity
    ) -> HoloMemorySensitivity {
        guard let llm = llmValue else { return localKeywords }

        // 本地只允许升级，不允许降级
        let order: [HoloMemorySensitivity] = [.normal, .highImpact, .sensitive]
        let llmIndex = order.firstIndex(of: llm) ?? 0
        let localIndex = order.firstIndex(of: localKeywords) ?? 0

        return order[max(llmIndex, localIndex)]
    }

    // MARK: - 本地敏感性分类

    /// 基于关键词的本地敏感性分类
    static func classifySensitivity(title: String, summary: String) -> HoloMemorySensitivity {
        let sensitiveKeywords = [
            "焦虑", "抑郁", "压力", "心理", "人格", "身份",
            "关系", "分手", "离婚", "债务", "疾病", "治疗"
        ]
        let highImpactKeywords = [
            "收入", "工资", "薪资", "离职", "跳槽", "升职", "结婚"
        ]
        let text = title + summary

        for keyword in sensitiveKeywords {
            if text.contains(keyword) { return .sensitive }
        }
        for keyword in highImpactKeywords {
            if text.contains(keyword) { return .highImpact }
        }
        return .normal
    }

    private static func isSingleDaySpike(_ text: String) -> Bool {
        let spikeWords = ["单日", "今天", "一天", "突增", "偏高", "多花"]
        return spikeWords.filter { text.contains($0) }.count >= 2
    }
}
