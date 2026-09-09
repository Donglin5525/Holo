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
        container.loadPersistentStores { _, error in
            if let error {
                widgetIntentLogger.error("小组件共享库加载失败: \(error.localizedDescription)")
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
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            guard let task = try context.fetch(request).first else { return }

            // 与 App 内完成口径一致：已完成→撤回；重复任务→完成并生成下一次；普通任务→完成
            if task.completed {
                try TodoCompletionCore.uncomplete(task, in: context)
            } else if task.repeatRule != nil {
                _ = try TodoCompletionCore.completeRepeating(task, in: context)
            } else {
                try TodoCompletionCore.complete(task, in: context)
            }
            HoloWidgetHabitTodoSnapshotWriter.refreshTodoSnapshot(context: context)
        }
        return .result()
    }
}
