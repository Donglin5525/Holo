//
//  AnalysisDetailBlockParser.swift
//  Holo
//
//  AI 文本标记解析 + 默认插入策略
//

import Foundation

/// Sheet 内的渲染块类型
enum AnalysisDetailBlock: Equatable {
    case text(String)
    case card(AnalysisCardSlot)
}

/// 分析卡片插槽，与 ChatCardData 的分析类型一一对应
enum AnalysisCardSlot: String, CaseIterable {
    case summary
    case breakdown
    case trend
    case comparison
    case highlights
}

/// AI 文本 → [AnalysisDetailBlock] 解析器
enum AnalysisDetailBlockParser {

    /// 标记行前缀
    private static let markerPrefix = "{{card:"
    private static let markerSuffix = "}}"

    /// 解析 AI 文本，识别标记并生成渲染块序列
    /// - Parameters:
    ///   - text: AI Markdown 文本
    ///   - availableSlots: 当前 AnalysisContext 实际可生成的卡片类型
    /// - Returns: 有序渲染块列表
    static func parse(text: String, availableSlots: Set<AnalysisCardSlot>) -> [AnalysisDetailBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [AnalysisDetailBlock] = []
        var textBuffer: [String] = []
        var usedSlots = Set<AnalysisCardSlot>()

        for line in lines {
            if let slot = parseMarker(line) {
                // 遇到标记：先 flush 文本 buffer
                flushTextBuffer(&textBuffer, into: &blocks)

                // 只使用第一次出现的标记，且该 slot 必须在 availableSlots 中
                if usedSlots.insert(slot).inserted, availableSlots.contains(slot) {
                    blocks.append(.card(slot))
                }
                // 重复标记或不可用的标记直接忽略（不保留为文本）
            } else {
                textBuffer.append(line)
            }
        }
        flushTextBuffer(&textBuffer, into: &blocks)

        // 检查是否使用了任何标记
        let parsedSlots = Set(blocks.compactMap { block -> AnalysisCardSlot? in
            if case .card(let slot) = block { return slot }
            return nil
        })

        // AI 没有输出任何有效标记时，使用默认插入策略
        if parsedSlots.isEmpty {
            return applyDefaultStrategy(text: text, availableSlots: availableSlots)
        }

        // 补充未被标记引用但可用的卡片（追加到末尾）
        var result = blocks
        let referencedSlots = parsedSlots
        for slot in AnalysisCardSlot.allCases {
            if !referencedSlots.contains(slot), availableSlots.contains(slot) {
                result.append(.card(slot))
            }
        }

        return result
    }

    // MARK: - Marker Parsing

    private static func parseMarker(_ line: String) -> AnalysisCardSlot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(markerPrefix), trimmed.hasSuffix(markerSuffix) else { return nil }
        let rawValue = String(trimmed.dropFirst(markerPrefix.count).dropLast(markerSuffix.count))
        return AnalysisCardSlot(rawValue: rawValue)
    }

    // MARK: - Text Buffer

    private static func flushTextBuffer(_ buffer: inout [String], into blocks: inout [AnalysisDetailBlock]) {
        guard !buffer.isEmpty else { return }
        let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        buffer.removeAll()
    }

    // MARK: - Default Insertion Strategy

    /// 无标记时的默认卡片插入策略
    private static func applyDefaultStrategy(text: String, availableSlots: Set<AnalysisCardSlot>) -> [AnalysisDetailBlock] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let n = paragraphs.count
        var result: [AnalysisDetailBlock] = []

        // 所有段落先转为 text block
        for para in paragraphs {
            result.append(.text(para))
        }

        // 确定可用的卡片（按 slot 声明顺序）
        let orderedSlots = AnalysisCardSlot.allCases.filter { availableSlots.contains($0) }
        guard !orderedSlots.isEmpty else { return result }

        // 少于 3 段：所有卡片追加到末尾
        if n < 3 {
            for slot in orderedSlots {
                result.append(.card(slot))
            }
            return result
        }

        // 计算插入点
        let summaryInsertIndex = 1                      // 第 1 段之后
        let midInsertIndex = max(1, n / 2)              // 中间位置
        let highlightsInsertIndex = n - 1               // 最后一段之前

        // 生成 (insertIndex, slotOrder, slot) 并按 (insertIndex, slotOrder) 排序
        var insertions: [(insertIndex: Int, slotOrder: Int, slot: AnalysisCardSlot)] = []

        for (order, slot) in orderedSlots.enumerated() {
            let index: Int
            switch slot {
            case .summary:
                index = summaryInsertIndex
            case .highlights:
                index = highlightsInsertIndex
            default: // breakdown, trend, comparison
                index = midInsertIndex
            }
            insertions.append((index, order, slot))
        }

        // 稳定排序：先按 insertIndex 升序，再按 slotOrder 升序
        insertions.sort { a, b in
            if a.insertIndex != b.insertIndex { return a.insertIndex < b.insertIndex }
            return a.slotOrder < b.slotOrder
        }

        // 从后向前插入（避免索引偏移）
        for insertion in insertions.reversed() {
            result.insert(.card(insertion.slot), at: insertion.insertIndex)
        }

        return result
    }
}
