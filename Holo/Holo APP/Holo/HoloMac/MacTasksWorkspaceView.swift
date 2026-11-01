//
//  MacTasksWorkspaceView.swift
//  HoloMac
//
//  任务模块三栏工作台（2026-10-28 迁移）：
//  - 侧栏：智能范围（今天/已过期/全部/收件箱/已完成）+ 清单区（文件夹标签行 + 清单平铺行）
//  - 中栏：MacTaskListColumnView（复用 TaskCardView 渲染 + 时间/优先级分组）
//  - 右栏：MacTaskDetailView（就地编辑 inspector）
//  数据层全量复用 iOS 侧：TodoRepository 单例（activeTasks 为唯一数据源，
//  各范围内存解析，语义对齐 V2 TaskExperienceScope）、HoloTaskCompletionCoordinator
//  （3 秒撤回窗）、TaskPostponePolicy（延期选项唯一规则源）。
//
//  macOS 红线遵守：侧栏可选行全部 ForEach/条件直出、tag 挂行顶层（清单树不嵌套）；
//  完成与延期回执走中栏底部 toast，不复用 iOS 键盘避让逻辑。
//

import SwiftUI
import Combine
import CoreData
import OSLog

// MARK: - 浏览范围

/// 任务侧栏范围（对齐 iOS V2 TaskExperienceScope 的成员语义）
enum MacTaskBrowseScope: Hashable {
    case today
    case overdue
    case all
    case inbox
    /// 四象限看板（2026-10-30：活动未完成任务全量，口径同 .all；看板视图接管 content 列）
    case quadrant
    case completed
    case list(UUID)

    var title: String {
        switch self {
        case .today: return String(localized: "今天")
        case .overdue: return String(localized: "已过期")
        case .all: return String(localized: "全部任务")
        case .inbox: return String(localized: "收件箱")
        case .quadrant: return String(localized: "四象限")
        case .completed: return String(localized: "已完成")
        case .list: return String(localized: "清单")
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .overdue: return "exclamationmark.triangle"
        case .all: return "tray.full"
        case .inbox: return "tray"
        case .quadrant: return "square.grid.2x2"
        case .completed: return "checkmark.circle"
        case .list: return "circle.fill"
        }
    }

    /// 范围内成员解析（未删未归档为公共前置条件，与 V2 activeMembers 同语义）
    func resolve(from tasks: [TodoTask]) -> [TodoTask] {
        switch self {
        case .all, .quadrant:
            return tasks.filter { !$0.completed }
        case .today:
            return tasks.filter { !$0.completed && ($0.isDueToday || $0.isOverdue) }
        case .overdue:
            return tasks.filter { !$0.completed && $0.isOverdue }
        case .inbox:
            return tasks.filter { !$0.completed && $0.list == nil }
        case .completed:
            return tasks.filter { $0.completed }
        case .list(let listID):
            return tasks.filter { !$0.completed && $0.list?.id == listID }
        }
    }
}

// MARK: - 浏览模型

