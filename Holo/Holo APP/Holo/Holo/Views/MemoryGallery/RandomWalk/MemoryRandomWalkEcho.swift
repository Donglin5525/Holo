//
//  MemoryRandomWalkEcho.swift
//  Holo
//
//  随机漫步的「回看一句」与过场摘句（暖光规格 §5.3）：
//  - 首版本地确定性生成，零网络依赖；最多一句，证据挂到可打开的同日原记录
//  - 过场摘句 = 该日用户原文（带正文想法）里可独立阅读的第一句
//  - 回看一句优先引用用户原文（「你那天写道」）；否则用可证实的事实模板
//    （≥4 条可靠时刻且 18 点后占比 ≥0.65 → 傍晚模板，阈值与
//    DailyReplayPresentation.narrative 的夜间判断同口径）；单笔账单/单次打卡不出句
//  - 不推断情绪、因果、人格或跨领域规律
//

import Foundation

/// 抵达后的「回看一句」：文本 + 证据身份 + 规则版本（编辑/删除后可重验）。
struct MemoryWalkEcho: Equatable {
    let text: String
    /// 单条依据直达原记录；nil = 依据是当天记录整体（打开当天列表）。
    let sourceEventID: UUID?
    let ruleVersion: String
}

enum MemoryWalkEchoBuilder {

    static let ruleVersion = "walk-echo-v1"
    /// 傍晚模板的判定阈值：与日回放夜间叙事一致（可靠时刻 ≥4 且 18 点后 ≥0.65）。
    private static let eveningReliableCount = 4
    private static let eveningShareThreshold = 0.65

    // MARK: - 过场摘句

    /// 过场光中展示的原文摘句：当天带正文想法的第一句（无想法日返回 nil，光形照常完整）。
    static func excerpt(for events: [CalendarEvent]) -> (text: String, sourceEventID: UUID)? {
        for event in events where event.module == .thought {
            if let sentence = firstReadableSentence(from: event.title) {
                return (sentence, event.id)
            }
        }
        return nil
    }

    // MARK: - 回看一句

    /// 抵达页的「回看一句」；没有可靠依据时返回 nil（整个区域省略）。
    ///
    /// - Parameters:
    ///   - events: 当天全部事件（跨日副本已被索引守卫滤掉）。
    ///   - visiblePreviews: 结果区即将展示的预览标题（摘句与列表重复且无补充细节时省略）。
    static func echo(for events: [CalendarEvent], visiblePreviews: [String]) -> MemoryWalkEcho? {
        guard !events.isEmpty else { return nil }

        // 1. 优先用户原文：想法正文里可独立阅读的第一人称句子。
        let thoughts = events.filter { $0.module == .thought }
        if let thought = thoughts.first(where: { firstReadableSentence(from: $0.title) != nil }),
           let sentence = firstReadableSentence(from: thought.title) {
            let trimmed = sentence
            let duplicatesPreview = visiblePreviews.contains { preview in
                preview.contains(trimmed) || trimmed.contains(preview)
            }
            if !duplicatesPreview {
                return MemoryWalkEcho(
                    text: String(localized: "你那天写道：“\(trimmed)”"),
                    sourceEventID: thought.id,
                    ruleVersion: ruleVersion
                )
            }
        }

        // 2. 事实模板：傍晚密集（条件与日回放夜间叙事同口径，但这里带证据身份）。
        let reliable = events.filter(\.hasReliableTime)
        guard reliable.count >= eveningReliableCount else { return nil }
        let evening = reliable.filter { Calendar.current.component(.hour, from: $0.date) >= 18 }
        let share = Double(evening.count) / Double(reliable.count)
        guard share >= eveningShareThreshold else { return nil }
        return MemoryWalkEcho(
            text: String(localized: "这一天的记录大多留在傍晚以后"),
            sourceEventID: nil,
            ruleVersion: ruleVersion
        )
    }

    // MARK: - 句子提取

    /// 取第一句可独立阅读的原文：以中文句号/问叹号截断；长度过短或过长的残句不用。
    private static func firstReadableSentence(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 6 else { return nil }
        let terminators: Set<Character> = ["。", "！", "？", "?", "!", "."]
        var sentence = Substring(text)
        for (offset, char) in text.enumerated() {
            guard offset > 0 else { continue }
            if terminators.contains(char) {
                sentence = text[..<text.index(text.startIndex, offsetBy: offset + 1)]
                break
            }
        }
        let result = String(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        // 单句至少 6 字才算「可独立阅读」；超过 42 字截到 40 字加省略号。
        guard result.count >= 6 else { return nil }
        if result.count > 42 {
            return String(result.prefix(40)) + "…"
        }
        return result
    }
}
