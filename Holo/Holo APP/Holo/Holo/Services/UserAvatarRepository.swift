//
//  UserAvatarRepository.swift
//  Holo
//
//  Holo 用户头像的唯一读写入口：本地即时展示，随 Core Data 私有库同步到 iCloud。
//

import CoreData
import Combine
import Foundation
import OSLog
import UIKit

enum UserAvatarState: String {
    case unset
    case custom
    case removed
}

@MainActor
final class UserAvatarRepository: ObservableObject {

    static let shared = UserAvatarRepository()
    static let primaryProfileKey = "primary"

    @Published private(set) var state: UserAvatarState = .unset
    @Published private(set) var image: UIImage?

    var hasCustomAvatar: Bool { state == .custom && image != nil }

    private let logger = Logger(subsystem: "com.holo.app", category: "UserAvatar")
    private lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext
    private var remoteChangeObserver: NSObjectProtocol?
    private var reloadDebounce: Task<Void, Never>?
    private var isReady = false

    private init() {}

    func setup() {
        guard !isReady else { return }
        isReady = true

        repairDuplicatesAndReload()
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: CoreDataStack.shared.persistentContainer.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReload()
            }
        }
    }

    func saveAvatarData(_ data: Data) throws {
        guard data.count <= UserAvatarImageProcessor.maximumOutputBytes,
              UIImage(data: data) != nil else {
            throw UserAvatarImageProcessor.ProcessingError.encodingFailed
        }
        try persist(state: .custom, avatarData: data)
    }

    /// 删除不是“没有记录”，而是一条可同步意图，防止旧设备把历史头像重新带回来。
    func removeAvatar() throws {
        try persist(state: .removed, avatarData: nil)
    }

    /// 账号与数据删除完成后立即清空内存展示；持久层由统一删除服务负责。
    func resetPublishedStateAfterAccountDeletion() {
        state = .unset
        image = nil
    }

    private func persist(state newState: UserAvatarState, avatarData: Data?) throws {
        let rows = fetchRows()
        let winner = rows.max(by: { Self.isOlder($0, than: $1) })
        let entity = winner ?? UserAvatarEntity(context: context)
        for stale in rows where stale !== entity {
            context.delete(stale)
        }

        entity.profileKey = Self.primaryProfileKey
        entity.state = newState.rawValue
        entity.avatarData = avatarData
        entity.revision = (rows.map(\UserAvatarEntity.revision).max() ?? 0) + 1
        entity.updatedAt = Date()
        entity.mutationID = UUID().uuidString
        try context.save()

        apply(entity)
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.repairDuplicatesAndReload()
        }
    }

    private func repairDuplicatesAndReload() {
        let rows = fetchRows()
        guard let winner = rows.max(by: { Self.isOlder($0, than: $1) }) else {
            state = .unset
            image = nil
            return
        }

        for stale in rows where stale !== winner {
            context.delete(stale)
        }
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                logger.error("修复重复头像记录失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        apply(winner)
    }

    private func fetchRows() -> [UserAvatarEntity] {
        let request = UserAvatarEntity.fetchRequest()
        request.predicate = NSPredicate(format: "profileKey == %@", Self.primaryProfileKey)
        do {
            return try context.fetch(request)
        } catch {
            logger.error("读取头像失败：\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func apply(_ entity: UserAvatarEntity) {
        let resolvedState = UserAvatarState(rawValue: entity.state) ?? .unset
        state = resolvedState
        if resolvedState == .custom,
           let data = entity.avatarData,
           let decoded = UIImage(data: data) {
            image = decoded
        } else {
            image = nil
        }
    }

    private static func isOlder(_ lhs: UserAvatarEntity, than rhs: UserAvatarEntity) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.mutationID < rhs.mutationID
    }
}
