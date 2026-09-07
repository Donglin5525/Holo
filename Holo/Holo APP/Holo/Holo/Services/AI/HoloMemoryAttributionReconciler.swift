//
//  HoloMemoryAttributionReconciler.swift
//  Holo
//
//  记忆引用署名的程序侧兜底。
//
//  署名主通道是模型在回复末尾吐 [[HOLO_MEMORY_IDS:…]] 标记；模型偶发不吐标记时，
//  「用了记忆却不说来源」，溯源断链。本文件在流式结束后按内容词匹配对账：
//  从注入的记忆条目文本中提取内容片段（剥离虚词），在回复正文中查找命中。
//  宁可多署（回复提到了猫 → 署名养猫记忆基本成立），不可漏署。
//  纯逻辑，可 standalone 测试。
//

import Foundation

nonisolated enum HoloMemoryAttributionReconciler {
    struct Entry: Sendable, Equatable {
        let id: String
        /// 记忆条目文本（标题 + AI 用途摘要）。
        let text: String
    }

    /// 虚词表：拆分内容片段用（单字/高频功能词不作为匹配特征）。
    private static let fillerCharacters: Set<Character> = Set("的了是在和与就都很我你他她它们这那有没不也又还把被对说要想去来能给会可以吗呢吧啊呀哦嘛之或及等着过地得上下里中前后都跟让使向从被让")

    static func matchedMemoryIDs(reply: String, entries: [Entry]) -> [String] {
        guard !reply.isEmpty, !entries.isEmpty else { return [] }
        var matched: [String] = []
        for entry in entries {
            guard !entry.id.isEmpty, hasContentOverlap(reply: reply, entryText: entry.text) else { continue }
            if !matched.contains(entry.id) {
                matched.append(entry.id)
            }
        }
        return matched
    }

    /// 条目文本拆出 ≥2 字的内容片段，任一片段被回复原文包含即视为命中。
    private static func hasContentOverlap(reply: String, entryText: String) -> Bool {
        for segment in contentSegments(in: entryText) {
            if reply.contains(segment) {
                return true
            }
        }
        return false
    }

    /// 按虚词与标点切分出连续内容片段（≥2 字）；过长片段截到 12 字，
    /// 避免「出差时担心没人喂」这类长片段因措辞差异匹配不上。
    private static func contentSegments(in text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                if fillerCharacters.contains(character) {
                    flush(&current, into: &segments)
                } else {
                    current.append(character)
                }
            } else {
                flush(&current, into: &segments)
            }
        }
        flush(&current, into: &segments)
        return segments
    }

    private static func flush(_ current: inout String, into segments: inout [String]) {
        defer { current = "" }
        if current.count < 2 { return }
        if current.count > 12 {
            // 滑窗采样：长片段取首、中、尾三个 12 字窗口，兼顾开头措辞与结尾专名。
            let characters = Array(current)
            let windows = [characters.prefix(12), characters.dropFirst(characters.count / 2).prefix(12), characters.suffix(12)]
            for window in windows where !window.isEmpty {
                segments.append(String(window))
            }
        } else {
            segments.append(current)
        }
    }
}
