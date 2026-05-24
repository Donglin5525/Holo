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

            let candidate = HoloLongTermMemory(
                id: "candidate-\(insightID)-\(cardID)",
                type: .recurringPattern,
                title: title,
                summary: summary,
                confidence: evidence.count >= 2 ? .medium : .low,
                confirmationState: .candidate,
                sensitivity: classifySensitivity(title: title, summary: summary),
                evidence: evidence,
                createdAt: Date(),
                updatedAt: Date(),
                expiresAt: nil
            )

            candidates.append(candidate)
        }

        // 候选进入晋升策略
        for candidate in candidates {
            let decision = HoloMemoryPromotionPolicy.evaluate(candidate: candidate)
            switch decision {
            case .discard(let reason):
                logger.info("丢弃候选 \(candidate.id)：\(reason)")
            case .observe(let reason):
                logger.info("观察候选 \(candidate.id)：\(reason)")
                HoloLongTermMemoryStore.upsertCandidate(candidate)
            case .silentlyAccept(let reason):
                logger.info("静默写入 \(candidate.id)：\(reason)")
                var accepted = candidate
                accepted.confirmationState = .silentlyAccepted
                HoloLongTermMemoryStore.upsertCandidate(accepted)
            case .requireConfirmation(let reason):
                logger.info("要求确认 \(candidate.id)：\(reason)")
                HoloLongTermMemoryStore.upsertCandidate(candidate)
            }
        }

        logger.info("从洞察 \(insightID) 提取了 \(candidates.count) 个候选")
    }

    // MARK: - Sensitivity Classification

    private static func classifySensitivity(title: String, summary: String) -> HoloMemorySensitivity {
        let sensitiveKeywords = ["焦虑", "抑郁", "压力", "心理", "人格", "身份", "关系", "分手", "离婚", "债务"]
        let text = title + summary
        for keyword in sensitiveKeywords {
            if text.contains(keyword) {
                return .sensitive
            }
        }
        return .normal
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let memoryInsightDidGenerate = Notification.Name("memoryInsightDidGenerate")
}
