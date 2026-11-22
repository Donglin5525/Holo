//
//  HoloWidgetIntents.swift
//  HoloWidgets
//
//  桌面小组件的就地交互意图：打卡习惯、勾选待办。
//  数据库自 1.0.3 起迁入 App Group 共享区，动作在本扩展进程内直接落库，
//  CloudKit 镜像仍由主 App 进程驱动；这里只开普通容器读写同一份库。
//

import AppIntents
import CoreData
import OSLog
import WidgetKit

private let widgetIntentLogger = Logger(subsystem: "com.holo.app", category: "HoloWidgetIntents")

// MARK: - 小组件进程独立数据容器

@MainActor
struct HoloWidgetDataStore {
    static let shared = HoloWidgetDataStore()

    /// 普通 NSPersistentContainer：扩展进程不做 CloudKit 镜像（entitlements 也未含 iCloud）
    /// 2026-10-26 共享库迁移乒乓数据事故收口：装载前先走与主 App 相同的只读指纹预检，
    /// 库与当前模型指纹不一致时拒绝打开（扩展进程绝不成为「静默迁移共享库」的入口），
    /// 指纹一致才装载；被拒绝时意图动作会失败并留日志，库文件原样保留。
    let container: NSPersistentContainer = {
        let container = NSPersistentContainer(
            name: "HoloDataModel",
            managedObjectModel: CoreDataStack.shared.createDataModel()
        )
        let description = NSPersistentStoreDescription(url: CoreDataStack.sharedStoreURL)
        description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        if let rejection = CoreDataStack.storeFingerprintRejection(
            at: CoreDataStack.sharedStoreURL,
            model: CoreDataStack.shared.createDataModel()
        ) {
            widgetIntentLogger.fault("小组件共享库指纹预检拒绝打开（原库原地保留，绝不自动迁移）：\(rejection.localizedDescription)")
        } else {
            container.loadPersistentStores { _, error in
                if let error {
                    widgetIntentLogger.error("小组件共享库加载失败: \(error.localizedDescription)")
                }
            }
        }
        return container
    }()

    var viewContext: NSManagedObjectContext { container.viewContext }
}

// MARK: - 习惯打卡

struct HoloHabitToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "打卡习惯"
    static let description = IntentDescription("切换这个习惯的今日打卡状态。")

    @Parameter(title: "习惯")
    var habitID: String

    init() {}

    init(habitID: String) {
        self.habitID = habitID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: habitID) else { return .result() }
        try await MainActor.run {
            let repository = HabitRepository(
                context: HoloWidgetDataStore.shared.viewContext,
                observesRemoteChanges: false
            )
            repository.setup()
            guard let habit = repository.getActiveHabits().first(where: { $0.id == id }) else { return }
            _ = try repository.toggleCheckIn(for: habit)
            HoloWidgetHabitTodoSnapshotWriter.refreshHabitSnapshot(repository: repository)
        }
        return .result()
    }
}

// MARK: - 待办勾选

struct HoloTodoToggleIntent: AppIntent {
    static let title: LocalizedStringResource = "勾选待办"
    static let description = IntentDescription("切换这条待办的完成状态。")

    @Parameter(title: "待办")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        try await MainActor.run {
            let context = HoloWidgetDataStore.shared.viewContext
            let request = TodoTask.fetchRequest()
            // 桌面快照可能仍显示已进回收站的任务；软删任务不得被小组件翻转完成态（2026-10-31 审计 A2）
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil", id as CVarArg)
            request.fetchLimit = 1
            guard let task = try context.fetch(request).first else { return }

            // 与 App 内完成口径一致：已完成→撤回；重复任务→完成并生成下一次；普通任务→完成
            if task.completed {
                try TodoCompletionCore.uncomplete(task, in: context)
            } else if task.repeatRule != nil {
                _ = try TodoCompletionCore.completeRepeating(task, in: context)
            } else {
                try TodoCompletionCore.complete(task, in: context, sourceSurface: "widget")
            }
            HoloWidgetHabitTodoSnapshotWriter.refreshTodoSnapshot(context: context)
        }
        return .result()
    }
}

// MARK: - 想法随机漫步「换一条」

struct HoloThoughtWalkShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "换一条想法"
    static let description = IntentDescription("随机换一条过往想法显示在桌面上。")

    init() {}

    func perform() async throws -> some IntentResult {
        let store = HoloWidgetSnapshotStore()
        guard let pool = store.readThoughtWalkPool(), !pool.items.isEmpty else { return .result() }

        // 只在池内且不与当前显示条重复的候选里随机
        let current = store.resolvedThoughtWalkItem()
        let candidates = pool.items.filter { $0.thoughtId != current?.thoughtId }
        guard let picked = candidates.randomElement() else { return .result() }

        // 手选当天内有效：主 App 刷新候选池也不会弹回当日主推，次日自动恢复轮换
        try? store.writeThoughtWalkSelection(
            HoloWidgetThoughtWalkSelection(thoughtId: picked.thoughtId, date: Date())
        )
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.thoughtMemory.rawValue)
        return .result()
    }
}

