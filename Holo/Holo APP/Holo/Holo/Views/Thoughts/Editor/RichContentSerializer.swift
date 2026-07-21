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

    /// @ 引用 Token 显示文字的最大长度（超出截断加省略号，避免行内引用过长）
    static let referenceDisplayMaxLength = 24

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

    /// 存量想法（无 JSON）：把整段文本按 #标签 切分为 text / tag 节点
    /// - 修复点：纯文本加载时也 Token 化标签，避免「打开后标签不再高亮」「重新保存后丢失 Token 化身份」
    ///   - tag 节点使用确定性 UUID（基于 displayPath 的稳定 hash），保证同一条想法多次打开 UUID 一致
    ///   - 末尾保留原文换行/空白，不再被段落级渲染吞掉（修复「末尾换行打开后消失」）
    static func nodes(fromPlainText text: String) -> [HoloContentNode] {
        guard !text.isEmpty else { return [] }

        // 先定位所有合法 #标签 的范围（含 # 前缀，UTF-16 NSRange）
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let regex = InlineTagDetector.textLevelTagRegex
        let matches = regex.matches(in: text, range: fullRange)
            .filter { match in
                InlineTagDetector.isTriggerPosition(match.range.location, in: text)
            }

        guard !matches.isEmpty else {
            return [.text(value: text)]
        }

        var nodes: [HoloContentNode] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let precedingRange = NSRange(location: cursor, length: match.range.location - cursor)
                let preceding = nsText.substring(with: precedingRange)
                nodes.append(.text(value: preceding))
            }
            let tagRange = match.range
            let rawTag = nsText.substring(with: tagRange)
            // 去掉 # 前缀
            let displayPath = ThoughtTagNormalizer.displayPath(String(rawTag.dropFirst()))
            guard !displayPath.isEmpty else {
                // 归一化后为空（如 "#_"）→ 当普通文本
                nodes.append(.text(value: rawTag))
                cursor = tagRange.location + tagRange.length
                continue
            }
            nodes.append(.tag(id: Self.deterministicTagId(for: displayPath), displayPath: displayPath))
            cursor = tagRange.location + tagRange.length
        }

        // 尾部剩余文本（含末尾换行/空白）作为 text 节点保留
        if cursor < nsText.length {
            let trailing = nsText.substring(from: cursor)
            nodes.append(.text(value: trailing))
        }

        return nodes
    }

    /// 基于 displayPath 的稳定 UUID（同一标签名跨会话一致）
    /// 用于纯文本加载时构造 tag Token，避免每次重新打开都生成不同 UUID 导致重复创建 ThoughtTag
    /// 实现：对 payload 做 djb2 64-bit hash（高低种子各一次），拼成 128 位再按 RFC 4122 v4 落位
    /// 注意：实际落库的 ThoughtTag 实体由 ThoughtTagNormalizer.key 归一化去重，
    ///      此 UUID 仅用于编辑期 Token 身份，不参与实体查找，碰撞不影响数据正确性
    private static func deterministicTagId(for displayPath: String) -> UUID {
        let payload = "holoTagNS|" + displayPath
        // 两个独立种子的 djb2 64-bit，组合成 128 位降低碰撞
        func djb2(_ seed: UInt64, _ s: String) -> UInt64 {
            var hash = seed
            for byte in s.utf8 {
                hash = hash &* 1099511628211 &+ UInt64(byte)
            }
            return hash
        }
        let high = djb2(0x84222325cbf29ce4, payload)
        let low = djb2(0x00037e1b4d9a6c2f, payload)

        var bytes = [UInt8]()
        withUnsafeBytes(of: high.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: low.bigEndian) { bytes.append(contentsOf: $0) }

        // RFC 4122 v4 mask：第 6 字节高 4 位 = 0100，第 8 字节高 2 位 = 10
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
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

    /// @ 引用 Token 显示文字：超长截断加省略号
    static func truncatedReferenceDisplay(_ title: String) -> String {
        guard title.count > referenceDisplayMaxLength else { return title }
        return String(title.prefix(referenceDisplayMaxLength)) + "…"
    }
}
