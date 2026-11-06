//
//  TaskQuadrantBoardView.swift
//  Holo
//
//  四象限矩阵（2026-11-05 原型 1:1 → 真机二轮拍板重构）：
//  2×2 四格铺满内容区、格内独立滚动；格头彩底 + 26pt 加号在格内新建。
//  待确认入口在左上筛选行（badge 计数，整行点击拉出左侧浮岛侧栏）；
//  侧栏顶部收编范围筛选，其下为待确认列表（毛玻璃、全屏遮罩）。
//  拖拽走系统 onDrag/dropDestination：格内行可拖换格；落在侧栏=移回待确认；
//  落在缝隙/页边距等无接收器区域=系统取消，任务留原处（矩形命中双保险：
//  每格只接收自己矩形内的 drop，缝隙无接收器）。
//  写入统一走 TaskPresentationActionCoordinator / repository。
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - 象限展示扩展（原型副题与空态引导）

extension TaskQuadrant {
    /// 格副标题（两轴语义，原型文案）
    var subtitleText: String {
        switch self {
        case .doFirst: return String(localized: "重要且紧急")
        case .scheduleTime: return String(localized: "重要不紧急")
        case .batchHandle: return String(localized: "不重要但紧急")
        case .reviewLater: return String(localized: "不重要不紧急")
        case .unclassified: return String(localized: "重要性或紧急性未判断")
        }
    }

    /// 空格引导（13/500，象限深色 45%；原型文案）
    var emptyPrompt: String {
        switch self {
        case .doFirst: return String(localized: "立即去做~")
        case .scheduleTime: return String(localized: "安排时间做~")
        case .batchHandle: return String(localized: "顺手集中做~")
        case .reviewLater: return String(localized: "有空再做~")
        case .unclassified: return String(localized: "待确认")
        }
    }

    /// 空格保留位置时的多行引导（Mac 看板沿用；iOS 端 2026-11-05 改版后已用 emptyPrompt）
    var emptyGuidance: String {
        switch self {
        case .doFirst: return String(localized: "眼前没有急事\n点 ＋ 添加任务")
        case .scheduleTime: return String(localized: "给重要的事留一点时间\n点 ＋ 添加任务")
        case .batchHandle: return String(localized: "把零碎小事集中处理\n点 ＋ 添加任务")
        case .reviewLater: return String(localized: "暂时没有这类任务\n点 ＋ 添加任务")
        case .unclassified: return String(localized: "没有待确认任务")
        }
    }

    /// UI 测试/无障碍用的稳定标识
    var dragIdentifier: String {
        switch self {
        case .doFirst: return "doFirst"
        case .scheduleTime: return "scheduleTime"
        case .batchHandle: return "batchHandle"
        case .reviewLater: return "reviewLater"
        case .unclassified: return "unclassified"
        }
    }
}

// MARK: - 拖拽上下文（宿主持有；板/侧栏/浮层共用）

/// 系统拖拽共享态：
/// - hoverTarget / hoverSidebar：悬停瞬时态（与 drop 事件严格成对）
/// - isDragging：拖拽进行中（侧栏收窄为 64pt 竖条，四格全露可达）。
///   系统拖拽对「取消落手」无源端回调，死区取消靠 5 秒兜底复位收窄态；
///   正常落格/落竖条/再拖起/关侧栏都会立即复位。
@MainActor
final class TaskQuadrantDragContext: ObservableObject {

    @Published var hoverTarget: TaskQuadrant?
    @Published var hoverSidebar = false
    @Published var isDragging = false
    /// 2×2 格局（不含页边距）在全局坐标系的 frame，由板视图上报（遮罩路由用）
    @Published var gridFrame: CGRect = .zero
    /// 遮罩全局原点（其 onDrop 坐标换算用）
    @Published var scrimOrigin: CGPoint = .zero

    private var backstopTask: Task<Void, Never>?

