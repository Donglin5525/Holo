//
//  RichContentSerializer.swift
//  Holo
//
//  观点模块 - 结构化内容序列化器
//  ContentNode[] ↔ richContentJSON；ContentNode[] → 派生平文本 content / firstLine
//

import Foundation

// MARK: - RichContentSerializer

/// 结构化内容序列化器
/// - richContentJSON 是 Token 身份的唯一事实源
/// - content（平文本，含 Markdown 标记与 #/@ 显示文字）由节点派生，供 AI 分类/搜索/卡片等下游消费
enum RichContentSerializer {

    enum SerializerError: Error {
        case invalidJSON
    }

    /// firstLine 派生时的最大长度（超出截断，供 @ 候选列表标题使用）
    static let firstLineMaxLength = 80

    // MARK: - ContentNode[] → JSON

    static func jsonString(from nodes: [HoloContentNode]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(nodes)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SerializerError.invalidJSON
        }
        return json
    }

    // MARK: - JSON → ContentNode[]

    /// 严格解析：非法 JSON 抛错
    static func nodes(fromJSONString json: String) throws -> [HoloContentNode] {
        guard let data = json.data(using: .utf8) else {
            throw SerializerError.invalidJSON
        }
        return try JSONDecoder().decode([HoloContentNode].self, from: data)
    }

    /// 宽松解析：JSON 为空或损坏时回退为纯文本节点，保护用户数据不丢
    static func nodes(richJSON: String?, fallbackPlainText: String) -> [HoloContentNode] {
        guard let richJSON, !richJSON.isEmpty,
              let nodes = try? nodes(fromJSONString: richJSON) else {
            return nodes(fromPlainText: fallbackPlainText)
        }
        return nodes
    }

    // MARK: - 存量平文本 → ContentNode[]

    /// 存量想法（无 JSON）：整段包成单个 text 节点，保持原样不解析任何 #/@
    static func nodes(fromPlainText text: String) -> [HoloContentNode] {
        guard !text.isEmpty else { return [] }
        return [.text(value: text)]
    }

    // MARK: - ContentNode[] → 派生平文本

    /// 派生 content：text 节点保留 Markdown 原文，Token 节点输出 #/@ 显示文字
    /// 示例：[text("今天思考了 "), tag("工作/Holo")] → "今天思考了 #工作/Holo"
    static func plainText(from nodes: [HoloContentNode]) -> String {
        nodes.map(plainTextSegment).joined()
    }

    private static func plainTextSegment(from node: HoloContentNode) -> String {
        switch node {
        case .text(let value):
            return value
        case .tag(_, let displayPath):
            return "#\(displayPath)"
        case .reference(_, let displayText, _):
            return "@\(displayText)"
        }
    }

    // MARK: - firstLine 派生

    /// @ 候选列表标题：派生平文本的首个非空行，超长截断
    static func firstLine(from nodes: [HoloContentNode]) -> String {
        firstLine(fromPlainText: plainText(from: nodes))
    }

    /// 从平文本派生首行（保存时写 Thought.firstLine，供 @ 候选与列表摘要使用）
    static func firstLine(fromPlainText plain: String) -> String {
        let lines = plain.components(separatedBy: .newlines)
        let first = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(first.prefix(firstLineMaxLength))
    }
}