/// 中栏数据源：repository.activeTasks 唯一事实源 + 范围解析 + 搜索内存过滤 + 排序。
/// 刷新节流（.todoDataDidChange 300ms 合并）对齐想法工作台口径。
final class MacTasksBrowserModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacTasksWorkspace")

    @Published var scope: MacTaskBrowseScope = .today
    @Published var searchText: String = ""
    @Published var sortOption: TaskSortOption = .due
    @Published var sortAscending: Bool = true
    @Published private(set) var tasks: [TodoTask] = []
    /// 首次加载完成标志（避免入场闪空态，同想法工作台）
    @Published private(set) var hasLoadedOnce = false
    /// 侧栏范围计数（today/all/inbox/overdue/completed）
    @Published private(set) var scopeCounts: [String: Int] = [:]
    /// 侧栏清单与文件夹（排序后）
    @Published private(set) var lists: [TodoList] = []
    @Published private(set) var folders: [TodoFolder] = []

    let repository = TodoRepository.shared

    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    func setup() {
        repository.setup()
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

    /// 立即重载（完成/延期等写操作后调用，不等节流）
    func reloadNow() {
        reloadTask?.cancel()
        reload()
    }

    private func reload() {
        guard CoreDataStack.shared.isReady else { return }
        repository.loadFolders()
        repository.loadActiveTasks()

        let all = repository.activeTasks

        // 侧栏计数（与范围解析同源，永不出现「计数和列表对不上」）
        var counts: [String: Int] = [:]
        counts["today"] = all.filter { !$0.completed && ($0.isDueToday || $0.isOverdue) }.count
        counts["overdue"] = all.filter { !$0.completed && $0.isOverdue }.count
        counts["all"] = all.filter { !$0.completed }.count
        counts["inbox"] = all.filter { !$0.completed && $0.list == nil }.count
        counts["completed"] = all.filter { $0.completed }.count
        scopeCounts = counts

        // 侧栏清单树：无文件夹的清单平铺在前，文件夹作为标签行内嵌其清单
        folders = repository.folders
        let allLists = repository.allActiveLists()
        let folderListIds = Set(folders.flatMap { $0.lists?.allObjects.compactMap { ($0 as? TodoList)?.id } ?? [] })
        lists = allLists.filter { !folderListIds.contains($0.id) }

        // 中栏：范围解析 → 搜索过滤 → 排序
        var result = scope.resolve(from: all)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { task in
                task.title.localizedCaseInsensitiveContains(query)
                    || (task.desc ?? "").localizedCaseInsensitiveContains(query)
                    || (task.checkItems?.allObjects as? [CheckItem] ?? [])
                        .contains { $0.title.localizedCaseInsensitiveContains(query) }
            }
        }
        tasks = result.sorted {
            sortOption.areInOrder($0, $1, ascending: sortAscending)
        }
        hasLoadedOnce = true
    }

    /// 当前范围标题（清单范围显示清单名）
    var scopeTitle: String {
        if case .list(let id) = scope, let list = repository.findList(by: id) {
            return list.name ?? String(localized: "清单")
        }
        return scope.title
    }

    func count(for scope: MacTaskBrowseScope) -> Int {
        switch scope {
        case .today: return scopeCounts["today"] ?? 0
        case .overdue: return scopeCounts["overdue"] ?? 0
        case .all, .quadrant: return scopeCounts["all"] ?? 0
        case .inbox: return scopeCounts["inbox"] ?? 0
        case .completed: return scopeCounts["completed"] ?? 0
        case .list(let id): return repository.findList(by: id).map { list in
            repository.activeTasks.filter { !$0.completed && $0.list?.id == id }.count
        } ?? 0
        }
    }
}

// MARK: - 工作台根视图

struct MacTasksWorkspaceView: View {

    private static let logger = Logger(subsystem: "com.holo.app", category: "MacTasksWorkspace")

    @StateObject private var model = MacTasksBrowserModel()
    /// 完成撤回协调器（与 iOS 任务列表同一契约：3 秒窗口、重复任务滚下一轮）
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared
    /// 象限移动/计划时段协调器（看板拖拽的唯一写入路径；toast 在此路由）
    @ObservedObject private var presentationCoordinator = TaskPresentationActionCoordinator.shared

    @State private var selectedTaskId: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 看板模式（.quadrant 范围）：详情 inspector 开合
    @State private var showBoardInspector = false
    /// 收集条聚焦脉冲（看板模式下 ⌘N / ⌘F 均聚焦收集条）
    @State private var captureFocusTrigger = 0

    // MARK: 弹层宿主状态

    /// 新建任务 sheet（nil = 关闭）
    @State private var showCreation = false
    /// 延期 popover（目标任务 + 锚点）
    @State private var postponeTarget: TodoTask?
    /// 删除确认
    @State private var deleteTarget: TodoTask?
    /// 移动清单 popover
    @State private var moveTarget: TodoTask?
    /// 中栏撤回 toast（完成/延期共用，同一时间一条）
    @State private var toastMessage: String?
    @State private var toastAction: (() -> Void)?
    @State private var toastDismissTask: Task<Void, Never>?
    /// ⌘F 搜索聚焦脉冲
    @State private var searchTrigger = 0