// MARK: - 每日洞察「换一条」

struct HoloInsightShuffleIntent: AppIntent {
    static let title: LocalizedStringResource = "换一条发现"
    static let description = IntentDescription("切换另一条 AI 观察显示在桌面上。")

    init() {}

    func perform() async throws -> some IntentResult {
        let store = HoloWidgetSnapshotStore()
        guard let pool = store.readInsightPool(), pool.items.count > 1 else { return .result() }

        let current = store.resolvedInsightItem()
        let currentIndex = pool.items.firstIndex(where: { $0.id == current?.id }) ?? 0
        let nextIndex = (currentIndex + 1) % pool.items.count
        let picked = pool.items[nextIndex]

        try? store.writeInsightSelection(
            HoloWidgetInsightSelection(insightId: picked.id, date: Date())
        )
        WidgetCenter.shared.reloadTimelines(ofKind: HoloWidgetKind.dailyInsight.rawValue)
        return .result()
    }
}

// MARK: - 小组件配置意图（长按「编辑小组件」）

struct HoloDailyKanbanConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "今日全览配置"
    static let description = IntentDescription("自定义今日全览的隐私脱敏选项。")

    @Parameter(title: "隐藏支出金额", default: false)
    var hideSensitiveAmount: Bool
}

struct HoloInsightConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "一个发现配置"
    static let description = IntentDescription("自定义每日洞察的隐私保护选项。")

    @Parameter(title: "隐私脱敏模式", default: false)
    var hideSensitiveContent: Bool
}

enum HoloMemoryWidgetStyle: String, AppEnum {
    case heatmap
    case onThisDay

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "展示样式")
    static let caseDisplayRepresentations: [HoloMemoryWidgetStyle: DisplayRepresentation] = [
        .heatmap: DisplayRepresentation(title: "生活热力图"),
        .onThisDay: DisplayRepresentation(title: "历史上的今天")
    ]
}

struct HoloMemoryConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "记忆长廊配置"
    static let description = IntentDescription("选择展示生活热力图或历史上的今天。")

    @Parameter(title: "展示样式", default: .heatmap)
    var style: HoloMemoryWidgetStyle

    @Parameter(title: "隐藏回忆正文", default: false)
    var hideSensitiveContent: Bool
}

struct HoloFinanceConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "本月收支配置"
    static let description = IntentDescription("自定义本月收支小组件的隐私脱敏选项。")

    @Parameter(title: "隐藏具体金额", default: false)
    var hideSensitiveAmount: Bool
}

struct HoloGoalEntity: AppEntity {
    let id: String
    let title: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "目标")
    static let defaultQuery = HoloGoalEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct HoloGoalEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HoloGoalEntity] {
        let all = availableEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [HoloGoalEntity] {
        availableEntities()
    }

    private func availableEntities() -> [HoloGoalEntity] {
        let snapshot = HoloWidgetSnapshotStore().readGoal() ?? .sample()
        return snapshot.allGoals.map { HoloGoalEntity(id: $0.goalId.uuidString, title: $0.title) }
    }
}

struct HoloGoalConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "目标进度配置"
    static let description = IntentDescription("选择固定展示某一个目标，留空则自动展示主目标。")

    @Parameter(title: "指定目标")
    var selectedGoal: HoloGoalEntity?
}

struct HoloAnniversaryEntity: AppEntity {
    let id: String
    let title: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "纪念日")
    static let defaultQuery = HoloAnniversaryEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct HoloAnniversaryEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HoloAnniversaryEntity] {
        let all = availableEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [HoloAnniversaryEntity] {
        availableEntities()
    }

    private func availableEntities() -> [HoloAnniversaryEntity] {
        let snapshot = HoloWidgetSnapshotStore().readAnniversary() ?? .sample()
        return snapshot.items.map { HoloAnniversaryEntity(id: $0.id.uuidString, title: $0.title) }
    }
}

struct HoloAnniversaryConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "纪念日配置"
    static let description = IntentDescription("选择固定展示某一个纪念日，留空则自动展示最近的一个。")

    @Parameter(title: "指定纪念日")
    var selectedAnniversary: HoloAnniversaryEntity?
}

// MARK: - iOS 18 控制中心 / 锁屏底栏快捷启动

@available(iOS 18.0, *)
struct HoloOpenVoiceControlIntent: AppIntent {
    static let title: LocalizedStringResource = "语音问 Holo"
    static let description = IntentDescription("打开 HoloAI 并直接拉起语音输入。")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "holo://ai?voiceInput=true")!))
    }
}

@available(iOS 18.0, *)
struct HoloOpenBookkeepingControlIntent: AppIntent {
    static let title: LocalizedStringResource = "快捷记一笔"
    static let description = IntentDescription("直接打开 Holo 记账面板。")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "holo://finance/add")!))
    }
}

@available(iOS 18.0, *)
struct HoloOpenThoughtControlIntent: AppIntent {
    static let title: LocalizedStringResource = "闪念速记"
    static let description = IntentDescription("直接打开 Holo 新想法编辑器。")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "holo://thoughts/new")!))
    }
}
