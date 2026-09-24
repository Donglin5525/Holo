//
//  MatterDetailView.swift
//  Holo
//
//  事情详情页（方案 §13.4）：固定阅读顺序
//  ①标题/日期/阶段/操作 ②Holo 判断 ③现在最值得做 ④还没解决（confirmed 前、suggested 弱化）
//  ⑤已经解决 ⑥相关内容 ⑦最近变化 ⑧底部固定「和 Holo 讨论这件事」
//
//  红线：不显示进度百分比；完成/归档只能由用户点；suggested 与 confirmed 视觉永分离。
//

import SwiftUI

struct MatterDetailView: View {

    let matterID: UUID
    /// 「和 Holo 讨论这件事」出口（M1 关闭详情后由上层接管，M2 接 Matter-scoped Chat）。
    var onDiscuss: ((UUID) -> Void)? = nil

    @ObservedObject private var repository = HoloMatterRepository.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showCompleteConfirm = false
    @State private var showArchiveConfirm = false
    @State private var loadFailed = false
    /// 正在「转成任务」的 loop ID（防重复点击）。
    @State private var creatingTaskFromLoop: UUID?
    /// V2：任务完成经 TodoRepository 广播，驱动计划/下一步即时重算（INV-07 不经 LLM）。
    @State private var v2ReloadToken = 0

