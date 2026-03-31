//
//  ThoughtRepository.swift
//  Holo
//
//  观点模块 - 数据仓储层
//  负责 Thought 实体的增删改查操作
//

import Foundation
import CoreData

// MARK: - Notification Names

extension Notification.Name {
    /// 观点数据变更通知（新增/编辑/删除想法时发送）
    static let thoughtDataDidChange = Notification.Name("thoughtDataDidChange")
}

/// 观点数据仓储
class ThoughtRepository {

    // MARK: - Properties

    private let context: NSManagedObjectContext

    // MARK: - Initialization

    /// 初始化方法
    /// - Parameter context: NSManagedObjectContext，默认使用主上下文
    init(context: NSManagedObjectContext = CoreDataStack.shared.viewContext) {
        self.context = context
    }

    // MARK: - Fetch Operations

    /// 获取所有想法
    /// - Parameters:
    ///   - limit: 数量限制，nil 表示无限制
    ///   - offset: 偏移量
    ///   - sortBy: 排序方式
    /// - Returns: Thought 数组
    func fetchAll(
        limit: Int? = nil,
        offset: Int = 0,
        sortBy: ThoughtSortOption = .createdAtDescending
    ) throws -> [Thought] {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")

        // 设置排序
        switch sortBy {
        case .createdAtDescending:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        case .createdAtAscending:
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        case .updatedAtDescending:
            request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        case .mood:
            request.sortDescriptors = [NSSortDescriptor(key: "mood", ascending: true)]
        }

        // 设置分页
        if let limit = limit {
            request.fetchLimit = limit
        }
        request.fetchOffset = offset

        return try context.fetch(request)
    }

