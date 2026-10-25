//
//  DiscoveryInvalidationService.swift
//  Holo
//
//  「HoloAI 一个发现」G2：来源失效信号 → 立即撤销依赖该来源的发现（02 §9.3）。
//
//  监听方式仿 ThoughtSemanticChangeFeed（G0 §2 / 缺口 B）：**不挂三域 UI 通知**
//  （Thought 主写路径不发 UI 通知），统一监听 Core Data 保存通知 +
//  CloudKit 远端变更 + `.holoAIDataProcessingConsentDidChange`。
//
//  · 保存通知 → 提取三域变更对象 → "thought:/task:/habitEvent:<uuid>" sourceRefs →
//    DiscoveryStore.findingsAffected(bySourceRefs:)（含反例/统计基线/版本依赖角色）→
//    立即 invalidateFinding。离线/无网同样照撤（02 §4.4 末行：本机 store 操作，不涉网络）。
//  · Habit 定义实体变化参与 habitEvent 的 sourceRevision（名称/单位等），
//    精确受影响记录集合不可低价判定 → 保守撤销全部当前发现（02 §9.3：
//    无法保证精确范围时保守撤销，不能让缓存成为隐私旁路）。CheckItem 变化映射回
//    所属任务（task:<id>）。
//  · 授权撤回（consent change）→ 保守撤销全部当前发现。
//

import CoreData
import Foundation

@MainActor
final class DiscoveryInvalidationService: NSObject {

    /// 需要提取 sourceRef 的业务实体名
    private enum MonitoredEntity {
        static let thought = "Thought"
        static let todoTask = "TodoTask"
        static let habit = "Habit"
        static let habitRecord = "HabitRecord"
        static let checkItem = "CheckItem"
    }

    private let store: DiscoveryStore
    /// 只处理该 coordinator 的保存通知（过滤测试与独立栈；仿 ThoughtSemanticChangeFeed）
    private let businessCoordinator: NSPersistentStoreCoordinator?
    private var started = false

    init(
        store: DiscoveryStore,
        businessCoordinator: NSPersistentStoreCoordinator? = nil
    ) {
        self.store = store
        // 默认业务主栈（懒取：CoreDataStack.shared.persistentContainer 会装载 store）
        self.businessCoordinator = businessCoordinator ?? CoreDataStack.shared.persistentContainer.persistentStoreCoordinator
        super.init()
    }

    /// 挂监听（幂等）。App 启动后调用一次；测试注入独立 coordinator 与 in-memory store。
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSave(_:)),
            name: .NSManagedObjectContextDidSave, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRemoteChange(_:)),
            name: .NSPersistentStoreRemoteChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConsentChange(_:)),
            name: .holoAIDataProcessingConsentDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 事件处理

    @objc private func handleSave(_ note: Notification) {
        guard let context = note.object as? NSManagedObjectContext,
              let coordinator = businessCoordinator,
              context.persistentStoreCoordinator === coordinator
        else { return }

        // 通知由保存上下文同步发出：必须在其队列内读成值快照（托管对象不跨队列逃逸）
        let extracted: (sourceRefs: Set<String>, conservative: Bool) = context.performAndWait {
            let inserted = (note.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject>) ?? []
            let updated = (note.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? []
            let deleted = (note.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject>) ?? []
            var refs = Set<String>()
            var conservative = false
            for object in inserted.union(updated).union(deleted) {
                switch object.entity.name {
                case MonitoredEntity.thought:
                    if let id = object.value(forKey: "id") as? UUID {
                        refs.insert("thought:\(id.uuidString)")
                    }
                case MonitoredEntity.todoTask:
                    if let id = object.value(forKey: "id") as? UUID {
                        refs.insert("task:\(id.uuidString)")
                    }
                case MonitoredEntity.habitRecord:
                    if let id = object.value(forKey: "id") as? UUID {
                        refs.insert("habitEvent:\(id.uuidString)")
                    }
                case MonitoredEntity.habit:
                    // 定义字段参与 habitEvent 的 sourceRevision；受影响记录集合不精确 → 保守
                    conservative = true
                case MonitoredEntity.checkItem:
                    // 子任务参与任务版本：映射回所属任务
                    if let task = object.value(forKey: "task") as? NSManagedObject,
                       let taskID = task.value(forKey: "id") as? UUID {
                        refs.insert("task:\(taskID.uuidString)")
                    }
                default:
                    continue
                }
            }
            return (refs, conservative)
        }

        Task { @MainActor in
            self.applyInvalidation(sourceRefs: extracted.sourceRefs, conservative: extracted.conservative, now: Date())
        }
    }

    /// 远端合并：无法定位具体对象 → 保守撤销全部当前发现
    @objc private func handleRemoteChange(_ note: Notification) {
        Task { @MainActor in
            self.applyInvalidation(sourceRefs: [], conservative: true, now: Date())
        }
    }

    /// 授权撤回/恢复：授权口径变化即当前发现的 accessRevision 前提失效 → 保守撤销
    @objc private func handleConsentChange(_ note: Notification) {
        Task { @MainActor in
            self.applyInvalidation(sourceRefs: [], conservative: true, now: Date())
        }
    }

    // MARK: - 失效执行

    /// 精确路径：sourceRefs → findingsAffected（含反例/基线/版本角色）→ invalidateFinding；
    /// 保守路径：撤销全部当前有效发现。幂等，离线可用（纯本机 store 操作）。
    func applyInvalidation(sourceRefs: Set<String>, conservative: Bool, now: Date) {
        do {
            if conservative {
                if let active = try store.activeFinding(now: now) {
                    try store.invalidateFinding(id: active.id, now: now)
                }
                return
            }
            guard !sourceRefs.isEmpty else { return }
            for hit in try store.findingsAffected(bySourceRefs: sourceRefs) {
                try store.invalidateFinding(id: hit.findingID, now: now)
            }
        } catch {
            // store 不可用时丢弃本次信号：下次任何保存/远端变更会再次触发；
            // 发现展示门控（canDisplay 的 dependenciesValid）仍会挡住已失效来源
            // ——不为想象中的异常堆兜底，但也不让一次失败静默伪装成功。
            assertionFailure("Discovery 失效执行失败：\(error)")
        }
    }
}