    /// 任意行拖起（onDrag）：侧栏收窄 + 兜底计时
    func beginDrag() {
        HapticManager.medium()
        withAnimation(TaskQuadrantMetrics.sidebarAnimation) {
            isDragging = true
        }
        backstopTask?.cancel()
        backstopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isDragging else { return }
                withAnimation(TaskQuadrantMetrics.sidebarAnimation) {
                    self.isDragging = false
                }
            }
        }
    }

    /// 拖拽结束（落格/落竖条/关侧栏）：立即恢复全宽
    func endDrag() {
        backstopTask?.cancel()
        withAnimation(TaskQuadrantMetrics.sidebarAnimation) {
            isDragging = false
        }
    }

    func clearHover() {
        hoverTarget = nil
        hoverSidebar = false
    }

    /// 矩形命中（四验拍板口径）：drop 坐标必须落在某一格的矩形内；
    /// 格间缝隙/页边距返回 nil = 取消留原处。侧栏打开时遮罩在四格之上，
    /// 其路由 delegate 用此函数把 drop 转发到命中格
    func hitQuadrant(at point: CGPoint) -> TaskQuadrant? {
        guard gridFrame.width > 1, gridFrame.height > 1,
              gridFrame.contains(point) else { return nil }
        let gap = TaskQuadrantMetrics.cellGap
        let cellWidth = (gridFrame.width - gap) / 2
        let cellHeight = (gridFrame.height - gap) / 2
        let column: Int?
        if point.x <= gridFrame.minX + cellWidth {
            column = 0
        } else if point.x >= gridFrame.minX + cellWidth + gap {
            column = 1
        } else {
            column = nil   // 列缝
        }
        let row: Int?
        if point.y <= gridFrame.minY + cellHeight {
            row = 0
        } else if point.y >= gridFrame.minY + cellHeight + gap {
            row = 1
        } else {
            row = nil      // 行缝
        }
        guard let column, let row else { return nil }
        return TaskQuadrant.overviewOrder[row * 2 + column]
    }
}

// MARK: - 遮罩期拖拽路由（侧栏打开时四格在遮罩之下，drop 按坐标转发到命中格）

struct TaskQuadrantRouteDropDelegate: DropDelegate {

    let context: TaskQuadrantDragContext
    /// 宿主视图本地坐标 → 全局坐标
    let toGlobal: (CGPoint) -> CGPoint
    let commit: (UUID, TaskQuadrant) -> Void

    private func refreshHover(_ info: DropInfo) -> DropProposal? {
        context.hoverTarget = context.hitQuadrant(at: toGlobal(info.location))
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        _ = refreshHover(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        refreshHover(info)
    }

    func dropExited(info: DropInfo) {
        context.clearHover()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = context.hitQuadrant(at: toGlobal(info.location))
        context.clearHover()
        context.endDrag()
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  let taskID = UUID(uuidString: payload),
                  let target else { return }
            Task { @MainActor in
                commit(taskID, target)
            }
        }
        return target != nil
    }
}

// MARK: - 侧栏落点（拖回待确认）

/// 侧栏挂 drop 目标：格内任务松手落在侧栏上 → 两轴重置为未判断（回待确认）。
/// 载荷与落格同源（任务 UUID 字符串）。
struct TaskQuadrantPendingDropDelegate: DropDelegate {

    let context: TaskQuadrantDragContext
    let onCommit: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText.identifier])
    }

    func dropEntered(info: DropInfo) {
        context.hoverSidebar = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        context.hoverSidebar = false
    }

    func performDrop(info: DropInfo) -> Bool {
        context.hoverSidebar = false
        context.endDrag()
        guard let provider = info.itemProviders(for: [UTType.plainText.identifier]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String,
                  let taskID = UUID(uuidString: payload) else { return }
            Task { @MainActor in
                onCommit(taskID)
            }
        }
        return true
    }
}

// MARK: - 矩阵主视图

struct TaskQuadrantBoardView: View {

    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var dragContext: TaskQuadrantDragContext
    let repository: TodoRepository
    let onOpenDetail: (UUID) -> Void
    let onCreateInQuadrant: (TaskQuadrant) -> Void

    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    var body: some View {
        grid
    }

