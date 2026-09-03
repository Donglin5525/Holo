//
//  UserPreferenceRepository.swift
//  Holo
//
//  用户级偏好设置仓库（键值对，跟随 iCloud 同步）
//  写入即上行 CloudKit；云端恢复/变更落地时按采纳规则回流到本地显示。
//

import Foundation
import CoreData
import os.log

/// 用户级偏好设置仓库
@MainActor
final class UserPreferenceRepository {

    static let shared = UserPreferenceRepository()

    private let logger = Logger(subsystem: "com.holo.app", category: "UserPreference")

    /// 昵称在同步表里的键
    static let displayNameKey = "userDisplayName"

    private lazy var context: NSManagedObjectContext = CoreDataStack.shared.viewContext

    private var remoteChangeObserver: NSObjectProtocol?
    private var isReady = false

    private init() {}

    /// 延迟初始化：注册云同步变更监听 + 修复重复行 + 首轮采纳
    /// 在 HomeView 的 .task {}（store 加载完成后）调用
    func setup() {
        guard !isReady else { return }
        isReady = true

        repairDuplicates()

        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: CoreDataStack.shared.persistentContainer.persistentStoreCoordinator,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adoptCloudValues()
                self?.adoptCloudBackedSettings()
            }
        }

        adoptCloudValues()
        adoptCloudBackedSettings()
    }

    // MARK: - 读写

    func value(forKey key: String) -> String? {
        let request = UserPreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        let rows = (try? context.fetch(request)) ?? []
        guard let latest = rows.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return latest.value
    }

    func set(_ value: String, forKey key: String) {
        let request = UserPreferenceEntity.fetchRequest()
        request.predicate = NSPredicate(format: "key == %@", key)
        let rows = (try? context.fetch(request)) ?? []

        guard let latest = rows.max(by: { $0.updatedAt < $1.updatedAt }) else {
            let entity = UserPreferenceEntity(context: context)
            entity.key = key
            entity.value = value
            entity.updatedAt = Date()
            try? context.save()
            return
        }

        for stale in rows where stale !== latest { context.delete(stale) }
        if latest.value != value {
            latest.value = value
            latest.updatedAt = Date()
        }
        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - 昵称统一出口

    /// 昵称保存的唯一通道：本地立即生效 + 同步表上行 iCloud。
    /// 引导页、个人页、设置页三个入口共用，保证「本次安装主动设置」标记与云端值始终一致。
    func setDisplayName(_ rawName: String) {
        guard let name = UserDisplayNameSettings.normalizedDisplayName(rawName) else { return }
        UserDisplayNameSettings.standard.saveDisplayName(name)
        set(name, forKey: Self.displayNameKey)
    }

    // MARK: - 云同步重复修复

    /// 与首页图标配置同源的竞态：卸载重装后种子写入与 iCloud 恢复并存时，
    /// 同一 key 会出现多行。只保留 updatedAt 最新的一行，其余删除。
    private func repairDuplicates() {
        let request = UserPreferenceEntity.fetchRequest()
        guard let all = try? context.fetch(request), !all.isEmpty else { return }

        var grouped: [String: [UserPreferenceEntity]] = [:]
        for entity in all {
            grouped[entity.key, default: []].append(entity)
        }

        let duplicates = grouped.values.flatMap { group in
            group.sorted { $0.updatedAt > $1.updatedAt }.dropFirst()
        }
        guard !duplicates.isEmpty else { return }

        duplicates.forEach { context.delete($0) }
        try? context.save()
    }

    // MARK: - 昵称采纳

    /// 云端值落地为本地显示名。
    /// 冲突规则：本次安装里用户主动设置过昵称（如引导页填写）→ 本地意图优先，
    /// 云端不覆盖；没设置过（如跳过引导）→ 采纳云端恢复的名字。
    private func adoptCloudValues() {
        let settings = UserDisplayNameSettings.standard
        guard !settings.hasSetDisplayNameThisInstall else { return }
        guard let cloudName = value(forKey: Self.displayNameKey),
              !cloudName.isEmpty else { return }
        guard cloudName != settings.displayName else { return }

        settings.adoptCloudDisplayName(cloudName)
        logger.info("昵称已从 iCloud 采纳（本次安装未主动设置过）")
    }

    /// 严格预算模式与自定义 Prompt 的云备份恢复/建立（随 remote change 防抖反复调用，均幂等）
    private func adoptCloudBackedSettings() {
        FinanceBudgetSettings.shared.restoreFromCloudIfClean()
        PromptManager.shared.restoreFromCloudIfClean()
    }
}
