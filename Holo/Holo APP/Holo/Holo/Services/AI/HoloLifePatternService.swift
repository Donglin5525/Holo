//
//  HoloLifePatternService.swift
//  Holo
//
//  生活模式持久化与摘要注入服务。首版只接受稳定信号，避免单次异常被长期化。
//

import Foundation
import os.log

final class HoloLifePatternService {
    static let shared = HoloLifePatternService()

    private static let logger = Logger(subsystem: "com.holo.app", category: "HoloLifePattern")
    private let minEvidenceCount = 2

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holo", isDirectory: true)
        return dir.appendingPathComponent("HoloLifePatternModel.json")
    }()

    private(set) var model: HoloLifePatternModel

    private init() {
        model = Self.loadFromDisk(fileURL: fileURL) ?? .empty()
    }

    func recordLowValueTopic(patternType: String, summary: String, evidenceCount: Int, source: LifePatternSource = .insightFeedback) {
        guard evidenceCount >= minEvidenceCount else { return }
        upsert(
            key: patternType,
            summary: summary,
            evidenceCount: evidenceCount,
            confidence: min(0.9, 0.45 + Double(evidenceCount) * 0.12),
            source: source,
            bucket: \.lowValueTopics
        )
    }

    func recordPressurePattern(key: String, summary: String, evidenceCount: Int, source: LifePatternSource) {
        guard evidenceCount >= minEvidenceCount else { return }
        upsert(
            key: key,
            summary: summary,
            evidenceCount: evidenceCount,
            confidence: min(0.85, 0.4 + Double(evidenceCount) * 0.12),
            source: source,
            bucket: \.pressurePatterns
        )
    }

    func promptSummary(for scenario: HoloLifePatternInjectionScenario) -> String? {
        guard scenario.allowsInjection else { return nil }

        var lines: [String] = []
        lines += model.pressurePatterns.prefix(3).map { "容易波动：\($0.summary)" }
        lines += model.recoveryPatterns.prefix(2).map { "恢复方式：\($0.summary)" }
        lines += model.effectiveInterventionStyles.prefix(2).map { "有效建议方式：\($0.summary)" }
        lines += model.lowValueTopics.prefix(3).map { "低价值主题：\($0.summary)" }

        guard !lines.isEmpty else { return nil }
        return "生活模式摘要：\n- " + lines.joined(separator: "\n- ") + "\n规则：这些模式只能辅助理解，不能覆盖用户当前明确输入。"
    }

    private func upsert(
        key: String,
        summary: String,
        evidenceCount: Int,
        confidence: Double,
        source: LifePatternSource,
        bucket: WritableKeyPath<HoloLifePatternModel, [LifePatternEntry]>
    ) {
        if let index = model[keyPath: bucket].firstIndex(where: { $0.key == key }) {
            model[keyPath: bucket][index].summary = summary
            model[keyPath: bucket][index].evidenceCount += evidenceCount
            model[keyPath: bucket][index].confidence = max(model[keyPath: bucket][index].confidence, confidence)
            model[keyPath: bucket][index].lastSeenAt = Date()
        } else {
            model[keyPath: bucket].append(LifePatternEntry(
                key: key,
                summary: summary,
                evidenceCount: evidenceCount,
                confidence: confidence,
                lastSeenAt: Date(),
                source: source
            ))
        }
        model.updatedAt = Date()
        saveToDisk()
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(model) else {
            Self.logger.error("生活模式编码失败")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadFromDisk(fileURL: URL) -> HoloLifePatternModel? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(HoloLifePatternModel.self, from: data)
    }
}

enum HoloLifePatternInjectionScenario {
    case userAsksRecentState
    case memoryInsightGeneration
    case retrospective
    case explicitAdvice
    case intentRecognition
    case execution
    case flexibleQueryPlanner

    var allowsInjection: Bool {
        switch self {
        case .userAsksRecentState, .memoryInsightGeneration, .retrospective, .explicitAdvice:
            return true
        case .intentRecognition, .execution, .flexibleQueryPlanner:
            return false
        }
    }
}