    var body: some View {
        // 注意：本视图不得自带 NavigationStack——它作为目的地被压入宿主导航栈
        // （Today 看板路由 / Matter 列表 push），「栈中栈」在 iOS 26 会卡死转场，
        // 连续压栈更触发 AnyNavigationPath comparisonTypeMismatch 断言闪退
        // （2026-09-20 东林真机+模拟器双复现）。弹窗根视图场景由调用方外部包栈
        // （HomeView / ChatView 的 sheet 已包），先例同 MatterListContent（§10.1）。
        ZStack(alignment: .bottom) {
            if loadFailed || matter == nil {
                missingView
            } else if let matter {
                content(matter)
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .navigationTitle(matter?.title ?? String(localized: "详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "关闭")) { dismiss() }
            }
        }
        .toolbar { toolbarTrailing }
        .confirmationDialog(
            String(localized: "完成这件事？"),
            isPresented: $showCompleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "确认完成")) {
                Task { try? await repository.completeMatter(id: matterID) }
            }
            Button(String(localized: "再等等"), role: .cancel) {}
        } message: {
            Text(String(localized: "完成后它会从首页焦点位撤下，你随时可以在列表里回看或重新打开。未解决的问题会保留记录。"))
        }
        .confirmationDialog(
            String(localized: "归档这件事？"),
            isPresented: $showArchiveConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "确认归档")) {
                Task { try? await repository.archiveMatter(id: matterID) }
            }
            Button(String(localized: "先不归档"), role: .cancel) {}
        } message: {
            Text(String(localized: "归档是轻性的收起，不删除任何数据，随时可以重新打开。"))
        }
    }

    // MARK: - 数据

    private var matter: HoloMatter? {
        repository.matter(id: matterID)
    }

    private func content(_ matter: HoloMatter) -> some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                if HoloMatterRolloutPolicy.unifiedLaunchV2Enabled {
                    // V2（2026-09-21 战略收敛 §4.2）：状态→下一步→计划→待确认；
                    // 内部词汇（phase/attention/证据/事件流）收进旧布局，主动查看才见。
                    v2Sections(matter)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        headerSection(matter)
                        judgmentSection(matter)
                        nextActionSection(matter)
                        openLoopsSection(matter)
                        resolvedSection(matter)
                        linksSection(matter)
                        eventsSection(matter)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
            discussButton(matter)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
            v2ReloadToken += 1
        }
    }

    // MARK: - V2 布局（§4.2：默认只回答状态、下一步、计划和待确认）

    /// 计划任务实时快照：确定性规则（planOrder 最小未完成 = 下一步），不读 projection 旧值。
    private var v2PlanTasks: [MatterPlanQuery.PlanTask] {
        _ = v2ReloadToken
        return MatterPlanQuery.planTasks(matterID: matterID, repository: repository)
    }

    private func v2Sections(_ matter: HoloMatter) -> some View {
        let tasks = v2PlanTasks
        let doneCount = tasks.filter(\.completed).count
        let next = tasks.first { !$0.completed }
        let activeLoops = repository.openLoops(matterID: matterID, activeOnly: true)
        let isCompleted = matter.lifecycle == .completed

        return VStack(alignment: .leading, spacing: 18) {
            v2Header(matter, isCompleted: isCompleted)
            if isCompleted {
                v2CompletedSummary(doneCount: doneCount, total: tasks.count)
            } else {
                v2Status(doneCount: doneCount, total: tasks.count)
                v2NextAction(next: next, hasActiveLoops: !activeLoops.isEmpty)
                v2PlanList(tasks)
                if !activeLoops.isEmpty {
                    v2PendingQuestions(activeLoops)
                }
            }
        }
    }

    private func v2Header(_ matter: HoloMatter, isCompleted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(matter.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if isCompleted {
                    Text(verbatim: "已完成")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                        .foregroundStyle(.green)
                }
                if let target = matter.targetDate {
                    Text(verbatim: "\(target.formatted(.dateTime.month().day())) 出发")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func v2Status(doneCount: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "当前状态")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(verbatim: "\(doneCount)/\(total) 已完成")
                .font(.subheadline.weight(.medium))
        }
    }

    private func v2NextAction(next: MatterPlanQuery.PlanTask?, hasActiveLoops: Bool) -> some View {
        Group {
            if let next {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "下一步 · \(next.title)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    // 分步推进在原卡内融合（2026-09-25 实施规格 §4.1）：
                    // 未采纳=帮我拆开入口；已采纳=一个动作+一次点击。
                    // 生成步骤不新增 TodoTask、不进 Matter 分母（E01/E04 锁定）。
                    MatterExecutionContent(
                        taskID: next.id,
                        repository: TodoRepository.shared,
                        originMatterID: matterID,
                        sourceSurface: "matter",
                        onDiscuss: { onDiscuss?(matterID) }
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if hasActiveLoops {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "当前状态")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(verbatim: "还需要确认一件事")
                        .font(.body.weight(.medium))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "准备已完成")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.green)
                    Button {
                        showCompleteConfirm = true
                    } label: {
                        Text(verbatim: "完成这件事")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private func v2PlanList(_ tasks: [MatterPlanQuery.PlanTask]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "计划 \(tasks.filter(\.completed).count)/\(tasks.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(tasks) { planTask in
                Button {
                    v2Toggle(planTask)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: planTask.completed ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(planTask.completed ? .green : .secondary)
                            .padding(.top, 1)
                        Text(planTask.title)
                            .font(.subheadline)
                            .strikethrough(planTask.completed)
                            .foregroundStyle(planTask.completed ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func v2PendingQuestions(_ loops: [HoloMatterOpenLoop]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "待确认 \(loops.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            ForEach(loops.prefix(3), id: \.id) { loop in
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Text(loop.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func v2CompletedSummary(doneCount: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(verbatim: "已完成")
                    .font(.headline)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            Text(verbatim: "\(doneCount)/\(total) 已完成 · 计划和对话保留，可随时回看。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// 计划行完成/撤销：走 Todo 域真实对象（INV-08 真实 ID），广播后本页即时重算。
    /// 完成报错不再吞（2026-09-25 实施规格 §8.4-1）：分步接管任务走统一完成语义。
    private func v2Toggle(_ planTask: MatterPlanQuery.PlanTask) {
        guard let task = repository.todoTask(id: planTask.id) else { return }
        do {
            if task.isExecutionManaged && !task.completed {
                // 已启用分步：直接完成 = 用户明确断言原结果（清单全勾不再自动完成根）
                try HoloTaskExecutionService.shared.completeRootDirectly(
                    taskID: task.id,
                    sourceSurface: "matter.planRow",
                    operationID: UUID().uuidString,
                    in: TodoRepository.shared
                )
            } else {
                // 普通任务或取消完成：原逻辑（重开保留步骤历史）
                try TodoRepository.shared.toggleTaskCompletion(task)
            }
        } catch {
            NSLog("[MatterDetail] 计划行完成失败: \(error.localizedDescription)")
        }
    }

    // MARK: ① 头部

    private func headerSection(_ matter: HoloMatter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(matter.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if matter.lifecycle == .completed {
                    Text(String(localized: "已完成"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                } else if let phase = matter.phase {
                    Text(phase.displayLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                if let target = matter.targetDate {
                    Text(Self.dateLine(target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if matter.lifecycle == .active {
                    // 高频意图直接给入口（原型 C1）：完成必须由用户亲手触发
                    Button {
                        NSLog("[MatterDiag] complete button tapped")
                        showCompleteConfirm = true
                    } label: {
                        Label(String(localized: "完成这件事"), systemImage: "flag.checkered")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.holoPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("matterCompleteButton")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var toolbarTrailing: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if matter?.lifecycle == .active {
                    Button {
                        showArchiveConfirm = true
                    } label: {
                        Label(String(localized: "归档"), systemImage: "archivebox")
                    }
                } else if matter?.lifecycle == .completed {
                    Button {
                        showArchiveConfirm = true
                    } label: {
                        Label(String(localized: "归档"), systemImage: "archivebox")
                    }
                    Button {
                        Task { try? await repository.reopenMatter(id: matterID) }
                    } label: {
                        Label(String(localized: "重新打开"), systemImage: "arrow.uturn.backward")
                    }
                } else if matter?.lifecycle == .archived {
                    Button {
                        Task { try? await repository.reopenMatter(id: matterID) }
                    } label: {
                        Label(String(localized: "重新打开"), systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(String(localized: "更多操作"))
        }
    }

    // MARK: ② Holo 判断

    private func judgmentSection(_ matter: HoloMatter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(String(localized: "HOLO 判断"))
            let projection = matter.projection
            let isStale = matter.isProjectionStale
            VStack(alignment: .leading, spacing: 7) {
                if isStale {
                    Label(String(localized: "判断正在更新，先看下面的状态"), systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(displaySummary(matter: matter, projection: projection))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = projection?.attentionReason, !reason.isEmpty, !isStale {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "info.circle").font(.caption2)
                        Text(reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color.holoPrimary.opacity(0.06))
            )
        }
    }

    /// 投影 stale 或缺失 → 确定性降级文案，不显示旧判断为当前结论（方案 §9.2）。
    private func displaySummary(matter: HoloMatter, projection: HoloMatterProjectionV1?) -> String {
        if let projection, !matter.isProjectionStale {
            return projection.summary
        }
        let loops = repository.openLoops(matterID: matter.id)
        let activeCount = loops.filter { $0.state == .open || $0.state == .waiting }.count
        if activeCount > 0 {
            return String(localized: "还有 \(activeCount) 个问题没有闭环。")
        }
        return String(localized: "暂无待处理问题。")
    }

    // MARK: ③ 现在最值得做

    @ViewBuilder
    private func nextActionSection(_ matter: HoloMatter) -> some View {
        let projection = matter.projection
        let nextAction: HoloMatterNextAction? = {
            guard let projection, !matter.isProjectionStale else { return nil }
            return projection.nextAction
        }()
        if let next = nextAction {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "现在最值得做"))
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.holoPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(next.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .strokeBorder(Color.holoPrimary.opacity(0.4), lineWidth: 1.2)
                )
                // 类型化动作出口（§8.4）：与 Today Hero 共用同一解析，无 entityID 只能讨论。
                nextActionActions(next, matterID: matter.id)
            }
        }
        // 没有依据就不显示「下一步」区块（不填充泛泛建议）。
    }

    /// Next Action 的动作行（与 TodayActionDispatcher 同一解析语义）。
    @ViewBuilder
    private func nextActionActions(_ next: HoloMatterNextAction, matterID: UUID) -> some View {
        HStack(spacing: 10) {
            switch next.kind {
            case .linkedTask:
                if let entityID = next.entityID.flatMap(UUID.init(uuidString:)),
                   TodoRepository.shared.findTask(by: entityID) != nil {
                    actionButton(String(localized: "查看任务"), systemImage: "checklist") {
                        dismiss()
                        DeepLinkState.shared.navigate(to: .taskDetail(taskId: entityID))
                    }
                } else {
                    // entityID 丢失/任务已删：不猜标题，降级为讨论。
                    actionButton(String(localized: "和 Holo 梳理"), systemImage: "bubble.left.and.text.bubble.right") {
                        onDiscuss?(matterID)
                    }
                }
            case .openLoopAction:
                if let loopID = next.entityID.flatMap(UUID.init(uuidString:)) {
                    actionButton(String(localized: "转成任务"), systemImage: "plus.circle") {
                        creatingTaskFromLoop = loopID
                        Task {
                            _ = try? await HoloMatterLinkingCoordinator.createTaskFromOpenLoop(
                                matterID: matterID, openLoopID: loopID
                            )
                            creatingTaskFromLoop = nil
                        }
                    }
                    .disabled(creatingTaskFromLoop == loopID)
                }
            case .suggestion:
                // 建议只引导讨论确认，不直接执行。
                actionButton(String(localized: "和 Holo 确认"), systemImage: "questionmark.bubble") {
                    onDiscuss?(matterID)
                }
            }
        }
        .padding(.top, 2)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: ④ 还没解决

    private func openLoopsSection(_ matter: HoloMatter) -> some View {
        let loops = repository.openLoops(matterID: matter.id).filter { $0.state == .open || $0.state == .waiting }
        let confirmed = loops.filter { $0.epistemic == .confirmed }
        let suggested = loops.filter { $0.epistemic == .suggested }
        return Group {
            if !loops.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(String(localized: "还没解决 · \(loops.count)"))
                    ForEach(confirmed) { loop in
                        // 省略号为显式 Menu（§8.5：点按即弹，不依赖长按 context menu）。
                        MatterOpenLoopRow(
                            title: loop.title,
                            epistemic: .confirmed,
                            state: loop.state
                        ) {
                            if loop.state == .open {
                                Button {
                                    Task { try? await repository.setOpenLoopState(id: loop.id, state: .waiting, actor: .user) }
                                } label: {
                                    Label(String(localized: "标记为等待中"), systemImage: "hourglass")
                                }
                            }
                            Button(role: .destructive) {
                                Task { try? await repository.dismissOpenLoop(id: loop.id, actor: .user) }
                            } label: {
                                Label(String(localized: "不需要处理"), systemImage: "xmark.circle")
                            }
                        }
                    }
                    ForEach(suggested) { loop in
                        MatterOpenLoopRow(
                            title: String(localized: "可能还需要确认：\(loop.title)"),
                            epistemic: .suggested,
                            state: loop.state
                        ) {
                            Button {
                                Task { try? await repository.confirmOpenLoop(id: loop.id) }
                            } label: {
                                Label(String(localized: "确认这是待办问题"), systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                Task { try? await repository.dismissOpenLoop(id: loop.id, actor: .user) }
                            } label: {
                                Label(String(localized: "不需要处理"), systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: ⑤ 已经解决

    @ViewBuilder
    private func resolvedSection(_ matter: HoloMatter) -> some View {
        let resolved = repository.openLoops(matterID: matter.id).filter { $0.state == .resolved }
        if !resolved.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "已经解决 · \(resolved.count)"))
                ForEach(resolved) { loop in
                    MatterResolvedLoopRow(
                        title: loop.title,
                        resolvedNote: Self.resolvedNote(loop, clock: Date())
                    )
                }
            }
        }
    }

    // MARK: ⑥ 相关内容

    @ViewBuilder
    private func linksSection(_ matter: HoloMatter) -> some View {
        let links = repository.links(matterID: matter.id)
        let counts = Self.linkCounts(links)
        if !counts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "相关内容"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(counts, id: \.0) { entry in
                            Text("\(entry.1) \(entry.0)")
                                .font(.caption)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                        }
                    }
                }
            }
        }
    }

    // MARK: ⑦ 最近变化

    @ViewBuilder
    private func eventsSection(_ matter: HoloMatter) -> some View {
        let events = repository.events(matterID: matter.id, limit: 20)
        let displayable = events.filter { Self.isDisplayable($0) }
        if !displayable.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(String(localized: "最近变化"))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(displayable.prefix(8)) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: HoloMatterEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.eventDate(event.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.eventText(event))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let revertID = revertableEventID(event) {
                    Button {
                        Task { try? await repository.revertEvent(eventID: revertID) }
                    } label: {
                        Text(String(localized: "撤销"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.holoPrimary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("matterRevertButton")
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 可撤销的自动更新事件：返回该事件自身的 id（撤销按事件 id 反向回滚）。
    /// 已撤销过的事件不再提供撤销入口。
    private func revertableEventID(_ event: HoloMatterEvent) -> UUID? {
        guard event.kind == .openLoopResolved, event.actor == .assistant else { return nil }
        if repository.events(matterID: matterID).contains(where: { $0.revertsEventID == event.id }) {
            return nil
        }
        return event.id
    }

    // MARK: ⑧ 底部讨论

    private func discussButton(_ matter: HoloMatter) -> some View {
        Button {
            onDiscuss?(matter.id)
        } label: {
            Label(String(localized: "和 Holo 讨论这件事"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.holoPrimary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: Color.holoPrimary.opacity(0.3), radius: 10, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.holoBackground.ignoresSafeArea(edges: .bottom))
    }

    // MARK: - 空态 / 确认弹窗

    private var missingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(String(localized: "这件事不存在或已删除"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 静态工具

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }

    nonisolated private static func dateLine(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return String(localized: "\(formatter.string(from: date))为目标")
    }

    nonisolated private static func resolvedNote(_ loop: HoloMatterOpenLoop, clock: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let when = formatter.string(from: loop.resolvedAt ?? clock)
        let source = (loop.epistemic == .suggested)
            ? String(localized: "AI 建议，已解决")
            : String(localized: "你确认过的问题")
        return "\(when) · \(source)"
    }

    nonisolated private static func eventDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 展示白名单：系统内部事件（projectionRefreshed 等）不进「最近变化」。
    nonisolated private static func isDisplayable(_ event: HoloMatterEvent) -> Bool {
        switch event.kind {
        case .activated, .openLoopAdded, .openLoopConfirmed, .openLoopResolved, .openLoopDismissed,
             .linkAdded, .completed, .archived, .reopened, .reverted:
            return true
        case .titleChanged, .openLoopReopened, .linkRemoved, .projectionRefreshed:
            return false
        }
    }

    nonisolated private static func eventText(_ event: HoloMatterEvent) -> String {
        switch event.kind {
        case .activated:
            return String(localized: "你开始了「\(eventAnchorTitle(event))」")
        case .openLoopAdded:
            return String(localized: "新增问题「\(eventAnchorTitle(event))」")
        case .openLoopConfirmed:
            return String(localized: "你确认了问题「\(eventAnchorTitle(event))」")
        case .openLoopResolved:
            let who = event.actor == .assistant
                ? String(localized: "你在对话里说")
                : String(localized: "你标记")
            let title = event.payload["title"] ?? ""
            if title.isEmpty {
                return String(localized: "一个问题已解决")
            }
            return "\(who)「\(title)」已解决"
        case .openLoopDismissed:
            return String(localized: "「\(eventAnchorTitle(event))」不需要处理")
        case .linkAdded:
            return String(localized: "关联了新内容")
        case .completed:
            return String(localized: "你完成了这件事 🎉")
        case .archived:
            return String(localized: "这件事已归档")
        case .reopened:
            return String(localized: "你重新打开了这件事")
        case .reverted:
            return String(localized: "更新已撤销")
        case .titleChanged, .openLoopReopened, .linkRemoved, .projectionRefreshed:
            return ""
        }
    }

    /// 事件正文标题：优先 payload，其次落到 source entity。
    nonisolated private static func eventAnchorTitle(_ event: HoloMatterEvent) -> String {
        let payload = event.payload
        if let title = payload["title"], !title.isEmpty { return title }
        return payload["openLoopID"] ?? ""
    }

    /// 相关内容计数（按真实 link 分类，方案 §13.4-6）。
    nonisolated private static func linkCounts(_ links: [HoloMatterLink]) -> [(String, Int)] {
        var counts: [String: Int] = [:]
        for link in links where link.isLinked {
            let name: String
            switch link.entityType {
            case .contextPlan: name = String(localized: "方案")
            case .todoTask: name = String(localized: "任务")
            case .thought: name = String(localized: "想法")
            case .chatMessage: name = String(localized: "对话")
            default: continue
            }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
