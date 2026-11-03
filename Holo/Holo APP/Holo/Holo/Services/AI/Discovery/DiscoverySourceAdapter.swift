//
//  DiscoverySourceAdapter.swift
//  Holo
//
//  「HoloAI 一个发现」G2：三域只读来源适配（02 §2 来源白名单 / §2.2 FactAtom 口径）。
//
//  · 想法／任务／习惯各一个 adapter，统一协议 DiscoverySourceAdapting；只产值类型快照，
//    离开 context 不携带 NSManagedObject（快照在所属 context 的 performAndWait 内投影）。
//  · 所有 fetch 谓词一律与各自 basePredicate() 求交（回源核权）：想法域叠加
//    DiscoveryAccessPolicy.thoughtDomainAIRestrictedPredicate（ThoughtAIAudience 标签排除）
//    并排除软删（isSoftDeleted/deletedAt）与归档（V1 默认不读已归档正文，02 §2.1 末段）；
//    任务域排除 deletedFlag/deletedAt/archived；习惯事件域排除 deletedAt。
//  · 发生时间口径（G0 缺口 A）：想法无独立 occurredAt，一律用 createdAt 兼发生与记录；
//    任务完成事件=completedAt 有值（未完成无发生时间）；HabitRecord date=发生、createdAt=记录、
//    isRetroactive=补签（补签 date 是目标日零点，只知道日期——occurredOnlyDateKnown=true，
//    builder 用日区间，不把零点当真实时刻）。
//  · 每域 sourceRevision 用固定字段序（DiscoveryContentDigest.sourceRevision(from:)），
//    纯静态函数产出，字段序一经发布不可变动（同记录类型必须永远同一字段序列）。
//  · 习惯只读：定义只取 id/name/type/unit/isBadHabit，不回写、不推断历史达标（G0 §1.3；
//    归档习惯的历史记录仍是真实事件，V1 照读，仅排除软删）。
//

import CoreData
import Foundation

// MARK: - 时间窗

/// [start, end) 左闭右开窗口。自然日语义由调用方（Retriever）用注入的 Calendar 换算。
struct DiscoveryTimeWindow: Equatable, Sendable {
    let start: Date
    /// 排他端点
    let end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

// MARK: - 来源快照（值类型）

/// 三域统一的只读来源快照。适配器产出；EvidenceBuilder 消费。
struct DiscoverySourceSnapshot: Equatable, Sendable {
    /// 来源域（thought/task/habit），与 sourceKind 前三者一一对应
    let domain: DiscoverySourceDomain
    let kind: DiscoverySourceKind
    let localID: String

    // MARK: 时间口径
    /// 事件发生时间：想法=createdAt（缺口 A 口径）；任务=completedAt（未完成为 nil）；
    /// 习惯事件=date。nil = 未知（F13：不能伪造）
    let occurredAt: Date?
    /// 只知道发生日期（补签 date=目标日零点）：builder 用日区间，不编时刻
    let occurredOnlyDateKnown: Bool
    /// 实际保存/记录时间（与发生时间分开）
    let recordedAt: Date

    // MARK: 材料与关联
    /// 原文材料（想法正文 / 任务标题+描述 / 习惯事件构成文），builder 在此上切块
    let text: String
    /// 显式记录的数值与单位（习惯数值型事件；computedFacts 只引用显式记录值，02 §5 门禁 6）
    let numericValue: Double?
    let numericUnit: String?
    /// 显式实体关联（tag:/topic:/goal:/habit:/thought:）；同名标签不构成同一实体
    let entityRefs: [String]
    /// 事件锚：同一底层事件的显式关联（task:<id>）。共享任一锚 → 同 lineage（02 §2.4 规则 1）
    let eventAnchors: [String]

    /// 参与版本判断的固定字段序（域内固定；不可从外部拼接）
    let revisionFields: [String]

    var localSourceRef: DiscoveryFactAtom.SourceRef {
        DiscoveryFactAtom.SourceRef(kind: kind, localID: localID)
    }
    /// 稳定内容摘要（DiscoveryStore 无关；适配器只产值类型快照）
    var sourceRevision: String {
        DiscoveryContentDigest.sourceRevision(from: revisionFields)
    }
    var sourceRefCanonical: String {
        localSourceRef.canonical
    }
}

// MARK: - 域可用性（反例覆盖三态判定用）

/// 该域可读数据的起点。反例检索区分「搜索完成无命中」与「历史不足」（02 §6 末段）用。
struct DiscoverySourceAvailability: Equatable, Sendable {
    /// 最早一条可读记录的时间；nil = 该域无任何可读记录
    let earliestRecordAt: Date?

