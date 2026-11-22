import CoreData

struct HabitFolderSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let emoji: String?
    let sticker: ResolvedPlacement
}

enum HabitFolderDecoration: Equatable {
    case emoji(String)
    case sticker(UUID, VisualPlacementPayload.Presentation?)
    case clear
}

extension HabitFolder {
    static let visualOwnerKind = "habitFolder"
    static let visualSlot = "icon"

    static func fetchRequest(id: UUID) -> NSFetchRequest<HabitFolder> {
        let request = NSFetchRequest<HabitFolder>(entityName: "HabitFolder")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return request
    }

    static func resolveSticker(id: UUID, in context: NSManagedObjectContext) -> ResolvedPlacement {
        VisualAssetRepository.shared.resolvePlacement(ownerKind: visualOwnerKind, ownerKey: id.uuidString,
                                                      slot: visualSlot, in: context)
    }
}

extension HabitRepository {
    func fetchFolderSummaries() throws -> [HabitFolderSummary] {
        try fetchFolders(in: context).map { folder in
            HabitFolderSummary(id: folder.id, name: folder.name, emoji: folder.emoji,
                               sticker: HabitFolder.resolveSticker(id: folder.id, in: context))
        }
    }

    /// 新建或重命名时可同时移入习惯，整批作为一次保存。
    @discardableResult
    func saveFolder(id: UUID?, name: String, adding habitIDs: Set<UUID>,
                    decoration: HabitFolderDecoration? = nil,
                    expectedSticker: ResolvedPlacement = .none) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HabitError.invalidData }
        let folderID = id ?? UUID()
        try changeFolders(serializesVisualWrite: decoration != nil) { store in
            let folders = try fetchFolders(in: store)
            let folder: HabitFolder
            if id != nil {
                guard let existing = folders.first(where: { $0.id == folderID }) else { throw HabitError.notFound }
                folder = existing
            } else {
                folder = HabitFolder(context: store)
                folder.id = folderID
                folder.sortOrder = (folders.last?.sortOrder ?? -1) + 1
            }
            folder.name = trimmed
            try assignHabits(habitIDs, to: folderID, in: store)
            if let decoration {
                try applyDecoration(decoration, expectedSticker: expectedSticker, to: folder, in: store)
            }
        }
        if decoration != nil {
            NotificationCenter.default.post(name: .visualAssetsDidChange, object: nil)
        }
        return folderID
    }

    func moveHabit(_ habitID: UUID, to folderID: UUID?) throws {
        try changeFolders { store in
            if let folderID, try !fetchFolders(in: store).contains(where: { $0.id == folderID }) {
                throw HabitError.notFound
            }
            try assignHabits([habitID], to: folderID, in: store)
        }
    }

    func deleteFolder(id: UUID) throws {
        try changeFolders { store in
            guard let folder = try fetchFolders(in: store).first(where: { $0.id == id }) else {
                throw HabitError.notFound
            }
            let request = Habit.fetchRequest()
            // 已归档、暂停和回收站内的习惯一并解除归属，恢复时也能直接从未分组找到。
            request.predicate = NSPredicate(format: "folderID == %@", id as CVarArg)
            for habit in try store.fetch(request) {
                habit.folderID = nil
            }
            store.delete(folder)
        }
    }

    func updateFolderOrder(_ ids: [UUID]) throws {
        try changeFolders { store in
            let folders = try fetchFolders(in: store)
            let ranks = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            let ordered = folders.sorted {
                (ranks[$0.id] ?? ids.count, $0.sortOrder, $0.id.uuidString)
                    < (ranks[$1.id] ?? ids.count, $1.sortOrder, $1.id.uuidString)
            }
            for (index, folder) in ordered.enumerated() {
                folder.sortOrder = Int64(index)
            }
        }
    }

    private func fetchFolders(in store: NSManagedObjectContext) throws -> [HabitFolder] {
        let request = NSFetchRequest<HabitFolder>(entityName: "HabitFolder")
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        return try store.fetch(request).sorted {
            ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString)
        }
    }

    private func assignHabits(_ ids: Set<UUID>, to folderID: UUID?, in store: NSManagedObjectContext) throws {
        guard !ids.isEmpty else { return }
        let request = Habit.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@ AND deletedAt == nil", Array(ids))
        let habits = try store.fetch(request)
        guard Set(habits.map(\.id)) == ids else { throw HabitError.notFound }
        for habit in habits {
            habit.folderID = folderID
        }
    }

    private func applyDecoration(_ decoration: HabitFolderDecoration, expectedSticker: ResolvedPlacement,
                                 to folder: HabitFolder, in store: NSManagedObjectContext) throws {
        let visual = VisualAssetRepository.shared
        let current = HabitFolder.resolveSticker(id: folder.id, in: store)
        guard current == expectedSticker, current.allowsFolderDecoration else { throw HabitError.saveFailed }
        let payload: VisualPlacementPayload
        switch decoration {
        case .emoji(let emoji):
            folder.emoji = emoji
            payload = .clear
        case .clear:
            folder.emoji = nil
            payload = .clear
        case .sticker(let id, let presentation):
            guard let asset = visual.findAsset(byID: id, in: store), !visual.hasTombstone(assetID: id, in: store),
                  let kind = VisualAssetKind.from(raw: asset.value(forKey: "kind") as? String) else {
                throw HabitError.notFound
            }
            folder.emoji = nil
            payload = .setAsset(.asset(id), presentation: presentation)
            try payload.validate(kind: kind)
        }
        if payload.action == .set || current != .none {
            try visual.stageRevisionLocked(operationID: UUID(), ownerKind: HabitFolder.visualOwnerKind,
                                           ownerKey: folder.id.uuidString, slot: HabitFolder.visualSlot,
                                           payload: payload, in: store)
        }
    }

    /// 文件夹、成员和贴纸位置在同一独立上下文保存。
    private func changeFolders(serializesVisualWrite: Bool = false,
                               _ edit: (NSManagedObjectContext) throws -> Void) throws {
        let store = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        store.persistentStoreCoordinator = context.persistentStoreCoordinator
        func save() throws -> [String: Any] {
            try edit(store)
            store.processPendingChanges()
            let inserted = store.insertedObjects
            let updated = store.updatedObjects.map(\.objectID)
            let deleted = store.deletedObjects.map(\.objectID)
            try store.save()
            return [
                NSInsertedObjectsKey: inserted.map(\.objectID),
                NSUpdatedObjectsKey: updated,
                NSDeletedObjectsKey: deleted
            ]
        }
        let changes = try serializesVisualWrite ? VisualAssetRepository.shared.performCommitLocked(save) : save()
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
        loadActiveHabits()
        notifyDataChange()
    }
}

extension ResolvedPlacement {
    var allowsFolderDecoration: Bool {
        switch self {
        case .none, .assetReady, .deleted: return true
        case .recordSelected, .pending, .unsupported, .corrupt: return false
        }
    }
}
