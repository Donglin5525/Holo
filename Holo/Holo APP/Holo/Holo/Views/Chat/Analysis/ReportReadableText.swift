//
//  ReportReadableText.swift
//  Holo
//
//  深度报告可读性文本工具（纯函数，2026-11-20 报告改版 A 期）：
//  - leadSentences：卡片/分享只取导语前几句（整句，不截半句）
//  - splitParagraph：超长段在最接近中点的句界一分为二，递归到 ≤ maxChars；单句不硬切
//  - numberSpans：数字+单位高亮范围（跳过 8 月 / 11-17 这类日期），替代整句加粗
//  - leadEmphasisRange：仅「短首句 + 后面还有话」时把首句当主题句加粗
//  方案：docs/_common/plans/2026-11-20-深度报告可读性与目标复盘改版/01-方案.md
//

import Foundation

nonisolated enum ReportReadableText {

    static let sentenceTerminators: Set<Character> = ["。", "！", "？", "；", "!", "?"]
    /// 超过这个字数的段落拆分（中文阅读一屏约 6–7 行）
    static let defaultMaxParagraphChars = 150
    /// 主题句加粗的首句上限：再长就是一整行半，加粗反而压住视线
    static let leadEmphasisMaxChars = 28

    /// 数字后可跟的单位（长的放前面，优先最长匹配）
    private static let units: [String] = [
        "小时", "分钟", "公斤", "公里", "千卡", "kg", "km",
        "%", "个", "天", "次", "条", "晚", "元", "万", "步", "周", "岁", "本", "项", "笔", "倍", "h"
    ]
    /// 数字后出现这些字 → 视为日期/时刻，不高亮
    private static let dateFollowers: Set<Character> = ["月", "日", "号", "年", "-", "/", ":", "："]
    private static let datePrecursors: Set<Character> = ["-", "/", ":", "："]

    // MARK: - 句子

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if sentenceTerminators.contains(char) {
                result.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }

    /// 在 maxChars 预算内取整句；首句超预算也完整保留（展示层用 lineLimit 兜底）。
    static func leadSentences(_ text: String, maxChars: Int = 90) -> String {
        let parts = sentences(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let first = parts.first else { return "" }
        var lead = first
        for part in parts.dropFirst() {
            guard lead.count + part.count <= maxChars else { break }
            lead += part
        }
        return lead.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 段落拆分

    static func splitParagraph(_ text: String, maxChars: Int = defaultMaxParagraphChars) -> [String] {
        guard text.count > maxChars else { return [text] }
        let parts = sentences(text)
        guard parts.count >= 2 else { return [text] }

        let total = parts.reduce(0) { $0 + $1.count }
        var bestCut = 1
        var bestDistance = Int.max
        var prefix = 0
        for index in 1..<parts.count {
            prefix += parts[index - 1].count
            let distance = abs(prefix * 2 - total)
            if distance < bestDistance {
                bestDistance = distance
                bestCut = index
            }
        }
        let head = parts[..<bestCut].joined()
        let tail = parts[bestCut...].joined()
        return splitParagraph(head, maxChars: maxChars) + splitParagraph(tail, maxChars: maxChars)
    }

    // MARK: - 强调范围

    static func numberSpans(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: "\\d[\\d,]*(?:\\.\\d+)?") else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return emphasisRange(forNumberAt: range, in: text)
        }
    }

    /// 段落 ≥2 句且首句 ≤28 字时返回首句范围，否则 nil。
    static func leadEmphasisRange(in text: String) -> Range<String.Index>? {
        let parts = sentences(text)
        guard parts.count >= 2, let first = parts.first, first.count <= leadEmphasisMaxChars else { return nil }
        let end = text.index(text.startIndex, offsetBy: first.count)
        return text.startIndex..<end
    }

    // MARK: - 私有

    private static func emphasisRange(forNumberAt range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        if range.lowerBound > text.startIndex,
           datePrecursors.contains(text[text.index(before: range.lowerBound)]) {
            return nil
        }
        // 数字后（可隔一个空格）紧跟的字符
        var cursor = range.upperBound
        if cursor < text.endIndex, text[cursor] == " " {
            cursor = text.index(after: cursor)
        }
        if range.upperBound < text.endIndex, dateFollowers.contains(text[range.upperBound]) {
            return nil
        }
        if cursor < text.endIndex, dateFollowers.contains(text[cursor]) {
            return nil
        }
        let rest = text[cursor...]
        if let unit = units.first(where: { rest.hasPrefix($0) }) {
            return range.lowerBound..<text.index(cursor, offsetBy: unit.count)
        }
        return range
    }
}