    init(earliestRecordAt: Date?) {
        self.earliestRecordAt = earliestRecordAt
    }
}

// MARK: - 统一协议

/// 三域只读适配统一协议（检索语义面）。所有实现的每个 fetch 谓词都必须与
/// basePredicate() 求交——这是「回源核权」的结构保证，不是调用方自觉。
/// 隔离口径仿 G1 DiscoveryStore：nonisolated + 所在 context performAndWait 投影，
/// 可从任意线程同步调用（默认 context 为主栈 viewContext，按 @MainActor 仓库惯例取）。
protocol DiscoverySourceAdapting: AnyObject {
    var domain: DiscoverySourceDomain { get }
    var sourceKind: DiscoverySourceKind { get }

    /// 域基础可见谓词（含软删/归档排除；想法域已含 AI 可见性）。所有 fetch 与它求交。
    func basePredicate() -> NSPredicate

    /// 按本地 ID 精确取（变化对象通道 / 回源核版本）
    func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot]
    /// 同主题（显式关系：标签/主题/目标）
    func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot]
    /// 同对象锚（task:/habit:/goal:/thought:，定向历史通道）
    func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot]
    /// 关键词（CONTAINS[cd]，与基础谓词求交）
    func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot]
    /// 中性时间窗扫描（无关键词；程序侧中性回看专用）
    func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot]
    /// 域数据起点
    func availability() throws -> DiscoverySourceAvailability
}

// MARK: - performAndWait 同步取回

/// 与 DiscoveryStore 同款一次性盒子：performAndWait 同步执行，闭包跑完才回调用线程读值。
nonisolated fileprivate final class DiscoveryAdapterSyncBox<T>: @unchecked Sendable {
    var value: Result<T, Error>!
}

// MARK: - 想法域

final class DiscoveryThoughtAdapter: DiscoverySourceAdapting {

