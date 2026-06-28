//
//  HealthInsightResponseParser.swift
//  Holo
//
//  健康洞察 LLM 响应解析器。
//  把后端返回的宽容 JSON（HealthInsightLLMResponse）转成严格展示模型（GeneratedHealthInsight）。
//  职责：JSON 提取（去围栏）+ evidenceId 同源过滤（防编造）+ title/summary 缺失丢弃。
//  不做质量门禁（confidence 阈值 / 跨域 / 长度 / 禁词）——那是 HealthInsightVerifier（Task 6）的职责。
//

import Foundation

/// 解析结果：一条核心洞察 + 0-N 条生活闭环。
struct HealthInsightParsedInsights: Sendable {
    var coreInsight: GeneratedHealthInsight?
    var lifestyleLoops: [GeneratedHealthInsight]
}

enum HealthInsightParseError: Error, LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "健康洞察 JSON 解析失败：\(detail)"
        }
    }
}

struct HealthInsightResponseParser {

    func parse(_ raw: String, legalEvidenceIds: Set<String>) throws -> HealthInsightParsedInsights {
        let jsonString = Self.extractJSON(from: raw)
        guard let data = jsonString.data(using: .utf8) else {
            throw HealthInsightParseError.invalidJSON("无法转为 UTF-8 数据")
        }

        let response: HealthInsightLLMResponse
        do {
            response = try JSONDecoder().decode(HealthInsightLLMResponse.self, from: data)
        } catch {
            throw HealthInsightParseError.invalidJSON(error.localizedDescription)
        }

        let coreInsight = response.coreInsight.flatMap {
            Self.makeInsight(from: $0, kind: .core, fallbackId: "core", legalEvidenceIds: legalEvidenceIds)
        }

        let loops = (response.lifestyleLoops ?? []).enumerated().compactMap { index, item in
            Self.makeInsight(from: item, kind: .lifestyleLoop, fallbackId: "loop-\(index)", legalEvidenceIds: legalEvidenceIds)
        }

        return HealthInsightParsedInsights(coreInsight: coreInsight, lifestyleLoops: loops)
    }

    // MARK: - Helpers

    private static func makeInsight(
        from item: HealthInsightLLMItem,
        kind: HealthInsightKind,
        fallbackId: String,
        legalEvidenceIds: Set<String>
    ) -> GeneratedHealthInsight? {
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // title/summary 缺失的条目无法展示，丢弃
        guard !title.isEmpty, !summary.isEmpty else {
            return nil
        }

        let trimmedId = item.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = trimmedId.isEmpty ? fallbackId : trimmedId

        // evidenceId 同源过滤：只保留合法集合中的（防 LLM 编造，审查修订 P3）
        let filteredEvidenceIds = (item.evidenceIds ?? []).filter { legalEvidenceIds.contains($0) }

        return GeneratedHealthInsight(
            id: id,
            kind: kind,
            domain: HealthInsightDomain(rawValue: item.domain ?? "") ?? .mixed,
            title: title,
            summary: summary,
            suggestedAction: item.suggestedAction,
            confidence: Self.clampedConfidence(item.confidence),
            evidenceIds: filteredEvidenceIds,
            caveat: item.caveat
        )
    }

    private static func clampedConfidence(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(max(value, 0), 1)
    }

    /// 从可能含 Markdown 围栏（```json ... ```）的文本中提取 JSON。
    private static func extractJSON(from text: String) -> String {
        if let range = text.range(of: "```json") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let range = text.range(of: "```") {
            let afterMarker = text[range.upperBound...]
            if let endRange = afterMarker.range(of: "```") {
                return String(afterMarker[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
