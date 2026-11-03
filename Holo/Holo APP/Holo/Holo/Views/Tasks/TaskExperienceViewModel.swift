//
//  TaskExperienceViewModel.swift
//  Holo
//
//  任务首页视图模型（方案 §4/§9）：单一快照源驱动范围过滤、四象限计数/分组、
//  待整理入口、搜索与新增定位；完成撤回窗口用同一 pending 投影。
//  刷新链：todoDataDidChange / Today 计划变化 / 前台恢复 / 日期边界。
//

import Foundation
import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif
import Combine
import CoreData

extension Notification.Name {
    /// 搜索页等外部 surface 请求首页打开某任务详情（object = 任务 UUID）
    static let taskExperienceOpenDetail = Notification.Name("taskExperienceOpenDetail")
    /// 任务创建成功回执（userInfo: id=UUID, quadrant=TaskQuadrant）：
    /// 首页展开定位、容器切回任务页（底部+/统计页入口同样生效）
    static let taskExperienceCreated = Notification.Name("taskExperienceCreated")
    /// 外层 FAB 请求按当前视图上下文新建（多视图方案 §7.1；任务页在场时消费）
    static let taskExperienceRequestCreation = Notification.Name("taskExperienceRequestCreation")
}

@MainActor
final class TaskExperienceViewModel: ObservableObject {

    // MARK: - 状态

    /// 全量任务快照（唯一计算链的源）
    @Published private(set) var snapshots: [TaskRecordSnapshot] = []
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var loadFailed: Bool = false

    /// 当前范围（新偏好键：首次升级默认全部未完成，不照搬旧版默认今日）
    @Published var scope: TaskExperienceScope = .allUncompleted {
        didSet { scopeDidChange() }
    }

    /// 当前选中的象限（nil = 四组都显示）
    @Published var selectedQuadrant: TaskQuadrant? = nil
    /// 各组展开状态（组名 -> 全展开）
    @Published var expandedGroups: Set<TaskQuadrant> = []

    /// 移动提示（分类变化移出当前组：已移至『…』+ 查看，§4.3）
    struct MoveToast: Equatable, Identifiable {
        let id = UUID()
        let taskID: UUID
        let targetQuadrant: TaskQuadrant
    }
    @Published var moveToast: MoveToast? = nil

    /// 撤回窗口投影（首页行与计数同一份 pending 展示，§4.3）
    private let completionCoordinator = HoloTaskCompletionCoordinator.shared
    var pendingCompletionTaskID: UUID? {
        completionCoordinator.pending?.taskID
    }

    private let repository: TodoRepository
    private var cancellables: Set<AnyCancellable> = []
    private var boundaryTimer: AnyCancellable?

    /// 新增定位（保存后展开目标组并滚动到新任务）
    @Published var locateTaskID: UUID? = nil

    /// 范围偏好持久化（只存活动范围；历史范围为临时访问，冷启动回全部，§4.5）
    private static let persistedScopeKey = "taskExperienceV2.selectedScope"
    private static let persistedScopeListKey = "taskExperienceV2.selectedScopeListID"

    init(repository: TodoRepository) {
        self.repository = repository
        restorePersistedScope()
        observeChanges()
    }

    // MARK: - 刷新链