    let domain = DiscoverySourceDomain.thought
    let sourceKind = DiscoverySourceKind.thought

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext? = nil) {
        // 默认主栈 viewContext（@MainActor 仓库按现有调用惯例）；测试可注入独立 context
        self.context = context ?? CoreDataStack.shared.viewContext
    }

    func basePredicate() -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            // 记录级 AI 可见（用户关联标签 excludeFromAI）+ 软删/归档排除（V1 不读归档正文）
            DiscoveryAccessPolicy.thoughtDomainAIRestrictedPredicate,
            NSPredicate(format: "deletedAt == nil AND isSoftDeleted == NO AND isArchived == NO"),
        ])
    }

    func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "id IN %@", localIDs),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let topicIDs = Self.uuids(refs: topicRefs, prefix: "topic:")
        let tagNames = Self.values(refs: topicRefs, prefix: "tag:")
        guard !topicIDs.isEmpty || !tagNames.isEmpty else { return [] }
        var orPredicates: [NSPredicate] = []
        if !topicIDs.isEmpty {
            orPredicates.append(NSPredicate(format: "ANY topics.id IN %@", topicIDs))
        }
        if !tagNames.isEmpty {
            orPredicates.append(NSPredicate(
                format: "SUBQUERY(tagAssignments, $a, $a.rejectedAt == nil AND $a.tag.name IN %@).@count > 0",
                tagNames as CVarArg
            ))
        }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                orPredicates.count == 1 ? orPredicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: orPredicates),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        // 想法域的对象锚：由本想法转换而来的任务（createdTasks）
        let taskIDs = Self.uuids(refs: anchorRefs, prefix: "task:")
        guard !taskIDs.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "ANY createdTasks.id IN %@", taskIDs),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !keyword.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "content CONTAINS[cd] %@", keyword),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func availability() throws -> DiscoverySourceAvailability {
        let earliest: Date? = try fetchOneDate(
            predicate: basePredicate(),
            ascending: true,
            dateKey: "createdAt"
        )
        return DiscoverySourceAvailability(earliestRecordAt: earliest)
    }

    // MARK: - 投影

    private func fetch(predicate: NSPredicate, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let box = DiscoveryAdapterSyncBox<[DiscoverySourceSnapshot]>()
        context.performAndWait { [context] in
            do {
                let request = Thought.fetchRequest()
                request.predicate = predicate
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                request.fetchLimit = limit
                // 块内投影成值类型：托管对象不跨 context 逃逸
                let snapshots = try context.fetch(request).map(Self.project)
                box.value = .success(snapshots)
            } catch {
                box.value = .failure(error)
            }
        }
        return try box.value!.get()
    }

    private func fetchOneDate(predicate: NSPredicate, ascending: Bool, dateKey: String) throws -> Date? {
        let box = DiscoveryAdapterSyncBox<Date?>()
        context.performAndWait { [context] in
            do {
                let request = Thought.fetchRequest()
                request.predicate = predicate
                request.sortDescriptors = [NSSortDescriptor(key: dateKey, ascending: ascending)]
                request.fetchLimit = 1
                request.propertiesToFetch = [dateKey]
                box.value = .success(try context.fetch(request).first?.value(forKey: dateKey) as? Date)
            } catch {
                box.value = .failure(error)
            }
        }
        return try box.value!.get()
    }

    static func project(_ thought: Thought) -> DiscoverySourceSnapshot {
        let assignments = (thought.tagAssignments as? Set<ThoughtTagAssignment>) ?? []
        let tagNames = assignments
            .filter { $0.rejectedAt == nil }
            .compactMap { $0.tag?.name }
        let topics = (thought.topics as? Set<Topic>) ?? []
        let topicIDs = topics.map { $0.id.uuidString }
        let createdTaskIDs = ((thought.createdTasks as? Set<TodoTask>) ?? [])
            .map { $0.id.uuidString }

        return DiscoverySourceSnapshot(
            domain: .thought,
            kind: .thought,
            localID: thought.id.uuidString,
            occurredAt: thought.createdAt,           // 缺口 A：无独立 occurredAt，createdAt 兼发生与记录
            occurredOnlyDateKnown: false,
            recordedAt: thought.createdAt,
            text: thought.content,
            numericValue: nil,
            numericUnit: nil,
            entityRefs: (tagNames.map { "tag:\($0)" } + topicIDs.map { "topic:\($0)" }).sorted(),
            eventAnchors: createdTaskIDs.map { "task:\($0)" }.sorted(),
            revisionFields: Self.revisionFields(
                id: thought.id,
                content: thought.content,
                createdAt: thought.createdAt,
                updatedAt: thought.updatedAt,
                tagNames: tagNames.sorted(),
                topicIDs: topicIDs.sorted()
            )
        )
    }

    /// 固定字段序（发布后不可变）：域标记、id、正文、创建/修改时间、标签名序、主题 id 序。
    static func revisionFields(
        id: UUID,
        content: String,
        createdAt: Date,
        updatedAt: Date,
        tagNames: [String],
        topicIDs: [String]
    ) -> [String] {
        [
            "discovery.thought.v1",
            id.uuidString,
            content,
            Self.timestamp(createdAt),
            Self.timestamp(updatedAt),
            tagNames.sorted().joined(separator: ","),
            topicIDs.sorted().joined(separator: ","),
        ]
    }

    static func timestamp(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }

    static func uuids(refs: [String], prefix: String) -> [UUID] {
        refs.compactMap { ref in
            guard ref.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(ref.dropFirst(prefix.count)))
        }
    }

    static func values(refs: [String], prefix: String) -> [String] {
        refs.compactMap { ref in
            guard ref.hasPrefix(prefix) else { return nil }
            let value = String(ref.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
    }
}

// MARK: - 任务域

final class DiscoveryTaskAdapter: DiscoverySourceAdapting {

    let domain = DiscoverySourceDomain.task
    let sourceKind = DiscoverySourceKind.task

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext? = nil) {
        self.context = context ?? CoreDataStack.shared.viewContext
    }

    func basePredicate() -> NSPredicate {
        NSPredicate(format: "deletedFlag == NO AND deletedAt == nil AND archived == NO")
    }

    func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "id IN %@", localIDs),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let tagNames = DiscoveryThoughtAdapter.values(refs: topicRefs, prefix: "tag:")
        let goalIDs = DiscoveryThoughtAdapter.uuids(refs: topicRefs, prefix: "goal:")
        guard !tagNames.isEmpty || !goalIDs.isEmpty else { return [] }
        var orPredicates: [NSPredicate] = []
        if !tagNames.isEmpty {
            orPredicates.append(NSPredicate(format: "ANY tags.name IN %@", tagNames))
        }
        if !goalIDs.isEmpty {
            orPredicates.append(NSPredicate(format: "goal.id IN %@", goalIDs))
        }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                orPredicates.count == 1 ? orPredicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: orPredicates),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let taskIDs = DiscoveryThoughtAdapter.uuids(refs: anchorRefs, prefix: "task:")
        let goalIDs = DiscoveryThoughtAdapter.uuids(refs: anchorRefs, prefix: "goal:")
        let thoughtIDs = DiscoveryThoughtAdapter.uuids(refs: anchorRefs, prefix: "thought:")
        guard !taskIDs.isEmpty || !goalIDs.isEmpty || !thoughtIDs.isEmpty else { return [] }
        var orPredicates: [NSPredicate] = []
        if !taskIDs.isEmpty { orPredicates.append(NSPredicate(format: "id IN %@", taskIDs)) }
        if !goalIDs.isEmpty { orPredicates.append(NSPredicate(format: "goal.id IN %@", goalIDs)) }
        if !thoughtIDs.isEmpty { orPredicates.append(NSPredicate(format: "sourceThought.id IN %@", thoughtIDs)) }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                orPredicates.count == 1 ? orPredicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: orPredicates),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !keyword.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "title CONTAINS[cd] %@ OR desc CONTAINS[cd] %@", keyword, keyword),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                windowPredicate(on: "createdAt", window: window),
            ]),
            limit: limit
        )
    }

    func availability() throws -> DiscoverySourceAvailability {
        let box = DiscoveryAdapterSyncBox<Date?>()
        context.performAndWait { [context] in
            do {
                let request = TodoTask.fetchRequest()
                request.predicate = basePredicate()
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
                request.fetchLimit = 1
                request.propertiesToFetch = ["createdAt"]
                box.value = .success(try context.fetch(request).first?.createdAt)
            } catch {
                box.value = .failure(error)
            }
        }
        return DiscoverySourceAvailability(earliestRecordAt: try box.value!.get())
    }

    // MARK: - 投影

    private func fetch(predicate: NSPredicate, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let box = DiscoveryAdapterSyncBox<[DiscoverySourceSnapshot]>()
        context.performAndWait { [context] in
            do {
                let request = TodoTask.fetchRequest()
                request.predicate = predicate
                request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
                request.fetchLimit = limit
                box.value = .success(try context.fetch(request).map(Self.project))
            } catch {
                box.value = .failure(error)
            }
        }
        return try box.value!.get()
    }

    static func project(_ task: TodoTask) -> DiscoverySourceSnapshot {
        let goalRef = task.goal.map { "goal:\($0.id.uuidString)" }
        let sourceThoughtRef = task.sourceThought.map { "thought:\($0.id.uuidString)" }
        let tagNames = ((task.tags as? Set<TodoTag>) ?? []).map { $0.name }

        return DiscoverySourceSnapshot(
            domain: .task,
            kind: .task,
            localID: task.id.uuidString,
            // 完成事件=completedAt 有值；未完成任务无发生时间（F10：不推断拖延）
            occurredAt: task.completedAt,
            occurredOnlyDateKnown: false,
            recordedAt: task.createdAt,
            text: Self.text(title: task.title, desc: task.desc),
            numericValue: nil,
            numericUnit: nil,
            entityRefs: ([goalRef, sourceThoughtRef].compactMap { $0 } + tagNames.map { "tag:\($0)" }).sorted(),
            eventAnchors: ["task:\(task.id.uuidString)"],
            revisionFields: Self.revisionFields(
                id: task.id,
                title: task.title,
                desc: task.desc,
                status: task.status,
                completedAt: task.completedAt,
                dueDate: task.dueDate,
                goalID: task.goal?.id.uuidString,
                checkItemsDigest: Self.checkItemsDigest(task.checkItems as? Set<CheckItem>),
                createdAt: task.createdAt
            )
        )
    }

    /// 原文材料：标题 + 描述（无描述只留标题）
    static func text(title: String, desc: String?) -> String {
        guard let desc, !desc.isEmpty else { return title }
        return title + "\n" + desc
    }

    /// 子任务确定性摘要（order 升序 → 标题=勾选态）
    static func checkItemsDigest(_ checkItems: Set<CheckItem>?) -> String {
        let items = (checkItems ?? [])
            .sorted { $0.order != $1.order ? $0.order < $1.order : $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.title)=\($0.isChecked ? "1" : "0")" }
        return items.joined(separator: ";")
    }

    /// 固定字段序（发布后不可变）：域标记、id、标题、描述、状态、完成时间、截止、
    /// 目标 id、子任务摘要、创建时间。
    static func revisionFields(
        id: UUID,
        title: String,
        desc: String?,
        status: String,
        completedAt: Date?,
        dueDate: Date?,
        goalID: String?,
        checkItemsDigest: String,
        createdAt: Date
    ) -> [String] {
        [
            "discovery.task.v1",
            id.uuidString,
            title,
            desc ?? "",
            status,
            completedAt.map(DiscoveryThoughtAdapter.timestamp) ?? "",
            dueDate.map(DiscoveryThoughtAdapter.timestamp) ?? "",
            goalID ?? "",
            checkItemsDigest,
            DiscoveryThoughtAdapter.timestamp(createdAt),
        ]
    }
}