    /// 范围持久化（重启记忆，默认「今天」）
    @AppStorage("mac.tasks.scopeRaw") private var scopeRaw: String = ""

    var body: some View {
        receiptLayers(
            presentationLayers(
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    MacTasksSidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    contentColumn
                } detail: {
                    detailColumn
                }
                .frame(minWidth: 1000, minHeight: 640)
                .toolbar {
                    ToolbarItem(placement: HoloToolbarPlacement.navTrailing) {
                        Button {
                            // 看板模式：⌘N 聚焦收集条（无弹窗创建）；列表模式照旧弹新建 sheet
                            if model.scope == .quadrant {
                                captureFocusTrigger += 1
                            } else {
                                showCreation = true
                            }
                        } label: {
                            Label(String(localized: "新建任务"), systemImage: "plus.circle")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityIdentifier("mac.task.newButton")
                    }
                }
                .task {
                    await CoreDataStack.shared.waitUntilReady()
                    restoreScope()
                    model.setup()
                }
                .onChange(of: model.scope) { _, newScope in
                    handleScopeChange(newScope)
                }
                .onReceive(HoloShortcutBus.shared.$lastEvent.dropFirst()) { event in
                    handleShortcutEvent(event)
                }
            )
        )
    }

    /// 换范围：中栏重查 + 选中清空；看板进出时切换列可见性与 inspector
    private func handleScopeChange(_ newScope: MacTaskBrowseScope) {
        selectedTaskId = nil
        persistScope(newScope)
        if newScope == .quadrant {
            // 看板不吃搜索条件：清掉列表页残留过滤；detail 列收起由看板占满
            model.searchText = ""
            columnVisibility = .doubleColumn
            showBoardInspector = false
        } else {
            showBoardInspector = false
            if columnVisibility == .doubleColumn { columnVisibility = .all }
        }
        model.reloadNow()
    }

    private func handleShortcutEvent(_ event: HoloShortcutEvent?) {
        guard let event else { return }
        switch event.action {
        case .searchInCurrentModule:
            // 看板模式 ⌘F 聚焦收集条（v1 看板无搜索）
            if model.scope == .quadrant {
                captureFocusTrigger += 1
            } else {
                searchTrigger += 1
            }
        default:
            break
        }
    }