    private func observeChanges() {
        NotificationCenter.default.publisher(for: .todoDataDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // 今日计划变化：行内「加入/放下」菜单态跟随刷新
        NotificationCenter.default.publisher(for: .holoTodayPlanDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshTodayEntries()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // 前台恢复兜底（§9.3）
        #if canImport(UIKit)
        let activeName = UIApplication.didBecomeActiveNotification
        #else
        let activeName = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: activeName)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // 显著时间变化（运营商时间同步/跨时区旅行）与时区切换：
        // today、逾期、自动紧急、月索引按新时刻重算（多视图方案 §8）
        #if canImport(UIKit)
        let significantTimeChange = UIApplication.significantTimeChangeNotification
        #else
        let significantTimeChange = Notification.Name.NSCalendarDayChanged
        #endif
        NotificationCenter.default.publisher(for: significantTimeChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // 撤回窗口开/关：计数与行投影同步（不重读库，纯派生）
        completionCoordinator.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        scheduleBoundaryRefresh()
    }

    /// 下一个相关时间边界触发刷新：午夜（自动紧急随日期变化）与紧急边界（§9.3）
    private func scheduleBoundaryRefresh() {
        boundaryTimer?.cancel()
        let calendar = TaskAnalyticsPeriod.makeCalendar()
        let now = Date()
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let urgentBoundary = TaskQuadrantResolver.urgentBoundary(now: now, calendar: calendar)
        let next = [midnight, urgentBoundary].filter { $0 > now }.min() ?? midnight
        boundaryTimer = Timer.publish(every: max(1, next.timeIntervalSinceNow), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reload()
                self?.scheduleBoundaryRefresh()
            }
    }

    func reload() {
        do {
            let loaded = try TaskSnapshotReader.readAllSnapshots(in: repository.context)
            snapshots = loaded
            isLoading = false
            loadFailed = false
            validatePersistedScope()
            refreshTodayEntries()
        } catch {
            // 读失败保留上次快照并如实标记（不显示假 0，§9.4）
            isLoading = false
            loadFailed = true
        }
    }

    // MARK: - 范围

    private func restorePersistedScope() {
        let raw = UserDefaults.standard.string(forKey: Self.persistedScopeKey) ?? "all"
        switch raw {
        case "today": scope = .todayDue
        case "overdue": scope = .overdue
        case "inbox": scope = .inbox
        case "list":
            let listRaw = UserDefaults.standard.string(forKey: Self.persistedScopeListKey) ?? ""
            if let id = UUID(uuidString: listRaw) {
                scope = .list(id)
            } else {
                scope = .allUncompleted
            }
        default: scope = .allUncompleted
        }
    }

    private func scopeDidChange() {
        // 切换范围清除象限选择及展开状态（§4.3）
        selectedQuadrant = nil
        expandedGroups = []

        switch scope {
        case .allUncompleted:
            UserDefaults.standard.set("all", forKey: Self.persistedScopeKey)
        case .todayDue:
            UserDefaults.standard.set("today", forKey: Self.persistedScopeKey)
        case .overdue:
            UserDefaults.standard.set("overdue", forKey: Self.persistedScopeKey)
        case .inbox:
            UserDefaults.standard.set("inbox", forKey: Self.persistedScopeKey)
        case .list(let id):
            UserDefaults.standard.set("list", forKey: Self.persistedScopeKey)
            UserDefaults.standard.set(id.uuidString, forKey: Self.persistedScopeListKey)
        case .completed, .archived:
            break // 历史范围不持久化（冷启动回全部，§4.5）
        }
    }

    /// 持久化的清单不存在 → 回全部（§4.5）
    private func validatePersistedScope() {
        guard case .list(let id) = scope else { return }
        let exists = snapshots.contains { $0.listID == id }
            || repository.allActiveLists().contains { $0.id == id }
        if !exists {
            scope = .allUncompleted
        }
    }

    // MARK: - 派生：范围成员（撤回窗口 pending 投影）

    var calendar: Calendar { TaskAnalyticsPeriod.makeCalendar() }
    var now: Date { Date() }

    /// 范围显示名（指定清单用真实清单名，不显示笼统「清单」）
    var scopeTitle: String {
        guard case .list(let listID) = scope else { return scope.title }
        if let name = snapshots.first(where: { $0.listID == listID })?.listName, 
           snapshots.first(where: { $0.listID == listID })?.listAvailable == true {
            return name
        }
        return repository.findList(by: listID)?.name ?? scope.title
    }

    /// 当日已加入今日安排的任务（行内菜单状态与放下判定用）
    @Published private(set) var todayEntryIDs: Set<UUID> = []

    private func refreshTodayEntries() {
        let read = HoloTodayPlanRepository(context: repository.context).currentPlan(scope: HoloTodayDayScope.current())
        if case .active(let payload, _) = read.state {
            todayEntryIDs = Set(payload.entries.map(\.taskID))
        } else {
            todayEntryIDs = []
        }
    }

    /// 当前范围的活动未完成任务（pending 完成任务暂时移出待办，§4.3）
    var activeMembers: [TaskRecordSnapshot] {
        let members = scope.activeMembers(from: snapshots, now: now, calendar: calendar)
        guard let pendingID = pendingCompletionTaskID else { return members }
        return members.filter { $0.id != pendingID }
    }

    /// 历史范围成员
    var historicalMembers: [TaskRecordSnapshot] {
        scope.historicalMembers(from: snapshots, calendar: calendar)
    }

    /// 四象限计数（不含待整理；pending 投影同步减一，§4.3）
    var quadrantCounts: [TaskQuadrant: Int] {
        var counts: [TaskQuadrant: Int] = [:]
        for member in activeMembers {
            counts[member.quadrant(now: now, calendar: calendar), default: 0] += 1
        }
        return counts
    }

    /// 待整理数（当前范围）
    var unclassifiedCount: Int {
        activeMembers.filter { $0.importance == .unknown }.count
    }

    /// 计数守恒：四格 + 待整理 = 范围活动任务总数（§4.3）
    var conservedTotal: Int { activeMembers.count }

    /// 四组任务（组内默认排序）
    var groupedMembers: [(quadrant: TaskQuadrant, members: [TaskRecordSnapshot])] {
        let byQuadrant = Dictionary(grouping: activeMembers) { $0.quadrant(now: now, calendar: calendar) }
        return TaskQuadrant.overviewOrder.map { quadrant in
            (quadrant, (byQuadrant[quadrant] ?? []).sorted {
                TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar)
            })
        }
    }

    /// 待整理组（按首页组内默认规则排序）
    var unclassifiedMembers: [TaskRecordSnapshot] {
        activeMembers
            .filter { $0.importance == .unknown }
            .sorted { TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar) }
    }

