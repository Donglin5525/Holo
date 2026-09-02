//
//  MemoryGalleryView.swift
//  Holo
//
//  记忆长廊主视图 — 日历 / 洞察 两 tab（L1 轻头部：tab 并入标题栏右侧 + 两 tab 常驻不销毁）
//  日历（日/周/月三档时间刻度，逐条事实）/ 洞察（理解档案 + 热力图 + 回放叙事）
//

import SwiftUI

/// 记忆长廊主视图
struct MemoryGalleryView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }

    // MARK: - State

    @StateObject private var viewModel = MemoryGalleryViewModel()
    @State private var selectedTab: MemoryGalleryTab = .calendar
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    #if DEBUG
    /// 是否显示 AI 设置页
    @State private var showAISettings = false
    #endif

    // MARK: - Body

    var body: some View {
        ZStack {
            // 背景独立铺层（与任务/财务等模块同一模式）。
            // 不能写成 .background(Color.ignoresSafeArea())：该写法会把「忽略安全区」
            // 包装住整个内容 VStack，突破骨架层 720 列的布局上限，导致长廊通铺全宽。
            Color.holoBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部导航栏（右侧并入页级 tab，L1 轻头部）
                navigationBar

                // 首访欢迎条：第一次进长廊时讲清「这里会自动汇集你的记录」，
                // 挂在默认落地的日历 tab（新用户长廊是空的，日历本身看不出用途）
                if selectedTab == .calendar {
                    FirstVisitWelcomeBar(
                        icon: "book.fill",
                        title: "欢迎来到记忆长廊",
                        message: "你的每条记录都会自动汇到这里，按日、周、月回看生活；右侧「洞察」是 Holo 对你的理解档案。",
                        seenKey: OnboardingProgressStore.memoryGalleryWelcomeKey
                    )
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.top, HoloSpacing.sm)
                }

                // 主内容区：两 tab 常驻不销毁（切走仅隐藏），
                // 日历侧的取数与网格状态跨切换存活，消除切回卡顿
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .swipeBackToDismiss(isResidentScreenRoot: true) { close() }
        #if DEBUG
        .sheet(isPresented: $showAISettings) {
            NavigationStack {
                AISettingsView()
            }
        }
        #endif
        .task {
            #if DEBUG
            if HoloAppStoreScreenshotSeeder.requestedRoute == .memoryInsight ||
               HoloAppStoreScreenshotSeeder.requestedRoute == .memoryExtraction {
                selectedTab = .insight
            }
            #endif
            consumeMemoryFocus()
            await viewModel.refresh()
        }
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            consumeMemoryFocus()
        }
    }

    /// 消费「聚焦新记忆」跳转：切到洞察 Tab，新记忆由列表既有的「新」徽章高亮。
    private func consumeMemoryFocus() {
        guard case .memoryGallery(let focusNewMemories) = deepLinkState.pendingTarget,
              focusNewMemories else { return }
        selectedTab = .insight
        deepLinkState.pendingTarget = nil
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        // 标题绝对居中：底层左右各排返回键与视图开关，上层标题对齐屏幕正中，
        // 不再受两侧元素宽度差影响（此前右侧分段 106pt vs 左侧 44pt 把标题挤偏）
        ZStack {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                Spacer(minLength: 0)

                // 页级视图拨动开关（左＝日历 / 右＝洞察）
                MemoryViewToggleSwitch(selectedTab: $selectedTab)
            }
            .padding(.horizontal, HoloSpacing.sm)

            Text("记忆长廊")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundColor(.holoTextPrimary)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
        .background(Color.holoBackground)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.holoBorder.opacity(0), Color.holoBorder.opacity(0.42), Color.holoBorder.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
        }
    }

    // MARK: - Tab Content

    /// 两 tab 常驻：隐藏而非销毁。若用 switch 切换，CalendarRootView 的
    /// @StateObject 会随切走释放、切回重建，触发 ±60 天全量重载 —— 切换动画同帧
    /// 跑四模块取数 + 泳道重建，即此前「洞察切回日历肉眼可见卡顿」的根因。
    private var tabContent: some View {
        ZStack {
            calendarTab
                .opacity(selectedTab == .calendar ? 1 : 0)
                .allowsHitTesting(selectedTab == .calendar)
                .accessibilityHidden(selectedTab != .calendar)

            insightTab
                .opacity(selectedTab == .insight ? 1 : 0)
                .allowsHitTesting(selectedTab == .insight)
                .accessibilityHidden(selectedTab != .insight)
        }
    }

    // MARK: - 日历 Tab（日回放 / 周网格 / 月月历）

    private var calendarTab: some View {
        CalendarRootView()
    }

    // MARK: - 洞察 Tab

    @ViewBuilder
    private var insightTab: some View {
        if viewModel.isLoading && viewModel.timelineSections.isEmpty {
            skeletonView
        } else if let errorMessage = viewModel.errorMessage {
            errorView(message: errorMessage)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    insightChapterHeader

                    VStack(spacing: HoloSpacing.lg) {
                        // 报告门卡（一个家两个门）：最新一份报告的轻入口，直达 Holo AI 报告 Tab。
                        // 无报告时不展示，长廊对无报告用户保持零噪音。
                        if let reportEntry = viewModel.latestReportEntry {
                            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                                sectionHeading(title: "它看懂了你", icon: "sparkles")
                                ReportDoorCard(entry: reportEntry) {
                                    DeepLinkState.shared.navigate(to: .ai(voiceInput: false))
                                    ChatReportTabRouter.shared.openReportTab()
                                }
                            }
                        }

                        // 用户只看到可理解的记忆结论与控制，不暴露内部评分参数。
                        DomainMemorySection()

                        // Daily Sense 状态卡片
                        if InsightFeatureFlags.dailySenseEnabled,
                           let snapshot = viewModel.dailySenseSnapshot,
                           !snapshot.signals.isEmpty {
                            DailySenseStatusCard(snapshot: snapshot)
                        }

                        // 活跃热力图（原明细 tab 资产，随两 tab 收敛迁入洞察）
                        heatmapSection

                        // 一起做的计划（LifePlan 台账）：理解档案第三块
                        LifePlanGallerySection()

                        featuredStoriesSection
                    }
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.bottom, HoloSpacing.lg)
                }
                .containerRelativeFrame(.horizontal, alignment: .leading)
            }
        }
    }

    /// 洞察与日/周/月共用「章节开场」语法：一个大主题、一句解释、一行事实证据。
    private var insightChapterHeader: some View {
        HStack(spacing: 12) {
            Text("理解")
                .font(.system(size: 42, weight: .medium, design: .serif))
                .foregroundColor(.holoTextPrimary)
                .tracking(-2)
                .frame(minWidth: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Holo 看见的你")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundColor(.holoTextPrimary)
                Text("\(viewModel.totalRecordedDays) 天生活证据 · \(viewModel.totalMemoryCount) 条记录")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 34, height: 34)
                .background(Color.holoPrimary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .padding(.horizontal, HoloSpacing.md)
        .frame(minHeight: 92)
        .background(
            LinearGradient(
                colors: [Color.holoBackground.opacity(0.99), Color.holoBackground.opacity(0.94)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.68), Color.holoPrimary.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 104, height: 1)
            .padding(.leading, HoloSpacing.md)
        }
        .padding(.bottom, HoloSpacing.md)
        .accessibilityElement(children: .combine)
    }

    /// 选中日期预览卡片
    private func selectedDatePreview(date: Date) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            let formatter = DateFormatter()
            let dateStr: String = {
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 EEEE"
                return formatter.string(from: date)
            }()

            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.holoPrimary)

                Text(dateStr)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: 0)

                Text("当天轨迹")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPlaceholder)
            }

            if let section = viewModel.timelineSections.first(where: {
                Calendar.current.isDate($0.date, inSameDayAs: date)
            }) {
                let summary = section.nodes.compactMap { node -> DailySummaryData? in
                    if case .summary(let data) = node.data { return data }
                    return nil
                }.first

                if let summary = summary {
                    selectedDateStats(summary)
                } else {
                    Text("当天暂无记录")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPlaceholder)
                }
            } else {
                Text("当天暂无记录")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPlaceholder)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func selectedDateStats(_ summary: DailySummaryData) -> some View {
        let stats = selectedDateStatItems(summary)

        if stats.isEmpty {
            Text("当天暂无记录")
                .font(.holoCaption)
                .foregroundColor(.holoTextPlaceholder)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: HoloSpacing.sm)], spacing: HoloSpacing.sm) {
                ForEach(stats) { stat in
                    previewStat(stat)
                }
            }
        }
    }

    private func previewStat(_ stat: MemoryPreviewStatItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: stat.icon)
                .font(.system(size: 12))
                .foregroundColor(stat.color)

            Text(stat.value)
                .font(.holoCaption)
                .fontWeight(.semibold)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(stat.label)
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
        }
        .padding(HoloSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stat.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
    }

    private func selectedDateStatItems(_ summary: DailySummaryData) -> [MemoryPreviewStatItem] {
        var stats: [MemoryPreviewStatItem] = []

        if let expense = summary.totalExpense {
            stats.append(MemoryPreviewStatItem(
                icon: "yensign.circle",
                value: formatExpense(expense),
                label: "支出",
                color: .holoPrimary
            ))
        }

        if summary.habitsTotal > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "figure.run",
                value: "\(summary.habitsCompleted)/\(summary.habitsTotal)",
                label: "习惯",
                color: .holoSuccess
            ))
        }

        if summary.tasksCompleted > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "checkmark.circle",
                value: "\(summary.tasksCompleted)",
                label: "任务",
                color: .holoPrimary
            ))
        }

        if summary.thoughtCount > 0 {
            stats.append(MemoryPreviewStatItem(
                icon: "bubble.left",
                value: "\(summary.thoughtCount)",
                label: "想法",
                color: .holoPurple
            ))
        }

        return stats
    }

    @ViewBuilder
    private var featuredStoriesSection: some View {
        let stories = viewModel.featuredNarrativeNodes()

        if !stories.isEmpty {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                sectionHeading(title: "可回看的片段", icon: "bookmark.fill")

                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    ForEach(stories) { item in
                        featuredStoryRow(item)
                    }
                }
            }
        }
    }

    private func sectionHeading(title: String, icon: String) -> some View {
        HStack(spacing: HoloSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoPrimary)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featuredStoryRow(_ item: FeaturedMemoryNode) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack(spacing: HoloSpacing.xs) {
                Text(item.section.formattedDate)
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Text(item.section.displayLabel)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.xs)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }

            switch item.node.data {
            case .milestone(let milestoneData):
                MilestoneNode(data: milestoneData)
            case .highlight(let highlightData):
                GentleHighlightNode(data: highlightData)
            case .summary:
                EmptyView()
            }
        }
    }

    // MARK: - 活跃热力图（洞察 Tab）

    /// 13 周活跃热力图 + 点选日的「当天轨迹」伴生卡
    private var heatmapSection: some View {
        VStack(spacing: HoloSpacing.md) {
            MemoryHeatmapView(
                data: viewModel.heatmapData,
                selectedDate: viewModel.selectedHeatmapDate
            ) { date in
                viewModel.selectedHeatmapDate = date
                Task { await viewModel.ensureWeekLoaded(date) }
            }

            if let selectedDate = viewModel.selectedHeatmapDate {
                selectedDatePreview(date: selectedDate)
            }
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 36))
                .foregroundColor(.holoTextPlaceholder)

            Text(message)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("重试")
                    .font(.holoBody)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, HoloSpacing.xl)
                    .padding(.vertical, HoloSpacing.sm)
                    .overlay(
                        Capsule().stroke(Color.holoPrimary, lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Skeleton View

    private var skeletonView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: HoloSpacing.lg) {
                ForEach(0..<4, id: \.self) { _ in
                    skeletonCard
                        .shimmer()
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.lg)
            .containerRelativeFrame(.horizontal, alignment: .leading)
        }
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.holoBorder)
                    .frame(width: 12, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.holoBorder)
                    .frame(width: 100, height: 14)
            }

            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 80, height: 20)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 60, height: 20)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.holoBorder)
                    .frame(width: 40, height: 20)
            }
        }
        .padding(16)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - Formatter

    private func formatExpense(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: value as NSDecimalNumber) ?? "¥0"
    }
}

// MARK: - Supporting Models

private struct MemoryPreviewStatItem: Identifiable {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var id: String { label }
}

// MARK: - Preview

#Preview {
    MemoryGalleryView()
}