    /// 弹层组（新建 sheet / 延期 / 移清单 / 删除确认）——拆独立函数分摊类型检查
    private func presentationLayers<V: View>(_ base: V) -> some View {
        base
            // 新建任务（三区骨架 sheet）
            .sheet(isPresented: $showCreation) {
                MacTaskCreationView(
                    defaultListID: currentListIDForCreation,
                    defaultDueToday: model.scope == .today)
                    .frame(minWidth: 480, minHeight: 560)
            }
            // 延期选项 popover（isPresented 形态：TodoTask 不保证 Identifiable）
            .popover(isPresented: Binding(
                get: { postponeTarget != nil },
                set: { if !$0 { postponeTarget = nil } }), arrowEdge: .bottom) {
                if let task = postponeTarget {
                    MacTaskPostponePopover(
                        task: task,
                        onPostponed: { message, undo in
                            showUndoToast(message: message, action: undo)
                        })
                }
            }
            // 移动到清单 popover
            .popover(isPresented: Binding(
                get: { moveTarget != nil },
                set: { if !$0 { moveTarget = nil } }), arrowEdge: .bottom) {
                if let task = moveTarget {
                    MacTaskMoveToListPopover(task: task)
                }
            }
            // 删除确认
            .confirmationDialog(
                String(localized: "删除这条任务？"),
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible
            ) {
                Button(String(localized: "删除"), role: .destructive) {
                    if let task = deleteTarget { performDelete(task) }
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: {
                Text(String(localized: "删除后将进入回收站并保留 30 天，可在 iPhone 端的「最近删除」中恢复。"))
            }
    }

    /// 回执组（完成/象限移动 toast + 看板 inspector）——拆独立函数分摊类型检查
    private func receiptLayers<V: View>(_ base: V) -> some View {
        base
            .onReceive(completionCoordinator.$pending) { pending in
            // 完成撤回窗口开启 → 中栏 toast 提示（窗口关闭且已落库则 toast 收起）
            if let pending {
                showUndoToast(
                    message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                    action: { [weak model] in
                        guard let model else { return }
                        completionCoordinator.undo(in: model.repository)
                        model.reloadNow()
                    },
                    duration: HoloTaskCompletionCoordinator.confirmDelay)
            }
        }
        // 象限移动回执路由（看板拖拽/右键/⌘⌥快捷键共用：3 秒撤回窗，同一时间一条）
        .onReceive(presentationCoordinator.$undoable) { action in
            guard let action else { return }
            showUndoToast(
                message: action.message,
                action: {
                    presentationCoordinator.undoCurrent(repository: model.repository)
                    model.reloadNow()
                },
                duration: TaskPresentationActionCoordinator.undoWindow)
        }
        .onReceive(presentationCoordinator.$failureMessage) { message in
            if let message {
                showUndoToast(message: message, duration: 2.0)
            }
        }
        // 看板详情 inspector（.quadrant 范围专用；列表范围详情走 detail 列，互不并存）
        .inspector(isPresented: inspectorBinding) {
            MacTaskDetailView(
                taskId: selectedTaskId,
                onToggleCompletion: toggleCompletion,
                onDelete: { task in deleteTarget = task },
                onChanged: { model.scheduleReload() })
                .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
        }
        .background {
            // Esc 关闭看板 inspector（cancelAction = Esc；仅看板 inspector 开启时挂载，
            // 不干扰列表范围弹层与文本输入的 Esc 语义）
            if model.scope == .quadrant && showBoardInspector {
                Button("") { showBoardInspector = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 看板 inspector 开合绑定（非看板范围强制关闭，不与 detail 列并存）
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.scope == .quadrant && showBoardInspector },
            set: { if model.scope == .quadrant { showBoardInspector = $0 } })
    }

    /// 中栏：四象限看板接管（detail 列收起，详情走 .inspector）/ 列表照旧
    @ViewBuilder
    private var contentColumn: some View {
        if model.scope == .quadrant {
            MacTaskQuadrantBoardView(
                onToggleCompletion: toggleCompletion,
                onPostpone: { task in postponeTarget = task },
                onMoveToList: { task in moveTarget = task },
                onArchive: archiveTask,
                onCopyTitle: copyTitle,
                onDelete: { task in deleteTarget = task },
                selectedTaskId: $selectedTaskId,
                captureFocusTrigger: captureFocusTrigger,
                toastMessage: toastMessage,
                toastAction: toastAction,
                inspectorShown: $showBoardInspector)
                .navigationSplitViewColumnWidth(min: 620, ideal: 900, max: 1728)
        } else {
            MacTaskListColumnView(
                model: model,
                selectedTaskId: $selectedTaskId,
                searchTrigger: searchTrigger,
                toastMessage: toastMessage,
                toastAction: toastAction,
                onToggleCompletion: toggleCompletion,
                onPostpone: { task in postponeTarget = task },
                onPostponeAllOverdue: postponeAllOverdue,
                onMoveToList: { task in moveTarget = task },
                onArchive: archiveTask,
                onCopyTitle: copyTitle,
                onDelete: { task in deleteTarget = task })
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 620)
        }
    }

    /// 右栏：看板范围占位（详情走 inspector），列表范围照旧详情列
    @ViewBuilder
    private var detailColumn: some View {
        if model.scope == .quadrant {
            Color.clear
        } else {
            MacTaskDetailView(
                taskId: selectedTaskId,
                onToggleCompletion: toggleCompletion,
                onDelete: { task in deleteTarget = task },
                onChanged: { model.scheduleReload() })
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        }
    }

    // MARK: - 范围持久化

    private func restoreScope() {
        guard !scopeRaw.isEmpty else { return }
        let parts = scopeRaw.split(separator: ":")
        switch parts.first {
        case "today": model.scope = .today
        case "overdue": model.scope = .overdue
        case "all": model.scope = .all
        case "inbox": model.scope = .inbox
        case "quadrant": model.scope = .quadrant
        case "completed": model.scope = .completed
        case "list":
            if parts.count > 1, let id = UUID(uuidString: String(parts[1])) {
                model.scope = .list(id)
            }
        default: break
        }
    }

    private func persistScope(_ scope: MacTaskBrowseScope) {
        switch scope {
        case .today: scopeRaw = "today"
        case .overdue: scopeRaw = "overdue"
        case .all: scopeRaw = "all"
        case .inbox: scopeRaw = "inbox"
        case .quadrant: scopeRaw = "quadrant"
        case .completed: scopeRaw = "completed"
        case .list(let id): scopeRaw = "list:\(id.uuidString)"
        }
    }

    /// 清单范围下新建预填该清单；其他范围不预填
    private var currentListIDForCreation: UUID? {
        guard case .list(let id) = model.scope else { return nil }
        return id
    }

    // MARK: - 操作

    private func toggleCompletion(_ task: TodoTask, trigger: (checkItemID: UUID, wasChecked: Bool)?) {
        if task.completed {
            // 已完成 → 撤回完成（无撤回窗口，直接落库；失败给可见回执，2026-10-31 审计 M10）
            do {
                try model.repository.uncompleteTask(task)
            } catch {
                Self.logger.error("撤回完成失败: \(error.localizedDescription)")
                showUndoToast(message: String(localized: "操作失败，请重试"), duration: 2.0)
            }
            model.reloadNow()
        } else if task.repeatRule != nil {
            // 重复任务：滚出下一实例（iOS 同链路）
            do {
                _ = try model.repository.completeRepeatingTask(task)
            } catch {
                Self.logger.error("完成重复任务失败: \(error.localizedDescription)")
                showUndoToast(message: String(localized: "操作失败，请重试"), duration: 2.0)
            }
            model.reloadNow()
        } else {
            completionCoordinator.requestCompletion(
                taskID: task.id, source: .taskList, trigger: trigger, in: model.repository)
            model.reloadNow()
        }
    }

    private func archiveTask(_ task: TodoTask) {
        try? model.repository.archiveTask(task)
        if selectedTaskId == task.id { selectedTaskId = nil }
        model.reloadNow()
    }

    private func copyTitle(_ task: TodoTask) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.title, forType: .string)
        #endif
    }

