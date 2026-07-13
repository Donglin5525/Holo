//
//  HoloLongTermMemoryCandidateObserver.swift
//  Holo
//
//  监听 MemoryInsight 生成事件，异步提取长期记忆候选
//  通知携带 card 数据，避免后台线程访问 Core Data
//

import Foundation
import os.log

enum HoloLongTermMemoryCandidateObserver {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MemoryCandidateObserver")
    private static var observer: NSObjectProtocol?

    // MARK: - Start Observing

    static func startObserving() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: .memoryInsightDidGenerate,
            object: nil,
            queue: OperationQueue()
        ) { notification in
            guard let insightID = notification.userInfo?["insightID"] as? String,
                  let cards = notification.userInfo?["cards"] as? [[String: Any]] else { return }
            extractCandidates(from: insightID, cards: cards)
        }
    }

    static func stopObserving() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }

    // MARK: - Extract Candidates

    private static func extractCandidates(from insightID: String, cards: [[String: Any]]) {
        guard HoloAIFeatureFlags.memoryInsightCandidateExtractionEnabled else { return }

        logger.info("开始从洞察 \(insightID) 提取长期记忆候选")

        var candidates: [HoloLongTermMemory] = []

        for cardData in cards {
            guard let cardID = cardData["id"] as? String,
                  let title = cardData["title"] as? String,
                  let summary = cardData["summary"] as? String,
                  let patternType = cardData["patternType"] as? String,
                  !patternType.isEmpty,
                  let evidenceData = cardData["evidence"] as? [[String: String]],
                  !evidenceData.isEmpty else { continue }

            let evidence = evidenceData.enumerated().map { index, ev -> HoloLongTermMemoryEvidence in
                HoloLongTermMemoryEvidence(
                    id: "\(insightID)-\(cardID)-ev\(index)",
                    source: .memoryInsight,
                    sourceID: ev["sourceID"],
                    excerpt: ev["excerpt"] ?? "",
                    observedAt: Date()
                )
            }

            guard let mcData = cardData["memoryCandidate"] as? [String: String],
                  let subjectKey = mcData["subjectKey"],
                  let semanticType = mcData["semanticType"],
                  let displaySummary = mcData["displaySummary"],
                  let aiUseSummary = mcData["aiUseSummary"] else {
                logger.info("卡片 \(cardID) 没有完整新格式 memoryCandidate，跳过")
                continue
            }

            let mcPayload = MemoryCandidatePayload(
                subjectKey: subjectKey,
                semanticType: semanticType,
                displaySummary: displaySummary,
                aiUseSummary: aiUseSummary
            )

            let cardTypeRaw = cardData["cardType"] as? String ?? "habit"
            let cardType = MemoryInsightCardType(rawValue: cardTypeRaw) ?? .habit
            let tempCard = MemoryInsightCard(
                id: cardID,
                type: cardType,
                title: title,
                body: summary,
                evidence: [],
                suggestedQuestion: nil,
                memoryCandidate: mcPayload
            )

            guard let mapped = MemoryCandidateSemanticMapper.validateAndMap(
                candidate: mcPayload,
                card: tempCard,
                evidence: evidence
            ) else {
                logger.info("Mapper 丢弃不合格新格式候选 \(cardID)")
                continue
            }
            candidates.append(mapped)
        }

        // 候选进入晋升策略
        for candidate in candidates {
            // driftSignal 自动设置 21 天过期
            var processedCandidate = candidate
            if candidate.semanticType == .driftSignal && candidate.expiresAt == nil {
                processedCandidate.expiresAt = Calendar.current.date(byAdding: .day, value: 21, to: Date())
            }

            // statMilestone 强制 useScopes 为 displayOnly
            if candidate.semanticType == .statMilestone {
                processedCandidate.useScopes = [.displayOnly, .retrospective]
            }

            let decision = HoloMemoryPromotionPolicy.evaluate(candidate: processedCandidate)
            switch decision {
            case .discard(let reason):
                logger.info("丢弃候选 \(processedCandidate.id)：\(reason)")
            case .observe(let reason):
                logger.info("观察候选 \(processedCandidate.id)：\(reason)")
                HoloLongTermMemoryStore.upsertCandidate(processedCandidate)
            case .silentlyAccept(let reason):
                logger.info("静默写入 \(processedCandidate.id)：\(reason)")
                var accepted = processedCandidate
                accepted.confirmationState = .silentlyAccepted
                HoloLongTermMemoryStore.upsertCandidate(accepted)
            case .requireConfirmation(let reason):
                logger.info("要求确认 \(processedCandidate.id)：\(reason)")
                HoloLongTermMemoryStore.upsertCandidate(processedCandidate)
            }
        }

        logger.info("从洞察 \(insightID) 提取了 \(candidates.count) 个候选")
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let memoryInsightDidGenerate = Notification.Name("memoryInsightDidGenerate")
}
