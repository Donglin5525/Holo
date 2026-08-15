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
    /// 任务标记 Token：选中文字转任务后插入。
    /// sourceLength 是作用范围在任务标记前的 UTF-16 长度，避免重进时用重复文本猜错下划线位置。
    case taskMark(id: UUID, taskId: UUID, displayText: String, sourceLength: Int)
}

// MARK: - Identifiable（供 .sheet(item:) 驱动 Token 操作菜单）

extension HoloContentNode: Identifiable {
    /// 用「类型前缀 + 实体 ID」拼稳定标识。text 节点不参与菜单，用内容哈希兜底。
    var id: String {
        switch self {
        case .text(let value):
            return "text-\(value.hashValue)"
        case .tag(let id, _):
            return "tag-\(id.uuidString)"
        case .reference(let noteId, _, _):
            return "ref-\(noteId.uuidString)"
        case .taskMark(let id, _, _, _):
            // 同一个任务可以作用于多段正文；SwiftUI 身份必须区分行内标记实例，
            // 不能使用 taskId，否则两个标记会被误认为同一个元素，菜单/刷新状态会漂移。
            return "task-mark-\(id.uuidString)"
        }
    }
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
        case taskId
        case sourceLength
    }

    private enum NodeType: String, Codable {
        case text
        case tag
        case reference
        case taskMark
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
                // 早期引用只保存了目标 ID；缺失展示字段时由序列化器用快照首行补齐。
                displayText: try container.decodeIfPresent(String.self, forKey: .displayText) ?? "",
                snapshot: try container.decodeIfPresent(String.self, forKey: .snapshot) ?? ""
            )
        case .taskMark:
            let displayText = try container.decode(String.self, forKey: .displayText)
            self = .taskMark(
                id: try container.decode(UUID.self, forKey: .id),
                taskId: try container.decode(UUID.self, forKey: .taskId),
                displayText: displayText,
                // 旧版 JSON 没有 sourceLength，旧快照长度是最可靠的兼容兜底。
                sourceLength: max(0, try container.decodeIfPresent(Int.self, forKey: .sourceLength) ?? displayText.utf16.count)
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
        case .taskMark(let id, let taskId, let displayText, let sourceLength):
            try container.encode(NodeType.taskMark, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(taskId, forKey: .taskId)
            try container.encode(displayText, forKey: .displayText)
            try container.encode(max(0, sourceLength), forKey: .sourceLength)
        }
    }
}

// MARK: - HoloTokenType

/// Token 类型（富文本属性 .holoTokenType 的取值）
enum HoloTokenType: String {
    case tag
    case reference
    case taskMark
}

// MARK: - Token 富文本属性键

extension NSAttributedString.Key {
    /// Token 类型（"tag" / "reference" / "taskMark"），无此属性的区间为普通文本
    static let holoTokenType = NSAttributedString.Key("holoTokenType")
    /// Token 关联实体 ID（ThoughtTag.id 或 Thought.id 的 uuidString）
    static let holoEntityId = NSAttributedString.Key("holoEntityId")
    /// 行内 Token 实例 ID。与实体 ID 分离：同一条笔记/标签可以在正文中出现多个独立 Token。
    static let holoTokenInstanceId = NSAttributedString.Key("holoTokenInstanceId")
    /// Token 展示文字快照（displayPath 或 displayText，不含 # / @ 前缀）
    static let holoDisplayText = NSAttributedString.Key("holoDisplayText")
    /// 引用 Token 的正文摘要快照（仅 reference 使用）
    static let holoSnapshot = NSAttributedString.Key("holoSnapshot")
    /// 任务标记 Token 关联的任务 ID（仅 taskMark 使用，TodoTask.id 的 uuidString）
    static let holoTaskId = NSAttributedString.Key("holoTaskId")
    /// 任务作用范围在标记 Token 前的 UTF-16 长度，用于重建持久下划线
    static let holoTaskSourceLength = NSAttributedString.Key("holoTaskSourceLength")
    /// 手动加粗标记（区别于系统 boldFont）：token 属性剥离时保留
    static let holoBold = NSAttributedString.Key("holoMarkdownBold")
    /// 手动颜色标记（hex 字符串）：token 属性剥离时保留
    static let holoColorHex = NSAttributedString.Key("holoMarkdownColorHex")
}