    /// 根据 ID 获取想法
    /// - Parameter id: UUID
    /// - Returns: Thought 对象，不存在返回 nil
    func fetchById(_ id: UUID) throws -> Thought? {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO AND isArchived == NO", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// 根据标签获取想法
    /// - Parameter tagName: 标签名称
    /// - Returns: Thought 数组
    func fetchByTag(_ tagName: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let tagPredicate = NSPredicate(format: "ANY tags.name == %@", tagName)
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [tagPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 根据心情获取想法
    /// - Parameter mood: 心情类型
    /// - Returns: Thought 数组
    func fetchByMood(_ mood: String) throws -> [Thought] {
        let request = Thought.fetchRequest()
        let moodPredicate = NSPredicate(format: "mood == %@", mood)
        let deletePredicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [moodPredicate, deletePredicate])
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return try context.fetch(request)
    }

    /// 搜索想法
    /// - Parameters:
    ///   - query: 搜索关键词
    ///   - filters: 筛选条件
    /// - Returns: Thought 数组
    func search(query: String, filters: ThoughtFilters? = nil) throws -> [Thought] {
        let request = Thought.fetchRequest()
        var predicates: [NSPredicate] = [NSPredicate(format: "isSoftDeleted == NO AND isArchived == NO")]

        // 搜索内容或标签
        if !query.isEmpty {
            let contentPredicate = NSPredicate(format: "content CONTAINS[cd] %@", query)
            let tagPredicate = NSPredicate(format: "ANY tags.name CONTAINS[cd] %@", query)
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [contentPredicate, tagPredicate]))
        }

        // 心情筛选
        if let mood = filters?.mood {
            predicates.append(NSPredicate(format: "mood == %@", mood))
        }

        // 日期范围筛选
        if let startDate = filters?.startDate {
            predicates.append(NSPredicate(format: "createdAt >= %@", startDate as CVarArg))
        }
        if let endDate = filters?.endDate {
            predicates.append(NSPredicate(format: "createdAt <= %@", endDate as CVarArg))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

        return try context.fetch(request)
    }

    // MARK: - Create Operations

    /// 创建新想法
    /// - Parameters:
    ///   - content: 内容
    ///   - mood: 心情
    ///   - tags: 标签名称数组
    ///   - imageData: 图片数据
    /// - Returns: 创建的 Thought 对象
    @discardableResult
    func create(
        content: String,
        mood: String? = nil,
        tags: [String] = [],
        imageData: Data? = nil
    ) throws -> Thought {
        let thought = Thought(context: context)
        thought.id = UUID()
        thought.content = content
        thought.createdAt = Date()
        thought.updatedAt = Date()
        thought.mood = mood
        thought.orderIndex = 0
        thought.imageData = imageData
        thought.isSoftDeleted = false

        // 关联标签
        if !tags.isEmpty {
            for tagName in tags {
                let tag = try getOrCreateTag(name: tagName)
                thought.addTags(tag)
            }
        }

        try context.save()
        return thought
    }

    // MARK: - Update Operations

    /// 更新想法
    /// - Parameters:
    ///   - id: 想法 ID
    ///   - content: 新内容
    ///   - mood: 新心情
    ///   - tags: 新标签数组
    /// - Returns: 更新后的 Thought 对象
    @discardableResult
    func update(
        _ id: UUID,
        content: String? = nil,
        mood: String? = nil,
        tags: [String]? = nil
    ) throws -> Thought {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        if let content = content {
            thought.content = content
        }
        if let mood = mood {
            thought.mood = mood
        }

        thought.updatedAt = Date()

        // 更新标签
        if let tags = tags {
            // 清除现有标签关联
            thought.tags?.forEach { tag in
                if let tag = tag as? ThoughtTag {
                    thought.removeTags(tag)
                }
            }

            // 添加新标签
            for tagName in tags {
                let tag = try getOrCreateTag(name: tagName)
                thought.addTags(tag)
            }
        }

        try context.save()
        return thought
    }

    // MARK: - Delete Operations

    /// 删除想法
    /// - Parameter id: 想法 ID
    func delete(_ id: UUID) throws {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        // 软删除：只标记 isSoftDeleted，不断开引用关系
        thought.isSoftDeleted = true
        thought.updatedAt = Date()

        try context.save()
    }

    /// 硬删除想法（用于彻底删除）
    /// - Parameter id: 想法 ID
    func hardDelete(_ id: UUID) throws {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        // 删除相关的引用关系
        if let references = thought.references as? Set<ThoughtReference> {
            references.forEach { context.delete($0) }
        }
        if let referencedBy = thought.referencedBy as? Set<ThoughtReference> {
            referencedBy.forEach { context.delete($0) }
        }

        context.delete(thought)
        try context.save()
    }

    // MARK: - Archive Operations

    /// 归档想法
    /// - Parameter id: 想法 ID
    func archive(_ id: UUID) throws {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO", id as CVarArg)
        request.fetchLimit = 1

        guard let thought = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        thought.isArchived = true
        thought.updatedAt = Date()

        try context.save()
    }

    /// 取消归档想法
    /// - Parameter id: 想法 ID
    func unarchive(_ id: UUID) throws {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND isSoftDeleted == NO", id as CVarArg)
        request.fetchLimit = 1

        guard let thought = try context.fetch(request).first else {
            throw ThoughtError.notFound
        }

        thought.isArchived = false
        thought.updatedAt = Date()

        try context.save()
    }

    /// 获取已归档的想法
    /// - Returns: Thought 数组
    func fetchArchived() throws -> [Thought] {
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO AND isArchived == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try context.fetch(request)
    }

    // MARK: - Reference Operations

    /// 添加引用关系
    /// - Parameters:
    ///   - sourceId: 引用发起方 ID
    ///   - targetId: 被引用方 ID
    func addReference(sourceId: UUID, targetId: UUID) throws {
        guard let source = try fetchById(sourceId),
              let target = try fetchById(targetId) else {
            throw ThoughtError.notFound
        }

        let reference = ThoughtReference(context: context)
        reference.id = UUID()
        reference.createdAt = Date()
        reference.sourceThought = source
        reference.targetThought = target

        try context.save()
    }

    /// 移除引用关系
    /// - Parameters:
    ///   - sourceId: 引用发起方 ID
    ///   - targetId: 被引用方 ID
    func removeReference(sourceId: UUID, targetId: UUID) throws {
        let request = ThoughtReference.fetchRequest()
        let sourcePredicate = NSPredicate(format: "sourceThought.id == %@", sourceId as CVarArg)
        let targetPredicate = NSPredicate(format: "targetThought.id == %@", targetId as CVarArg)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [sourcePredicate, targetPredicate])

        guard let reference = try context.fetch(request).first else {
            return
        }

        context.delete(reference)
        try context.save()
    }