    // MARK: - 2×2 格局

    private var grid: some View {
        VStack(spacing: TaskQuadrantMetrics.cellGap) {
            HStack(spacing: TaskQuadrantMetrics.cellGap) {
                quadrantCell(.doFirst)
                quadrantCell(.scheduleTime)
            }
            HStack(spacing: TaskQuadrantMetrics.cellGap) {
                quadrantCell(.batchHandle)
                quadrantCell(.reviewLater)
            }
        }
        .background(
            // 内区 frame（不含页边距）：遮罩路由按矩形命中行列（缝隙/边距 → 取消）
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.frame(in: .global)) { _, frame in
                        dragContext.gridFrame = frame
                    }
                    .onAppear {
                        dragContext.gridFrame = geo.frame(in: .global)
                    }
            }
        )
        .padding(.horizontal, TaskQuadrantMetrics.pageInset)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func quadrantCell(_ quadrant: TaskQuadrant) -> some View {
        let members = model.groupedMembers.first { $0.quadrant == quadrant }?.members ?? []
        let isTarget = dragContext.hoverTarget == quadrant
        return VStack(spacing: 0) {
            TaskQuadrantCellHeader(quadrant: quadrant, count: members.count) {
                onCreateInQuadrant(quadrant)
            }
            if members.isEmpty {
                Text(quadrant.emptyPrompt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(quadrant.tintColor.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(members) { member in
                            cellRow(member)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isTarget ? quadrant.backgroundColor : Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: TaskQuadrantMetrics.cellRadius, style: .continuous))
        .overlay(
            // 拖拽目标格：2pt 象限深色描边（原型 inset 2pt 高亮）
            RoundedRectangle(cornerRadius: TaskQuadrantMetrics.cellRadius, style: .continuous)
                .strokeBorder(isTarget ? quadrant.tintColor : Color.clear, lineWidth: 2)
        )
        .accessibilityElement(children: .contain)   // 容器标识（UI 测试定位格），子元素保持可访问
        .accessibilityIdentifier("quadrant.cell.\(quadrant.dragIdentifier)")
        // 落格接收（矩形命中）：dropDestination 只接收本格矩形内的 drop，
        // 格缝/页边距无接收器=系统取消；目标=当前实时解析格时补丁为 nil（零写入）
        .dropDestination(for: String.self) { items, _ in
            dragContext.clearHover()
            dragContext.endDrag()
            guard let payload = items.first,
                  let taskID = UUID(uuidString: payload) else { return false }
            TaskPresentationActionCoordinator.shared.commitQuadrantMove(
                taskID: taskID,
                target: quadrant,
                repository: repository,
                now: model.now,
                calendar: model.calendar
            )
            return true
        } isTargeted: { hovering in
            dragContext.hoverTarget = hovering ? quadrant : nil
        }
    }

    /// 格内任务行（可拖拽换格）
    private func cellRow(_ member: TaskRecordSnapshot) -> some View {
        let due = Self.dueFact(member, now: model.now, calendar: model.calendar)
        return TaskQuadrantTaskRow(
            member: member,
            dueText: due?.text,
            isOverdue: due?.isOverdue ?? false,
            isDone: model.pendingCompletionTaskID == member.id,
            onToggle: { toggleCompletion(member) },
            onOpenDetail: { onOpenDetail(member.id) },
            onDragStarted: { dragContext.beginDrag() }
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    // MARK: - 动作

    /// 完成/撤回（与列表同一协调器，撤回窗口内可反悔）
    private func toggleCompletion(_ member: TaskRecordSnapshot) {
        if model.pendingCompletionTaskID == member.id {
            completionCoordinator.undo(in: repository)
            HapticManager.light()
        } else {
            completionCoordinator.requestCompletion(taskID: member.id, source: .taskMatrix, in: repository)
            HapticManager.taskCompletion()
        }
    }

    // MARK: - 截止事实（短格式：今天/明天带时刻，其余 M/D——保证「已逾期」完整可见）

    static func dueFact(
        _ member: TaskRecordSnapshot,
        now: Date,
        calendar: Calendar
    ) -> (text: String, isOverdue: Bool)? {
        guard let due = member.effectiveDue(calendar: calendar) else { return nil }
        let timeText: String? = member.isAllDay ? nil : Self.timeFormatter.string(from: due)

        if member.isOverdue(asOf: now, calendar: calendar) {
            if calendar.isDateInToday(due) {
                let timeSuffix = timeText.map { " \($0)" } ?? ""
                return (String(localized: "今天") + timeSuffix + String(localized: " · 已逾期"), true)
            }
            return (Self.dayFormatter.string(from: due) + String(localized: " · 已逾期"), true)
        }
        if calendar.isDateInToday(due) {
            if let timeText {
                return (String(localized: "今天") + " " + timeText + String(localized: " 前"), false)
            }
            return (String(localized: "今天"), false)
        }
        if calendar.isDateInTomorrow(due) {
            if let timeText {
                return (String(localized: "明天") + " " + timeText + String(localized: " 前"), false)
            }
            return (String(localized: "明天"), false)
        }
        return (Self.dayFormatter.string(from: due), false)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M/d")
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 待确认侧栏浮层（宿主 overlay 层：全屏遮罩 + 左侧浮岛 + 拖拽胶囊）

struct TaskQuadrantSidebarOverlay: View {

    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var dragContext: TaskQuadrantDragContext
    let repository: TodoRepository
    let showsSidebar: Bool
    let onOpenDetail: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsSidebar {
                // 全屏遮罩（rgba(22,20,15,.25)）。四验拍板：回归模态语义——
                // 触摸拦截（点外层任务不进详情）、点蒙版即退出；
                // 拖拽落点由路由 delegate 按矩形命中转发到四格（侧栏拖出仍可落任意格）
                TaskQuadrantPalette.scrim(0.25)
                    .ignoresSafeArea()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { dragContext.scrimOrigin = geo.frame(in: .global).origin }
                                .onChange(of: geo.frame(in: .global).origin) { _, origin in
                                    dragContext.scrimOrigin = origin
                                }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .onDrop(of: [UTType.plainText.identifier], delegate: routeDelegate)
                    .transition(.opacity)
            }
            if showsSidebar {
                TaskQuadrantSidebarPanel(
                    model: model,
                    repository: repository,
                    dragContext: dragContext,
                    onOpenDetail: onOpenDetail,
                    onClose: onClose
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            dropCapsule
        }
    }

    /// 遮罩路由（本地坐标 + 遮罩全局原点 → 矩形命中格）
    private var routeDelegate: TaskQuadrantRouteDropDelegate {
        let origin = dragContext.scrimOrigin
        return TaskQuadrantRouteDropDelegate(
            context: dragContext,
            toGlobal: { point in
                CGPoint(x: point.x + origin.x, y: point.y + origin.y)
            },
            commit: { taskID, target in
                TaskPresentationActionCoordinator.shared.commitQuadrantMove(
                    taskID: taskID,
                    target: target,
                    repository: repository,
                    now: model.now,
                    calendar: model.calendar
                )
            }
        )
    }

    /// 底部胶囊：悬停格=归入「格名」；悬停侧栏=移回待确认（浮卡由系统 preview 承担）
    @ViewBuilder
    private var dropCapsule: some View {
        if dragContext.hoverSidebar {
            capsuleText(String(localized: "移回待确认"))
        } else if let target = dragContext.hoverTarget {
            capsuleText(String(localized: "归入「\(target.displayTitle)」"))
        }
    }

    private func capsuleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(TaskQuadrantPalette.capsule))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 24)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - 左侧浮岛本体（顶部范围筛选 + 待确认列表 + 拖回待确认落点）

private struct TaskQuadrantSidebarPanel: View {

    @ObservedObject var model: TaskExperienceViewModel
    let repository: TodoRepository
    @ObservedObject var dragContext: TaskQuadrantDragContext
    let onOpenDetail: (UUID) -> Void
    let onClose: () -> Void

    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    private var members: [TaskRecordSnapshot] { model.unclassifiedMembers }
    private var lists: [TodoList] { repository.allActiveLists() }

    var body: some View {
        Group {
            if dragContext.isDragging {
                collapsedStrip
            } else {
                fullPanel
            }
        }
        // 三验拍板：全高贴左缘（安全区顶 → 安全区底，盖过导航/筛选行），
        // 拖拽进行中收窄为 64pt 竖条，四格全部露出可达
        .frame(width: dragContext.isDragging
            ? TaskQuadrantMetrics.sidebarCollapsedWidth
            : TaskQuadrantMetrics.sidebarWidth
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TaskQuadrantPalette.sidebarTint.opacity(0.72))
        .background(.ultraThinMaterial)
        .clipShape(TaskQuadrantMetrics.sidebarShape)
        .overlay(
            // 拖回待确认悬停高亮：2pt 品牌橙描边提示可放（收窄态同样生效）
            TaskQuadrantMetrics.sidebarShape
                .strokeBorder(
                    dragContext.hoverSidebar ? TaskQuadrantPalette.accent : TaskQuadrantPalette.ink.opacity(0.08),
                    lineWidth: dragContext.hoverSidebar ? 2 : 0.5
                )
        )
        .shadow(color: Color(red: 30 / 255, green: 28 / 255, blue: 22 / 255).opacity(0.10), radius: 14, y: 8)
        // 落点：拖到侧栏（全宽或收窄竖条）= 移回待确认（两轴重置未判断）
        .onDrop(of: [UTType.plainText.identifier], delegate: pendingDropDelegate)
        .accessibilityElement(children: .contain)   // 容器标识（UI 测试定位侧栏），子元素保持可访问
        .accessibilityIdentifier("quadrant.sidebar")
    }

    // MARK: 全宽形态（范围筛选 + 待确认列表）

    private var fullPanel: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    scopeSection
                    divider
                    pendingSection
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 收窄竖条（拖拽进行中）：竖排「待确认」+计数，仍是移回待确认落点

    private var collapsedStrip: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 24)
            TaskQuadrantVerticalText(title: String(localized: "待确认"))
                .foregroundColor(TaskQuadrantPalette.handleText)
            Text(verbatim: "\(members.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(TaskQuadrantPalette.handleText)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.holoCardBackground))
                .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: 头部（标题 + 关闭）

    private var header: some View {
        HStack(spacing: 8) {
            Text("任务")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(TaskQuadrantPalette.ink)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TaskQuadrantPalette.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(TaskQuadrantPalette.fill))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quadrant.sidebar.close")
            .accessibilityLabel(Text("关闭"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: 范围筛选（原 TaskScopeSheet 的选择功能收编至此）

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeRow(.allUncompleted)
            scopeRow(.todayDue)
            scopeRow(.overdue)
            scopeRow(.inbox)
            if !lists.isEmpty {
                sectionLabel(String(localized: "清单"))
                ForEach(lists, id: \.id) { list in
                    listScopeRow(list)
                }
            }
            sectionLabel(String(localized: "历史"))
            scopeRow(.completed)
            scopeRow(.archived)
        }
    }

    private func scopeRow(_ value: TaskExperienceScope) -> some View {
        let selected = model.scope == value
        return Button {
            model.scope = value   // 历史范围由宿主 onChange 收起侧栏
        } label: {
            HStack(spacing: 6) {
                Text(value.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? TaskQuadrantPalette.accent : TaskQuadrantPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count = model.scopeCounts[value], count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(TaskQuadrantPalette.inkSecondary)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(TaskQuadrantPalette.accent)
                }
            }
            .frame(minHeight: 34)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func listScopeRow(_ list: TodoList) -> some View {
        let selected = model.scope == .list(list.id)
        return Button {
            model.scope = .list(list.id)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: list.color ?? "#007AFF"))
                    .frame(width: 7, height: 7)
                Text(list.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? TaskQuadrantPalette.accent : TaskQuadrantPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(TaskQuadrantPalette.accent)
                }
            }
            .frame(minHeight: 34)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(TaskQuadrantPalette.inkTertiary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var divider: some View {
        Rectangle()
            .fill(TaskQuadrantPalette.ink.opacity(0.06))
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.top, 12)
    }

    // MARK: 待确认列表

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("待确认")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(TaskQuadrantPalette.ink)
                HoloCountBadge(count: members.count)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                if index > 0 {
                    Rectangle()
                        .fill(TaskQuadrantPalette.ink.opacity(0.06))
                        .frame(height: 0.5)
                }
                row(member)
            }
        }
    }

    /// 待确认行（可长按拖出归位；系统拖拽，拖起时侧栏收窄）
    private func row(_ member: TaskRecordSnapshot) -> some View {
        let due = TaskQuadrantBoardView.dueFact(member, now: model.now, calendar: model.calendar)
        return TaskQuadrantTaskRow(
            member: member,
            dueText: due?.text,
            isOverdue: due?.isOverdue ?? false,
            isDone: model.pendingCompletionTaskID == member.id,
            onToggle: { toggleCompletion(member) },
            onOpenDetail: { onOpenDetail(member.id) },
            onDragStarted: { dragContext.beginDrag() }
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 完成/撤回（与格内同一协调器）
    private func toggleCompletion(_ member: TaskRecordSnapshot) {
        if model.pendingCompletionTaskID == member.id {
            completionCoordinator.undo(in: repository)
            HapticManager.light()
        } else {
            completionCoordinator.requestCompletion(taskID: member.id, source: .taskMatrix, in: repository)
            HapticManager.taskCompletion()
        }
    }

    /// 拖回待确认：统一走协调器（两轴重置未判断 + 可撤回横条），计数随通知链刷新
    private var pendingDropDelegate: TaskQuadrantPendingDropDelegate {
        TaskQuadrantPendingDropDelegate(
            context: dragContext,
            onCommit: { taskID in
                TaskPresentationActionCoordinator.shared.commitReturnToPending(
                    taskID: taskID,
                    repository: repository
                )
            }
        )
    }
}

// MARK: - 尺寸与节奏（原型数值集中）

enum TaskQuadrantMetrics {
    /// 页边距 16
    static let pageInset: CGFloat = 16
    /// 格间 gap 12（横纵同值）
    static let cellGap: CGFloat = 12
    /// 格圆角 18
    static let cellRadius: CGFloat = 18
    /// 侧栏全宽 / 拖拽中收窄宽度
    static let sidebarWidth: CGFloat = 200
    static let sidebarCollapsedWidth: CGFloat = 64
    /// 侧栏形状：左缘贴边直角、右侧圆角 20
    static var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(bottomTrailing: 20, topTrailing: 20),
            style: .continuous
        )
    }
    /// 侧栏开关节奏
    static let sidebarAnimation = Animation.spring(response: 0.32, dampingFraction: 0.9)
}

// MARK: - 竖排文字（收窄竖条「待确认」；CJK 逐字竖排，拉丁回退旋转）

private struct TaskQuadrantVerticalText: View {
    let title: String

    var body: some View {
        if title.count <= 4, title.allSatisfy({ !$0.isASCII }) {
            VStack(spacing: 3) {
                ForEach(Array(title.enumerated()), id: \.offset) { _, character in
                    Text(String(character))
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        } else {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .fixedSize()
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - 格头（彩底 + 名称/计数/副题 + 26pt 加号）

private struct TaskQuadrantCellHeader: View {
    let quadrant: TaskQuadrant
    let count: Int
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(quadrant.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(quadrant.tintColor)
                        .lineLimit(1)
                    if count > 0 {
                        Text(verbatim: "\(count)")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(quadrant.tintColor.opacity(0.72))
                    }
                }
                Text(quadrant.subtitleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(quadrant.tintColor.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(quadrant.tintColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(quadrant.tintColor.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "在\(quadrant.displayTitle)中新增任务"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(quadrant.backgroundColor)
    }
}

// MARK: - 任务行（格内与侧栏共用；系统拖拽拖出浮卡）

private struct TaskQuadrantTaskRow: View {
    let member: TaskRecordSnapshot
    let dueText: String?
    let isOverdue: Bool
    /// 撤回窗口内的「已完成」投影（对勾 + 减淡）
    let isDone: Bool
    let onToggle: () -> Void
    let onOpenDetail: () -> Void
    /// 拖起回调（宿主置收窄态）
    let onDragStarted: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                ring
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone
                ? String(localized: "恢复\(member.title)")
                : String(localized: "完成\(member.title)"))

            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(member.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(TaskQuadrantPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let dueText {
                        metaLine(dueText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(voiceOverLabel)
        }
        .opacity(isDone ? 0.55 : 1)
        // 系统拖拽（长按约 0.5s 浮起；ScrollView 内真机可靠——2026-11-05 真机实锤
        // 自定义 LongPress+Drag 组合手势在滚动容器内不触发后换用此机制，旧板同款）。
        // 浮卡=拖拽 preview，跟随手指；拖起时侧栏收窄（onDragStarted）。
        .onDrag {
            onDragStarted()
            return NSItemProvider(object: member.id.uuidString as NSString)
        } preview: {
            TaskQuadrantFloatCard(member: member, dueText: dueText, isOverdue: isOverdue)
        }
    }

    /// 20pt 勾选圈：常态 1.5pt 描边，逾期染红 45%（格内与侧栏同一取色源）；
    /// 完成态叠对勾
    private var ring: some View {
        ZStack {
            Circle()
                .strokeBorder(TaskQuadrantPalette.ringStroke(isOverdue: isOverdue), lineWidth: 1.5)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TaskQuadrantPalette.ink)
            }
        }
    }

    /// meta 行：日历图标 + 11pt tabular；逾期整行染 #C03A28、600
    private func metaLine(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10))
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, weight: isOverdue ? .semibold : .regular))
        .foregroundColor(isOverdue ? TaskQuadrantPalette.late : TaskQuadrantPalette.meta)
        .monospacedDigit()
    }

    private var voiceOverLabel: String {
        var parts = [member.title]
        if let dueText {
            parts.append(dueText)
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 拖拽浮卡（系统拖拽 preview：白卡圆角 18、双层阴影、-2° 旋转微放大）

private struct TaskQuadrantFloatCard: View {
    let member: TaskRecordSnapshot
    let dueText: String?
    let isOverdue: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .strokeBorder(TaskQuadrantPalette.ringStroke(isOverdue: isOverdue), lineWidth: 1.5)
                .frame(width: 20, height: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(member.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(TaskQuadrantPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let dueText {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 10))
                        Text(dueText)
                    }
                    .font(.system(size: 11, weight: isOverdue ? .semibold : .regular))
                    .foregroundColor(isOverdue ? TaskQuadrantPalette.late : TaskQuadrantPalette.meta)
                    .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 250, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.holoCardBackground)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 22, y: 18)
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 6)
        .rotationEffect(.degrees(-2))
        .scaleEffect(1.02)
    }
}

// MARK: - 象限规则说明（入口收在右上「···」菜单，2026-11-05 改版）

struct TaskQuadrantRulesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    ForEach(TaskQuadrant.overviewOrder, id: \.self) { quadrant in
                        HStack {
                            Text(quadrant.displayTitle)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(quadrant.tintColor)
                            Spacer()
                            Text(quadrant.subtitleText)
                                .font(.holoCaption)
                                .foregroundColor(.holoTextSecondary)
                        }
                        .padding(.vertical, 10)
                    }
                    Divider()
                    Text("重要性 P1 在重要侧，P2 / P3 在非重要侧。\n紧急性 P1 为紧急，P2 / P3 为非紧急。\n按日期自动折算：逾期、今天 / 明天 / 后天截止 → P1；3–7 天 → P2；更远或无截止 → P3。\n重要性或紧急性未判断的任务在待确认（点左上筛选行打开侧栏），长按拖到对应格归位；拖回侧栏即重置为待确认。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.xl)
            }
            .navigationTitle(String(localized: "象限规则"))
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
