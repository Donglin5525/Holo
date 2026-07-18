//
//  HoloContentNode.swift
//  Holo
//
//  观点模块 - 编辑器结构化内容节点
//  text 节点承载 Markdown 原文；tag / reference 为带唯一 ID 的不可拆分 Token
//

import Foundation
import UIKit

// MARK: - HoloContentNode

/// 编辑器内容节点（编辑期内存模型，同时也是 richContentJSON 的序列化单位）
enum HoloContentNode: Equatable {
    /// 普通文本（含原始 Markdown 标记）
    case text(value: String)
    /// 标签 Token：id 为 ThoughtTag 主键，displayPath 为插入时的路径快照
    case tag(id: UUID, displayPath: String)
    /// 引用 Token：noteId 为目标想法主键，displayText 为目标首行快照，snapshot 为正文摘要快照
    case reference(noteId: UUID, displayText: String, snapshot: String)
}

// MARK: - Codable（自定义 type 判别，保证 JSON 格式稳定可读）

extension HoloContentNode: Codable {

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case id
        case displayPath
        case noteId
        case displayText
        case snapshot
    }

    private enum NodeType: String, Codable {
        case text
        case tag
        case reference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)

        switch type {
        case .text:
            self = .text(value: try container.decode(String.self, forKey: .value))
        case .tag:
            self = .tag(
                id: try container.decode(UUID.self, forKey: .id),
                displayPath: try container.decode(String.self, forKey: .displayPath)
            )
        case .reference:
            self = .reference(
                noteId: try container.decode(UUID.self, forKey: .noteId),
                displayText: try container.decode(String.self, forKey: .displayText),
                snapshot: try container.decode(String.self, forKey: .snapshot)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let value):
            try container.encode(NodeType.text, forKey: .type)
            try container.encode(value, forKey: .value)
        case .tag(let id, let displayPath):
            try container.encode(NodeType.tag, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(displayPath, forKey: .displayPath)
        case .reference(let noteId, let displayText, let snapshot):
            try container.encode(NodeType.reference, forKey: .type)
            try container.encode(noteId, forKey: .noteId)
            try container.encode(displayText, forKey: .displayText)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
}

// MARK: - HoloTokenType

/// Token 类型（富文本属性 .holoTokenType 的取值）
enum HoloTokenType: String {
    case tag
    case reference
}

// MARK: - Token 富文本属性键

extension NSAttributedString.Key {
    /// Token 类型（"tag" / "reference"），无此属性的区间为普通文本
    static let holoTokenType = NSAttributedString.Key("holoTokenType")
    /// Token 关联实体 ID（ThoughtTag.id 或 Thought.id 的 uuidString）
    static let holoEntityId = NSAttributedString.Key("holoEntityId")
    /// Token 展示文字快照（displayPath 或 displayText，不含 # / @ 前缀）
    static let holoDisplayText = NSAttributedString.Key("holoDisplayText")
    /// 引用 Token 的正文摘要快照（仅 reference 使用）
    static let holoSnapshot = NSAttributedString.Key("holoSnapshot")
}
