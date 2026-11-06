//
//  MacQuadrantBoardModel.swift
//  HoloMac
//
//  四象限看板数据模型（2026-10-30）：repository.activeTasks 唯一事实源，
//  TaskQuadrantResolver 实时分组（象限不落库）、TaskRecordSnapshot.defaultOrder
//  同口径排序（紧急分降序 → 截止升序 → 创建时间 → UUID）。
//  写入动作不经本模型——拖拽/右键/快捷键统一走 TaskPresentationActionCoordinator
//  （象限移动唯一规则源），本模型只读 + 监听 .todoDataDidChange 节流重载。
//

import SwiftUI
import Combine
import CoreData
import OSLog

// MARK: - 象限格展示组

/// 单个象限格的展示组（成员已按紧急分口径排序）
struct MacQuadrantGroup: Identifiable, Equatable {
    let quadrant: TaskQuadrant
    let tasks: [TodoTask]
    var id: String { String(describing: quadrant) }

    static func == (lhs: MacQuadrantGroup, rhs: MacQuadrantGroup) -> Bool {
        lhs.quadrant == rhs.quadrant && lhs.tasks.map(\.id) == rhs.tasks.map(\.id)
    }
}

// MARK: - 建档初始值（与拖入同口径）

extension TaskQuadrant {
    /// 就地建入格的两轴初始值：等于「全默认新任务套用 TaskQuadrantMovePolicy 补丁」
    /// 的结果（重要侧 P1 / 非重要侧落中性 P2；紧急侧锁 P1 / 不紧急侧锁 P3），
    /// 与拖拽写入同规则源，保证两条路径口径完全一致。
    var creationImportance: TaskImportance {
        switch self {
        case .doFirst, .scheduleTime: return .p1
        case .batchHandle, .reviewLater: return .p2
        case .unclassified: return .unknown
        }
    }

    var creationUrgencyMode: TaskUrgencyMode {
        switch self {
        case .doFirst, .batchHandle: return .p1
        case .scheduleTime, .reviewLater: return .p3
        case .unclassified: return .auto
        }
    }
}

// MARK: - 看板模型

/// 看板只读模型：五组解析（四象限 + 待确认）+ 布局动画签名。
/// 结构与 MacTasksBrowserModel 同构（NotificationCenter 节流 + repository 单例）。
final class MacQuadrantBoardModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacQuadrantBoard")

    @Published private(set) var groups: [MacQuadrantGroup] = []
    @Published private(set) var unclassified: [TodoTask] = []
    @Published private(set) var hasLoadedOnce = false
    /// 布局动画签名：五组全部成员 ID 顺序（组内集合变化才触发插入/移动动画）
    @Published private(set) var layoutSignature: [UUID] = []

    let repository = TodoRepository.shared

    /// 分组解析基准时刻（每次重载刷新——象限随日期实时解析，不落库）
    private(set) var now: Date = Date()
    let calendar = TaskAnalyticsPeriod.makeCalendar()

    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    /// macOS 14 onAppear 会二次触发（编辑器踩坑同源）：setup 幂等防重复监听
    private var isSetup = false

    func setup() {
        guard !isSetup else { return }
        isSetup = true
        observer = NotificationCenter.default.addObserver(
            forName: .todoDataDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleReload()
        }
        scheduleReload()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        reloadTask?.cancel()
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    /// 立即重载（创建/移动等写操作后调用，不等节流）
    func reloadNow() {
        reloadTask?.cancel()
        reload()
    }

    private func reload() {
        guard CoreDataStack.shared.isReady else { return }
        now = Date()
        repository.loadActiveTasks()
        let active = repository.activeTasks.filter { !$0.completed }

        // 快照排序（defaultOrder 要快照入参；一次物化避免比较器内重复构建）
        let snapshotted = active.map { (task: $0, snapshot: TaskRecordSnapshot.make(from: $0)) }

        var byQuadrant: [TaskQuadrant: [(task: TodoTask, snapshot: TaskRecordSnapshot)]] = [:]
        for item in snapshotted {
            let quadrant = item.snapshot.quadrant(now: now, calendar: calendar)
            byQuadrant[quadrant, default: []].append(item)
        }

        var signature: [UUID] = []
        var resolvedGroups: [MacQuadrantGroup] = []
        for quadrant in TaskQuadrant.overviewOrder {
            let members = (byQuadrant[quadrant] ?? [])
                .sorted { TaskRecordSnapshot.defaultOrder($0.snapshot, $1.snapshot, now: now, calendar: calendar) }
                .map(\.task)
            signature.append(contentsOf: members.map(\.id))
            resolvedGroups.append(MacQuadrantGroup(quadrant: quadrant, tasks: members))
        }
        groups = resolvedGroups

        let pool = snapshotted
            .filter { $0.snapshot.importance == .unknown }
            .sorted { TaskRecordSnapshot.defaultOrder($0.snapshot, $1.snapshot, now: now, calendar: calendar) }
            .map(\.task)
        unclassified = pool
        signature.append(contentsOf: pool.map(\.id))
        layoutSignature = signature
        hasLoadedOnce = true
    }

    /// 活动任务总数（四格 + 待确认，标题计数与侧栏口径一致）
    var activeCount: Int {
        groups.reduce(0) { $0 + $1.tasks.count } + unclassified.count
    }
}
