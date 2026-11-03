import Foundation
import CoreData
import Combine
import OSLog

/// 活跃一级分类的共享名称索引。列表行只查内存，分类编辑与 iCloud 合并后统一刷新。
@MainActor
final class FinanceCategoryNameCache: ObservableObject {
    static let shared = FinanceCategoryNameCache(context: CoreDataStack.shared.viewContext)

    @Published private(set) var names: [UUID: String] = [:]
    @Published private(set) var revision = 0
    private var types: [UUID: String] = [:]
    private let context: NSManagedObjectContext
    private var observer: NSObjectProtocol?
    private var refreshScheduled = false
    private let logger = Logger(subsystem: "com.holo.app", category: "FinanceCategoryNameCache")

    init(context: NSManagedObjectContext) {
        self.context = context
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: .main
        ) { [weak self] notification in
            let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey,
                        NSRefreshedObjectsKey, NSInvalidatedObjectsKey]
            let categoryChanged = notification.userInfo?[NSInvalidatedAllObjectsKey] != nil
                || keys.contains { key in
                    (notification.userInfo?[key] as? Set<NSManagedObject>)?
                        .contains { $0.entity.name == "Category" } == true
                }
            guard categoryChanged else { return }
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func scheduleReload() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refreshScheduled = false
            self.reload()
        }
    }

    func parentName(for category: Category) -> String? {
        guard let parentID = category.parentId, types[parentID] == category.type else { return nil }
        return names[parentID]
    }

    private func reload() {
        let request = Category.fetchRequest()
        request.predicate = NSPredicate(format: "parentId == nil AND deletedAt == nil")
        do {
            let categories = DuplicateRowFilter.deduplicatingCopies(try context.fetch(request))
            let updated = Dictionary(categories.map { ($0.id, $0.name) },
                                     uniquingKeysWith: { first, _ in first })
            types = Dictionary(categories.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })
            if updated != names { names = updated }
            // 子分类归属变化也必须通知账单行，即使一级名称没有变化。
            revision &+= 1
        } catch {
            logger.error("分类名称索引刷新失败：\(error.localizedDescription)")
        }
    }
}
