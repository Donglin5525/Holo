//
//  ThoughtUIHelpers.swift
//  Holo
//
//  观点模块 - UI 辅助类型和扩展
//  包含心情枚举、Core Data 扩展等
//

import SwiftUI
import CoreData

// MARK: - 心情枚举

/// 心情类型枚举
enum ThoughtMoodType: String, CaseIterable, Codable {
    case happy = "happy"      // 开心
    case sad = "sad"          // 难过
    case angry = "angry"      // 愤怒
    case calm = "calm"        // 平静
    case thinking = "thinking" // 思考
    case inspired = "inspired" // 灵感

    /// 从字符串初始化
    init?(from string: String?) {
        guard let string = string else { return nil }
        self.init(rawValue: string)
    }

    /// 显示名称
    var displayName: String {
        switch self {
        case .happy: return "开心"
        case .sad: return "难过"
        case .angry: return "愤怒"
        case .calm: return "平静"
        case .thinking: return "思考"
        case .inspired: return "灵感"
        }
    }

    /// Emoji 图标
    var emoji: String {
        switch self {
        case .happy: return "😄"
        case .sad: return "😢"
        case .angry: return "😤"
        case .calm: return "😌"
        case .thinking: return "🤔"
        case .inspired: return "💡"
        }
    }

    /// 主色调
    var color: Color {
        switch self {
        case .happy: return Color(red: 245/255, green: 158/255, blue: 11/255)
        case .sad: return Color(red: 59/255, green: 130/255, blue: 246/255)
        case .angry: return Color(red: 239/255, green: 68/255, blue: 68/255)
        case .calm: return Color(red: 16/255, green: 185/255, blue: 129/255)
        case .thinking: return Color(red: 139/255, green: 92/255, blue: 246/255)
        case .inspired: return Color(red: 251/255, green: 191/255, blue: 36/255)
        }
    }

    /// 浅色背景
    var backgroundColor: Color {
        switch self {
        case .happy: return Color(red: 254/255, green: 243/255, blue: 199/255)
        case .sad: return Color(red: 219/255, green: 234/255, blue: 254/255)
        case .angry: return Color(red: 254/255, green: 226/255, blue: 226/255)
        case .calm: return Color(red: 209/255, green: 250/255, blue: 229/255)
        case .thinking: return Color(red: 237/255, green: 233/255, blue: 254/255)
        case .inspired: return Color(red: 254/255, green: 243/255, blue: 199/255)
        }
    }
}

// MARK: - Thought 扩展

extension Thought: Identifiable {}

extension Thought {
    /// 心情类型
    var moodType: ThoughtMoodType? {
        ThoughtMoodType(from: mood)
    }

    /// 预览文本（前 80 个字符）
    var previewText: String {
        let stripped = content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        return String(stripped.prefix(80))
    }

    /// 格式化日期
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) {
            formatter.dateFormat = "HH:mm"
            return "今天 " + formatter.string(from: createdAt)
        } else if calendar.isDateInYesterday(createdAt) {
            formatter.dateFormat = "HH:mm"
            return "昨天 " + formatter.string(from: createdAt)
        } else {
            formatter.dateFormat = "MM月dd日"
            return formatter.string(from: createdAt)
        }
    }

    /// 标签数组
    var tagArray: [ThoughtTag] {
        (tags as? Set<ThoughtTag>)?.sorted { $0.name < $1.name } ?? []
    }

    /// 引用数量
    var referenceCount: Int {
        (references as? Set<ThoughtReference>)?.count ?? 0
    }

    /// 被引用数量
    var referencedByCount: Int {
        (referencedBy as? Set<ThoughtReference>)?.count ?? 0
    }
}

// MARK: - ThoughtTag 扩展

extension ThoughtTag: Identifiable {}

extension ThoughtTag {
    /// 标签颜色
    var tagColor: Color {
        guard let colorHex = color else { return .holoPurple }
        return Color(hex: colorHex)
    }
}

// MARK: - UUID Identifiable 扩展

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}