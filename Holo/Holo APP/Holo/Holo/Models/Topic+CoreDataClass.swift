//
//  Topic+CoreDataClass.swift
//  Holo
//
//  想法主题实体
//  多条想法的长期线索聚合（v1a 只建表，不实现主题匹配/摘要/升级流程）
//

import Foundation
import CoreData

@objc(Topic)
class Topic: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Topic> {
        NSFetchRequest<Topic>(entityName: "Topic")
    }

    // MARK: - @NSManaged Properties

    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var iconEmoji: String?
    @NSManaged var summary: String?
    @NSManaged var status: String
    @NSManaged var confidence: Double
    @NSManaged var associatedTagNames: String?
    @NSManaged var thoughtCount: Int16
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date

    // MARK: - Relationships

    @NSManaged var thoughts: NSSet?
    @NSManaged var associatedTags: NSSet?
    @NSManaged var mergedToTopic: Topic?
    @NSManaged var mergedFromTopics: NSSet?
}

// MARK: - Core Data Generated Accessors

extension Topic {

    // MARK: - Thoughts Accessors

    @objc(addThoughtsObject:)
    @NSManaged func addThoughts(_ value: Thought)

    @objc(removeThoughtsObject:)
    @NSManaged func removeThoughts(_ value: Thought)

    @objc(addThoughts:)
    @NSManaged func addThoughts(_ values: Set<Thought>)

    @objc(removeThoughts:)
    @NSManaged func removeThoughts(_ values: Set<Thought>)

    // MARK: - AssociatedTags Accessors

    @objc(addAssociatedTagsObject:)
    @NSManaged func addAssociatedTags(_ value: ThoughtTag)

    @objc(removeAssociatedTagsObject:)
    @NSManaged func removeAssociatedTags(_ value: ThoughtTag)

    @objc(addAssociatedTags:)
    @NSManaged func addAssociatedTags(_ values: Set<ThoughtTag>)

    @objc(removeAssociatedTags:)
    @NSManaged func removeAssociatedTags(_ values: Set<ThoughtTag>)

    // MARK: - MergedFromTopics Accessors

    @objc(addMergedFromTopicsObject:)
    @NSManaged func addMergedFromTopics(_ value: Topic)

    @objc(removeMergedFromTopicsObject:)
    @NSManaged func removeMergedFromTopics(_ value: Topic)

    @objc(addMergedFromTopics:)
    @NSManaged func addMergedFromTopics(_ values: Set<Topic>)

    @objc(removeMergedFromTopics:)
    @NSManaged func removeMergedFromTopics(_ values: Set<Topic>)
}

// MARK: - Status 枚举

extension Topic {

    /// 主题状态类型
    enum TopicStatus: String, CaseIterable {
        case candidate  // 候选主题，证据不足
        case active     // 历史正式主题：可展示，但不进入 AI 分类约束池
        case classification // 用户明确启用的分类主题：可展示且进入 AI 单选约束池
        case hidden     // 用户隐藏
        case merged     // 已合并到其他主题
    }

    /// 便捷访问 status 枚举
    var statusEnum: TopicStatus {
        get { TopicStatus(rawValue: status) ?? .candidate }
        set { status = newValue.rawValue }
    }

    /// 是否可出现在主题列表、日历和 AI 数据摘要中。
    var isVisibleTopic: Bool {
        statusEnum == .active || statusEnum == .candidate || statusEnum == .classification
    }

    /// 是否是用户认可、可约束新想法 AI 分类的主题。
    var isClassificationTopic: Bool {
        statusEnum == .classification
    }
}

// MARK: - 图标 emoji（知识树 v1）

nonisolated enum TopicIconProvider {

    /// Onboarding 预设主题的固定图标（标题归一化后精确匹配）
    private static let presetIcons: [String: String] = [
        "工作与事业": "💼",
        "个人成长": "🌱",
        "灵感创意": "💡",
        "生活与健康": "🏃",
        "财务与消费": "💰",
        "关系与家庭": "👨‍👩‍👧",
    ]

    /// 关键词启发式（标题包含即命中，按数组顺序取第一个）
    private static let keywordRules: [(keywords: [String], icon: String)] = [
        (["工作", "事业", "项目", "职场", "job", "work"], "💼"),
        (["成长", "学习", "阅读", "读书", "复盘", "成长"], "🌱"),
        (["灵感", "创意", "点子", "idea", "设计"], "💡"),
        (["健康", "运动", "跑步", "健身", "睡眠", "饮食", "医疗"], "🏃"),
        (["财务", "消费", "钱", "记账", "理财", "账单", "订阅"], "💰"),
        (["家庭", "关系", "家人", "朋友", "孩子", "父母"], "👨‍👩‍👧"),
        (["旅行", "出行", "游记"], "✈️"),
        (["写作", "内容", "创作", "博客", "自媒体"], "✍️"),
        (["音乐", "吉他", "钢琴", "唱歌"], "🎵"),
        (["摄影", "拍照", "照片"], "📷"),
        (["美食", "做饭", "烹饪", "咖啡", "茶"], "🍜"),
        (["宠物", "猫", "狗"], "🐱"),
        (["情绪", "心情", "日记", "碎碎念", "记录"], "🌤️"),
        (["科技", "数码", "编程", "开发", "AI", "人工智能"], "🤖"),
    ]

    /// 兜底图标池（标题无法识别时按标题稳定哈希取一个，不跳变）
    private static let fallbackPool: [String] = [
        "📦", "🎯", "🔭", "🧭", "🎨", "🌿", "⭐️", "🔥",
        "🧩", "📌", "🌊", "☕️", "🍀", "🪴", "🛠️", "🗺️",
    ]

    /// 主题展示图标：用户设置 > 预设精确匹配 > 关键词启发式 > 标题稳定哈希兜底
    /// （更换图标的完整选择器见 EmojiCatalog + TopicIconPickerSheet）
    static func icon(for topic: Topic) -> String {
        if let chosen = topic.iconEmoji, !chosen.isEmpty { return chosen }
        return defaultIcon(forTitle: topic.title)
    }

    /// 按标题给默认图标（新建主题时也可主动落库，避免重命名后图标跳变）
    static func defaultIcon(forTitle title: String) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = presetIcons[normalized] { return preset }

        let lowered = normalized.lowercased()
        for rule in keywordRules where rule.keywords.contains(where: { lowered.contains($0.lowercased()) }) {
            return rule.icon
        }

        var hash = 5381
        for scalar in normalized.unicodeScalars {
            hash = (hash << 5) &+ hash &+ Int(scalar.value)
        }
        return fallbackPool[abs(hash) % fallbackPool.count]
    }
}

// MARK: - 关联标签展示缓存

extension Topic {

    /// 从 associatedTags 关系重算 associatedTagNames 展示缓存（逗号拼接，排序保证稳定）
    /// 标签删除/重命名/合并后必须调用，否则 AI 对话工具会读到脏名字
    func refreshAssociatedTagNamesCache() {
        let names = (associatedTags as? Set<ThoughtTag>)?
            .map(\.name)
            .sorted() ?? []
        associatedTagNames = names.isEmpty ? nil : names.joined(separator: ",")
    }
}