    private func performDelete(_ task: TodoTask) {
        try? model.repository.deleteTask(task)
        if selectedTaskId == task.id { selectedTaskId = nil }
        deleteTarget = nil
        model.reloadNow()
    }

    // MARK: - 撤回 toast

    /// 过期任务批量推到今天：落库 + 「已推到今天」回执 + 5 秒撤回（2026-10-31 审计 M3）
    private func postponeAllOverdue() {
        do {
            let snapshots = try model.repository.postponeOverdueToToday()
            guard !snapshots.isEmpty else {
                model.reloadNow()
                return
            }
            showUndoToast(
                message: String(localized: "已将 \(snapshots.count) 个过期任务推到今天"),
                action: {
                    model.repository.restorePostponed(snapshots)
                    model.reloadNow()
                },
                duration: 5.0
            )
        } catch {
            Self.logger.error("批量延期失败: \(error.localizedDescription)")
            showUndoToast(message: String(localized: "批量延期失败，请重试"), duration: 2.0)
        }
        model.reloadNow()
    }

    private func showUndoToast(message: String, action: (() -> Void)? = nil, duration: TimeInterval = 2.5) {
        toastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            toastMessage = message
            toastAction = action
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                toastMessage = nil
                toastAction = nil
            }
        }
    }
}