    /// 获取想法引用的其他想法
    /// - Parameter id: 想法 ID
    /// - Returns: Thought 数组
    func getReferences(for id: UUID) throws -> [Thought] {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        return (thought.references as? Set<ThoughtReference>)?
            .compactMap { $0.targetThought }
            .filter { !$0.isSoftDeleted } ?? []
    }

    /// 获取引用该想法的其他想法
    /// - Parameter id: 想法 ID
    /// - Returns: Thought 数组
    func getReferencedBy(id: UUID) throws -> [Thought] {
        guard let thought = try fetchById(id) else {
            throw ThoughtError.notFound
        }

        return (thought.referencedBy as? Set<ThoughtReference>)?
            .compactMap { $0.sourceThought }
            .filter { !$0.isSoftDeleted } ?? []
    }

    // MARK: - Tag Operations

    /// 获取所有标签
    /// - Returns: ThoughtTag 数组
    func getAllTags() throws -> [ThoughtTag] {
        let request = ThoughtTag.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "usageCount", ascending: false)]
        return try context.fetch(request)
    }

    /// 获取或创建标签
    /// - Parameter name: 标签名称
    /// - Returns: ThoughtTag 对象
    private func getOrCreateTag(name: String) throws -> ThoughtTag {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", name)

        if let tag = try context.fetch(request).first {
            // 增加使用次数
            tag.usageCount += 1
            return tag
        } else {
            let tag = ThoughtTag(context: context)
            tag.id = UUID()
            tag.name = name
            tag.usageCount = 1
            return tag
        }
    }

    /// 合并标签
    /// - Parameters:
    ///   - oldName: 原标签名
    ///   - newName: 新标签名
    func mergeTags(oldName: String, newName: String) throws {
        let oldTags = try getOrCreateTag(name: oldName)
        let newTag = try getOrCreateTag(name: newName)

        // 将旧标签关联的想法转移到新标签
        if let thoughts = oldTags.thoughts as? Set<Thought> {
            for thought in thoughts {
                oldTags.removeThoughts(thought)
                newTag.addThoughts(thought)
            }
        }

        // 删除旧标签
        context.delete(oldTags)
        try context.save()
    }

    /// 删除未使用的标签
    /// - Parameter name: 标签名称
    func deleteTag(_ name: String) throws {
        let request = ThoughtTag.fetchRequest()
        request.predicate = NSPredicate(format: "name == %@", name)

        guard let tag = try context.fetch(request).first else {
            return
        }

        // 检查是否有思想使用该标签
        if let thoughts = tag.thoughts as? Set<Thought>, !thoughts.isEmpty {
            throw ThoughtError.tagInUse
        }

        context.delete(tag)
        try context.save()
    }
}

// MARK: - Error Types

/// 观点模块错误类型
enum ThoughtError: LocalizedError {
    case notFound
    case tagInUse
    case saveFailed
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "想法不存在"
        case .tagInUse:
            return "标签正在使用中，无法删除"
        case .saveFailed:
            return "保存失败"
        case .unknown(let error):
            return "未知错误：\(error.localizedDescription)"
        }
    }
}

// MARK: - Sort Options

/// 排序选项
enum ThoughtSortOption {
    case createdAtDescending      // 创建时间倒序
    case createdAtAscending       // 创建时间正序
    case updatedAtDescending      // 更新时间倒序
    case mood                     // 按心情排序
}

// MARK: - Filters

/// 筛选条件
struct ThoughtFilters {
    var mood: String?
    var startDate: Date?
    var endDate: Date?
    var tags: [String]?
}