    // MARK: - 清单分组（新版列表组织层，多视图方案 §3.4）

    struct TaskListGroup: Identifiable, Equatable {
        /// nil = 收件箱
        let listID: UUID?
        let title: String
        let members: [TaskRecordSnapshot]
        var id: String { listID?.uuidString ?? "inbox" }
    }

    /// 按清单组织当前范围活动任务：收件箱置首，其余按清单现有顺序，
    /// 失效归属桶置末；0 项清单隐藏；组内复用 defaultOrder；
    /// 指定清单范围省略重复组标题（showsHeader=false 由视图按范围判断）。
    var listGroups: [TaskListGroup] {
        let members = activeMembers
        guard !members.isEmpty else { return [] }

        func sortedGroup(_ title: String, _ subset: [TaskRecordSnapshot]) -> TaskListGroup {
            TaskListGroup(
                listID: nil,
                title: title,
                members: subset.sorted {
                    TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar)
                }
            )
        }

        // 指定清单范围：只列其成员（收件箱范围同样单组）
        switch scope {
        case .inbox:
            return [sortedGroup(String(localized: "收件箱"), members.filter { $0.listID == nil })]
                .filter { !$0.members.isEmpty }
        case .list(let listID):
            // 指定清单范围：单组、省略与范围名重复的组标题（视图层按范围判断）
            return [TaskListGroup(
                listID: listID,
                title: "",
                members: members.sorted {
                    TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar)
                }
            )]
        default:
            break
        }

        var groups: [TaskListGroup] = []
        let inbox = members.filter { $0.listID == nil }
        if !inbox.isEmpty {
            groups.append(sortedGroup(String(localized: "收件箱"), inbox))
        }
        // 有效清单依现有清单顺序（allActiveLists 顺序 = unfiled + folders）
        for list in repository.allActiveLists() {
            let subset = members.filter { $0.listID == list.id }
            if !subset.isEmpty {
                groups.append(TaskListGroup(
                    listID: list.id,
                    title: list.name,
                    members: subset.sorted {
                        TaskRecordSnapshot.defaultOrder($0, $1, now: now, calendar: calendar)
                    }
                ))
            }
        }
        // 失效归属桶置末（清单已删除/失效的成员，原删除契约）
        let orphanStart = groups.reduce(into: Set<UUID>()) { set, group in
            group.members.forEach { set.insert($0.id) }
        }
        let orphans = members.filter { !orphanStart.contains($0.id) }
        if !orphans.isEmpty {
            groups.append(sortedGroup(String(localized: "未归属清单"), orphans))
        }
        return groups
    }

    // MARK: - 日历投影成员（多视图方案 §3.3/§4.2）

    /// 日历投影用的成员：活动范围集合 +（开启显示已完成时）同范围完成任务
    /// 与 pending 完成任务（显示为完成待确认）；范围徽章仍用 activeMembers 口径
    func calendarMembers(showsCompleted: Bool) -> [TaskRecordSnapshot] {
        var members = activeMembers
        guard showsCompleted else { return members }
        let completed = scope.completedMembersInScope(from: snapshots, now: now, calendar: calendar)
        members.append(contentsOf: completed)
        if let pendingID = pendingCompletionTaskID,
           let pending = snapshots.first(where: { $0.id == pendingID && !$0.deleted && !$0.archived }) {
            members.append(pending)
        }
        return members
    }

    // MARK: - 范围数量提示（范围菜单用）

    var scopeCounts: [TaskExperienceScope: Int] {
        var result: [TaskExperienceScope: Int] = [:]
        let activeScopes: [TaskExperienceScope] = [.allUncompleted, .todayDue, .overdue, .inbox]
        for value in activeScopes {
            result[value] = value.activeMembers(from: snapshots, now: now, calendar: calendar).count
        }
        for list in repository.allActiveLists() {
            result[.list(list.id)] = TaskExperienceScope.list(list.id)
                .activeMembers(from: snapshots, now: now, calendar: calendar).count
        }
        return result
    }

    var allLists: [TodoList] {
        repository.allActiveLists()
    }

    /// 详情打开用的规范任务副本
    func repositoryTask(_ id: UUID) -> TodoTask? {
        repository.findTask(by: id)
    }

    // MARK: - 整理队列（打开时冻结，§6.1）

    func makeTriageQueue() -> [TaskRecordSnapshot] {
        unclassifiedMembers
    }

    // MARK: - 新增定位（§5.4/§7.2）

    /// 创建成功后不在当前范围的任务（View 据此给「已新增，当前范围不包含此任务」
    /// + 查看 提示；不自动切范围、不改截止迁就筛选）
    @Published var createdOutOfScopeTaskID: UUID? = nil

    func handleCreated(taskID: UUID, quadrant: TaskQuadrant) {
        reload()
        // 新任务不属于当前范围：如实标记，切范围交给用户的「查看」动作（§7.1）
        let inScope = scope.activeMembers(from: snapshots, now: now, calendar: calendar)
            .contains { $0.id == taskID }
        createdOutOfScopeTaskID = inScope ? nil : taskID
        // 清单/矩阵定位共用：滚动到新任务行（列表按实际清单定位，§7.2）
        locateTaskID = taskID
    }

    /// 「查看」范围外新任务：切到全部未完成
    func revealOutOfScopeTask() {
        guard let taskID = createdOutOfScopeTaskID else { return }
        scope = .allUncompleted
        createdOutOfScopeTaskID = nil
        locateTaskID = taskID
    }

    // MARK: - 分类直写 + 移动提示（§4.3/§8.2）

    /// 首页「更多」里的直接分类：保存后如移出当前组给「已移至」提示
    func applyClassification(taskID: UUID, importance: TaskImportance, urgencyMode: TaskUrgencyMode) {
        let beforeQuadrant = snapshots.first { $0.id == taskID }?
            .quadrant(now: now, calendar: calendar)
        do {
            try repository.updateTaskClassification(taskID: taskID, importance: importance, urgencyMode: urgencyMode)
            reload()
            let afterQuadrant = snapshots.first { $0.id == taskID }?
                .quadrant(now: now, calendar: calendar)
            // 当前组内任务因分类移出：提示去向（展示层判断，不写库）
            if let before = beforeQuadrant, let after = afterQuadrant, before != after,
               selectedQuadrant == nil || selectedQuadrant == before {
                moveToast = MoveToast(taskID: taskID, targetQuadrant: after)
            }
        } catch {
            // 保存失败如实提示（不 toast 成功）
            moveToast = nil
        }
    }

    /// 「查看」移动去向：跳到目标象限
    func revealMovedTask() {
        guard let toast = moveToast else { return }
        selectedQuadrant = toast.targetQuadrant
        expandedGroups.insert(toast.targetQuadrant)
        locateTaskID = toast.taskID
        moveToast = nil
    }

    // MARK: - 搜索（§4.5：不修改首页范围、不改四象限计数）

    func searchResults(keyword: String) -> [TaskRecordSnapshot] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        return snapshots
            .filter { !$0.deleted }
            .filter { snapshot in
                let title = snapshot.title.lowercased()
                let note = (snapshot.note ?? "").lowercased()
                let listName = snapshot.listName?.lowercased() ?? ""
                return title.contains(lower) || note.contains(lower) || listName.contains(lower)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