// MARK: - 习惯事件域

final class DiscoveryHabitAdapter: DiscoverySourceAdapting {

    let domain = DiscoverySourceDomain.habit
    let sourceKind = DiscoverySourceKind.habitEvent

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext? = nil) {
        self.context = context ?? CoreDataStack.shared.viewContext
    }

    func basePredicate() -> NSPredicate {
        // 事件级软删排除；归档习惯的历史记录仍是真实事件，V1 照读（只排除软删）
        NSPredicate(format: "deletedAt == nil")
    }

    func fetchSnapshots(localIDs: [String], limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !localIDs.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "id IN %@", localIDs),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(topicRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        try fetchAnchors(anchorRefs: topicRefs, window: window, limit: limit)
    }

    func fetchSnapshots(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        try fetchAnchors(anchorRefs: anchorRefs, window: window, limit: limit)
    }

    private func fetchAnchors(anchorRefs: [String], window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let habitIDs = DiscoveryThoughtAdapter.uuids(refs: anchorRefs, prefix: "habit:")
        let goalIDs = DiscoveryThoughtAdapter.uuids(refs: anchorRefs, prefix: "goal:")
        guard !habitIDs.isEmpty || !goalIDs.isEmpty else { return [] }
        var orPredicates: [NSPredicate] = []
        if !habitIDs.isEmpty {
            orPredicates.append(NSPredicate(format: "habitId IN %@", habitIDs))
        }
        if !goalIDs.isEmpty {
            orPredicates.append(NSPredicate(format: "habit.goal.id IN %@", goalIDs))
        }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                orPredicates.count == 1 ? orPredicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: orPredicates),
                windowPredicate(on: "date", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(keyword: String, window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        guard !keyword.isEmpty else { return [] }
        return try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                NSPredicate(format: "note CONTAINS[cd] %@ OR habit.name CONTAINS[cd] %@", keyword, keyword),
                windowPredicate(on: "date", window: window),
            ]),
            limit: limit
        )
    }

    func fetchSnapshots(window: DiscoveryTimeWindow, limit: Int) throws -> [DiscoverySourceSnapshot] {
        try fetch(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                basePredicate(),
                windowPredicate(on: "date", window: window),
            ]),
            limit: limit
        )
    }

    func availability() throws -> DiscoverySourceAvailability {
        let box = DiscoveryAdapterSyncBox<Date?>()
        context.performAndWait { [context] in
            do {
                let request = HabitRecord.fetchRequest()
                request.predicate = basePredicate()
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
                request.fetchLimit = 1
                request.propertiesToFetch = ["date"]
                box.value = .success(try context.fetch(request).first?.date)
            } catch {
                box.value = .failure(error)
            }
        }
        return DiscoverySourceAvailability(earliestRecordAt: try box.value!.get())
    }

    // MARK: - 投影

    private func fetch(predicate: NSPredicate, limit: Int) throws -> [DiscoverySourceSnapshot] {
        let box = DiscoveryAdapterSyncBox<[DiscoverySourceSnapshot]>()
        context.performAndWait { [context] in
            do {
                let request = HabitRecord.fetchRequest()
                request.predicate = predicate
                request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                request.fetchLimit = limit
                box.value = .success(try context.fetch(request).map(Self.project))
            } catch {
                box.value = .failure(error)
            }
        }
        return try box.value!.get()
    }

    static func project(_ record: HabitRecord) -> DiscoverySourceSnapshot {        // 定义只取 id/name/type/unit/isBadHabit，不回写、不推断历史达标（G0 §1.3）
        let habit = record.habit
        let habitName = habit?.name ?? ""
        let habitType = habit.map { Int($0.type) } ?? 0
        let unit = habit?.unit
        let isBadHabit = habit?.isBadHabit ?? false

        return DiscoverySourceSnapshot(
            domain: .habit,
            kind: .habitEvent,
            localID: record.id.uuidString,
            occurredAt: record.date,
            // 补签 date=目标日零点（retroactiveCheckIn 写 startOfDay）：只知道日期，不编时刻（T31）
            occurredOnlyDateKnown: record.isRetroactive,
            recordedAt: record.createdAt,
            text: Self.text(
                habitName: habitName,
                isCheckIn: habitType == 0,
                isCompleted: record.isCompleted,
                value: record.value?.doubleValue,
                unit: unit,
                note: record.note,
                isRetroactive: record.isRetroactive
            ),
            numericValue: record.value?.doubleValue,
            numericUnit: unit,
            entityRefs: Self.entityRefs(habitID: record.habitId, goal: habit?.goal),
            eventAnchors: ["habitEvent:\(record.id.uuidString)"],
            revisionFields: Self.revisionFields(
                recordID: record.id,
                habitID: record.habitId,
                date: record.date,
                isCompleted: record.isCompleted,
                value: record.value?.doubleValue,
                note: record.note,
                isRetroactive: record.isRetroactive,
                createdAt: record.createdAt,
                habitName: habitName,
                habitType: habitType,
                unit: unit,
                isBadHabit: isBadHabit
            )
        )
    }

    /// 习惯事件显式关联：习惯 id + 目标 id
    static func entityRefs(habitID: UUID, goal: Goal?) -> [String] {
        var refs = ["habit:\(habitID.uuidString)"]
        if let goal {
            refs.append("goal:\(goal.id.uuidString)")
        }
        return refs
    }

    /// 习惯事件构成文：定义名 + 动作/数值 + 备注（+补签标记）。
    /// 原文=结构化字段与备注，不虚构叙述。
    static func text(
        habitName: String,
        isCheckIn: Bool,
        isCompleted: Bool,
        value: Double?,
        unit: String?,
        note: String?,
        isRetroactive: Bool
    ) -> String {
        var parts: [String] = ["习惯「\(habitName)」"]
        if isCheckIn {
            parts.append(isCompleted ? "打卡" : "取消打卡")
        }
        if let value {
            parts.append("记录 \(Self.numberText(value))\(unit ?? "")")
        }
        if let note, !note.isEmpty {
            parts.append("备注：\(note)")
        }
        if isRetroactive {
            parts.append("补签（只知道日期）")
        }
        return parts.joined(separator: "；")
    }

    /// 数值显式记录（定点：整数十进制、非整数保留必要位数；确定性输出）
    static func numberText(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.4g", value)
    }

    /// 固定字段序（发布后不可变）：域标记、记录 id、习惯 id、发生时间、完成态、数值、
    /// 备注、补签、记录时间、定义名/类型/单位/坏习惯标记（定义字段参与版本：
    /// 定义改名/换单位都会使依赖该记录的发现进入核版本失败路径）。
    static func revisionFields(
        recordID: UUID,
        habitID: UUID,
        date: Date,
        isCompleted: Bool,
        value: Double?,
        note: String?,
        isRetroactive: Bool,
        createdAt: Date,
        habitName: String,
        habitType: Int,
        unit: String?,
        isBadHabit: Bool
    ) -> [String] {
        [
            "discovery.habitEvent.v1",
            recordID.uuidString,
            habitID.uuidString,
            DiscoveryThoughtAdapter.timestamp(date),
            isCompleted ? "1" : "0",
            value.map(Self.numberText) ?? "",
            note ?? "",
            isRetroactive ? "1" : "0",
            DiscoveryThoughtAdapter.timestamp(createdAt),
            habitName,
            String(habitType),
            unit ?? "",
            isBadHabit ? "1" : "0",
        ]
    }
}

// MARK: - 公共小工具

/// 窗口谓词（[start, end) 左闭右开）
func DiscoveryWindowPredicate(on key: String, window: DiscoveryTimeWindow) -> NSPredicate {
    NSPredicate(format: "%K >= %@ AND %K < %@", key, window.start as NSDate, key, window.end as NSDate)
}

private func windowPredicate(on key: String, window: DiscoveryTimeWindow) -> NSPredicate {
    DiscoveryWindowPredicate(on: key, window: window)
}
