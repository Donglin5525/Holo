//
//  HealthView.swift
//  Holo
//
//  健康主视图
//

import SwiftUI
#if canImport(UIKit)
#else
import AppKit
#endif

// MARK: - HealthView

struct HealthView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var motionScenePhase
    @Environment(\.holoMotionSurfaceIsActive) private var motionSurfaceActive
    @AppStorage(HoloMotionRollout.interactionKey) private var motionEnabled = true
    private var animateSync: Bool { isRefreshing && motionEnabled && !reduceMotion && motionScenePhase == .active && motionSurfaceActive }
    @Environment(\.dismiss) private var dismiss
    /// ZStack 平级常驻模式下的关闭动作（由 HomeView 注入）。
    /// 未注入时（旧 sheet/cover 场景）fallback 到 @Environment(\.dismiss)。
    @Environment(\.holoDismiss) private var holoDismiss
    /// 统一关闭入口：优先 holoDismiss，否则 dismiss。
    private var close: () -> Void { holoDismiss ?? { dismiss() } }
    @ObservedObject private var repository = HealthRepository.shared
    @State private var selectedMetric: HealthMetricType?
    @State private var showVitals = false
    @State private var weeklySleepData: [DailyHealthData] = []
    @State private var weeklyStepsData: [DailyHealthData] = []
    @State private var weeklyWorkoutData: [DailyHealthData] = []
    /// 趋势卡当前指标（睡眠/步数/运动可切换，默认睡眠）
    @State private var trendMetric: HealthMetricType = .sleep
    @State private var isRefreshing = false
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    /// 切天内容滑入方向：切明天从右进、切昨天从左进（switchDay 里更新）
    @State private var dayContentEdge: Edge = .leading
    /// 左右滑动切天的实时手势标记：快速轻扫时点击回调需同步读取，防止误触进详情/弹层
    @State private var daySwipeState = DaySwipeGestureState()
    @State private var dayData = HealthDayData()
    @State private var insightViewModel = HealthInsightViewModel()
    @State private var selectedEvidenceInsight: GeneratedHealthInsight?
    /// 日期数据加载代数（R10，2026-10-04 体检）：快速切天时旧请求不得覆盖新日期
    @State private var dateLoadGeneration = 0

    /// 宽屏双栏（通宵冲刺 D1）：expanded 档左（hero+指标+数据源）/右（洞察+生活闭环+周趋势），
    /// 修复单列卡片流在 iPad 全宽拉伸的「放大版 iPhone」观感；iPhone/竖屏单列不变。
    @Environment(\.holoContentWidth) private var healthWindowWidth
    private var isExpandedWidth: Bool {
        HoloAdaptiveLayout.isExpandedWidth(healthWindowWidth)
    }

    private var snapshot: HealthDashboardSnapshot {
        let stepsAvail: HealthMetricAvailability = dayData.steps > 0 ? .available : .noData
        let sleepAvail: HealthMetricAvailability = dayData.sleep > 0 ? .available : .noData
        let workoutAvail: HealthMetricAvailability = dayData.workoutMinutes > 0 ? .available : .noData
        let standAvail: HealthMetricAvailability
        if dayData.standHours > 0 {
            standAvail = .available
        } else if dayData.activeMinutes > 0 {
            standAvail = .unsupported
        } else {
            standAvail = .noData
        }

        return HealthDashboardSnapshot(
            steps: HealthMetricSnapshot(type: .steps, value: dayData.steps, availability: stepsAvail),
            sleep: HealthMetricSnapshot(type: .sleep, value: dayData.sleep, availability: sleepAvail),
            workout: HealthMetricSnapshot(type: .workout, value: dayData.workoutMinutes, availability: workoutAvail),
            standOrActivity: HealthDashboardSnapshot.standOrActivitySnapshot(
                standHours: dayData.standHours,
                activeMinutes: dayData.activeMinutes,
                standAvailability: standAvail
            ),
            dataSourceState: repository.dataSourceState
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if shouldShowPermissionView {
                    topBackBar
                    HealthPermissionView(
                        onAuthorize: requestPermission,
                        onDismiss: { close() }
                    )
                } else if shouldShowUnavailableView {
                    topBackBar
                    unavailableView
                } else {
                    healthContent
                }
            }
            .navigationDestination(item: $selectedMetric) { metric in
                HealthDetailView(type: metric, selectedDate: $selectedDate)
            }
            .navigationDestination(isPresented: $showVitals) {
                VitalsView()
            }
            #if canImport(UIKit)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        // 手势挂在 NavigationStack 外面时让位判断恒失效（见 SwipeBackModifier 文档），
        // 必须按 push 状态显式门控：详情页/身体状态页在前台时整层失效，
        // 边缘右滑交给两个子页面各自的 swipeBackToDismiss(ignoreNavigationStack: true)
        .swipeBackToDismiss(
            isEnabled: selectedMetric == nil && !showVitals,
            isResidentScreenRoot: true
        ) {
            if selectedMetric != nil {
                selectedMetric = nil
            } else {
                close()
            }
        }
        .task {
            await refreshAll()
            // 洞察改为后台隐性生成：页面只读缓存立即显示，生成不随页面离场取消
            insightViewModel.load()
        }
        .onChange(of: selectedDate) {
            Task { await loadDateData(for: selectedDate) }
        }
        .sheet(item: $selectedEvidenceInsight) { insight in
            HealthInsightEvidenceSheet(
                insight: insight,
                evidence: insightViewModel.snapshot?.evidence ?? [],
                periodBadgeText: insightPeriodBadgeText
            )
        }
    }

    private var shouldShowPermissionView: Bool {
        !repository.hasRequestedPermission && repository.dataSourceState == .notRequested
    }

    private var shouldShowUnavailableView: Bool {
        repository.dataSourceState == .denied || repository.dataSourceState == .unavailable
    }

    private var healthContent: some View {
        VStack(spacing: 0) {
            headerView
            // 左右滑动切天（与账本页共用容器）：左缘 24pt 让位给右滑返回手势
            DaySwipeContainer(
                state: daySwipeState,
                onDayChange: { forward in switchDay(forward: forward) },
                canSwipeForward: !Calendar.current.isDateInToday(selectedDate),
                edgeExclusionWidth: 24
            ) {
                // 方案甲拆段后 .id 不再挂在内容根上（周期段不随日期换身份），
                // 滚动复位改由锚点 scrollTo 承担，ScrollViewReader 提供锚点滚动
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        if isExpandedWidth {
                            expandedColumns
                        } else {
                            singleColumnStack
                        }
                    }
                    .onChange(of: selectedDate) {
                        scrollToDateTop(proxy)
                    }
                }
            }
        }
        .background(Color.holoToolBackground)
    }

    /// 单列阅读动线（方案甲）：日期段①（今天+趋势）→ 周期段（洞察+闭环，不随日期滑动）
    /// → 日期段②（身体状态+数据源）→ 页脚
    private var singleColumnStack: some View {
        VStack(spacing: HoloSpacing.md) {
            dateSwipeSection(anchor: healthDateTopAnchorID) {
                VStack(spacing: HoloSpacing.md) {
                    todayCard
                    weeklyTrendCard
                }
            }

            periodSection

            dateSwipeSection {
                VStack(spacing: HoloSpacing.md) {
                    vitalsEntry
                    if shouldShowDataSourceCard {
                        dataSourceCard
                    }
                }
            }

            healthFootnote
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.vertical, HoloSpacing.md)
    }

    /// 宽屏双栏（方案甲）：左栏整体为日期段（今天+体征+数据源，随切天滑动）；
    /// 右栏上部日期段（趋势）+ 下部周期段（洞察+闭环+页脚，不随日期滑动）
    private var expandedColumns: some View {
        HStack(alignment: .top, spacing: HoloSpacing.md) {
            dateSwipeSection(anchor: healthDateTopAnchorID) {
                VStack(spacing: HoloSpacing.md) {
                    todayCard
                    vitalsEntry
                    if shouldShowDataSourceCard {
                        dataSourceCard
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: HoloSpacing.md) {
                dateSwipeSection {
                    weeklyTrendCard
                }
                periodSection
                healthFootnote
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, HoloSpacing.page)
        .padding(.vertical, HoloSpacing.md)
    }

    /// 周期段：核心洞察与生活闭环是近 N 天的周期结论，与所选日期无关，
    /// 不挂 .id 不参与切天过渡（方案甲：切天时只有日期段滑动）
    private var periodSection: some View {
        VStack(spacing: HoloSpacing.md) {
            if let core = generatedCoreInsight {
                coreInsightCard(core)
            }
            lifestyleInsightCard
        }
    }

    /// 日期段容器：段内容随切天换身份整段方向性滑入。
    /// 必须包 ZStack(alignment: .top)——.id 换身份过渡期间新旧两份视图同时存在，
    /// VStack 兄弟会把两份上下堆叠穿帮，ZStack 让它们重叠过渡，段高按 max(旧,新) 平滑变化。
    /// anchor 非 nil 时在段容器上暴露滚动复位锚点（日期段① 挂顶部锚点）。
    @ViewBuilder
    private func dateSwipeSection<Content: View>(
        anchor: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let section = ZStack(alignment: .top) {
            content()
                // 切天内容方向性滑入：id 随日期切换换身份触发过渡
                .id(selectedDate)
                .transition(.asymmetric(
                    insertion: .move(edge: dayContentEdge).combined(with: .opacity),
                    removal: .opacity
                ))
        }
        if let anchor {
            section.id(anchor)
        } else {
            section
        }
    }

    /// 切天滚动复位：三个切天入口（滑动/箭头/日历）都写 selectedDate，
    /// 统一在此一处复位到日期段① 顶部（与切天同一动画节奏）
    private func scrollToDateTop(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(healthDateTopAnchorID, anchor: .top)
        } else {
            withAnimation(HoloAnimation.standard) {
                proxy.scrollTo(healthDateTopAnchorID, anchor: .top)
            }
        }
    }

    /// 日期段① 的滚动复位锚点（scrollTo 目标）
    private let healthDateTopAnchorID = "healthDateTop"

    /// 数据源状态卡只在异常（部分连接）时常驻展示；
    /// 正常连接的同步状态已由头部副标题承载，不再打断内容动线。
    private var shouldShowDataSourceCard: Bool {
        repository.dataSourceState == .partiallyConnected
    }

    private var healthFootnote: some View {
        Text("数据来自 Apple Health · 身体分与洞察仅供参考")
            .holoText(.metadata)
            .foregroundColor(.holoToolTextSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 返回首页按钮（对齐全局 fullScreenCover 模块约定，复用于各分支）
    private var backButton: some View {
        HoloIconButton(systemName: "chevron.left", title: "返回", showsSurface: true) {
            close()
        }
    }

    /// 权限引导 / 不可用兜底分支的固定返回栏
    private var topBackBar: some View {
        HStack {
            backButton
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.sm)
    }

    /// 顶栏一行（返回/标题/同步）+ 日期行；所有日期状态下高度一致，切天不跳动。
    /// 数据来源与免责说明由页脚承载，不再占副标题位（「刚刚」写死问题随副标题一并移除）。
    private var headerView: some View {
        VStack(spacing: HoloSpacing.xs) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                backButton

                Text("健康")
                    .holoText(.pageTitle)
                    .foregroundColor(.holoToolText)

                Spacer()

                syncButton
            }
            .frame(height: 44)

            HealthDateNavigator(selectedDate: $selectedDate)
        }
        .padding(.top, HoloSpacing.sm)
        .padding(.bottom, HoloSpacing.sm)
        // 与下方卡片统一左右留白，避免返回/同步按钮贴屏幕边缘
        .padding(.horizontal, HoloSpacing.page)
    }

    /// 同步按钮：中性色 44pt 圆钮（与返回钮同款底），刷新时图标旋转。
    /// 主色橙只留给「今天」芯片，不再同时承担同步/步数多个语义。
    private var syncButton: some View {
        Button {
            Task {
                await runRefresh()
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isRefreshing ? Color.holoToolTextSecondary : Color.holoToolText)
                .rotationEffect(.degrees(animateSync ? 360 : 0))
                .animation(animateSync ? HoloAnimation.loadingRotation : nil, value: animateSync)
                .frame(width: 44, height: 44)
                .background(Color.holoToolSurface, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .disabled(isRefreshing)
        .accessibilityLabel(Text(isRefreshing ? "同步中" : "同步健康数据"))
        .accessibilityIdentifier("health.sync")
    }

    /// 今天卡（方案 A）：三环 + 判词 + 四项数值合一，一张卡回答「这一天怎么样、差在哪」。
    /// 取代原「三环卡 + 四宫格」：同一组进度不再画两遍，近 7 天趋势得以进首屏。
    private var todayCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: HoloSpacing.md) {
                TripleHealthRingView(snapshot: snapshot)

                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.statusTitle)
                        .holoText(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    // 判词按句分行（达标一句、差距一句）：整段自动换行会把「睡眠」拆到两行
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.verdictClauses.enumerated()), id: \.offset) { _, clause in
                            Text(clause)
                                .holoText(.supporting)
                                .foregroundColor(.holoToolTextSecondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let badge = snapshot.scoringBadgeText {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))

                            Text(badge)
                        }
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(.holoToolTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.holoToolInset)
                        .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(HoloSpacing.md)
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(Color.holoToolBorder)
                .frame(height: 0.5)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0)
                ],
                spacing: 0
            ) {
                ForEach(Array(snapshot.metrics.enumerated()), id: \.element.id) { index, metric in
                    metricCell(metric, showsTrailingDivider: index % 2 == 0, showsBottomDivider: index < 2)
                }
            }
        }
        .holoSurface()
    }

    /// 今天卡四格：整格可点进对应指标详情，右上徽章说达标/差距/缺数据
    private func metricCell(
        _ metric: HealthMetricSnapshot,
        showsTrailingDivider: Bool,
        showsBottomDivider: Bool
    ) -> some View {
        Button {
            guard !daySwipeState.isSwiping else { return }
            selectedMetric = metric.type
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: metric.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(metric.type.color)

                    Text(metric.title)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)

                    Spacer(minLength: 4)

                    metricBadge(metric)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(metric.valueText)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.holoToolText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if metric.availability == .available {
                        Text(metric.type.unit)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoToolTextSecondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoloPressStyle())
        .overlay(alignment: .trailing) {
            if showsTrailingDivider {
                Rectangle()
                    .fill(Color.holoToolBorder)
                    .frame(width: 0.5)
                    .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Rectangle()
                    .fill(Color.holoToolBorder)
                    .frame(height: 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(metric.title))
        .accessibilityValue(Text(metricCellAccessibilityValue(metric)))
    }

    /// 格内徽章：达标 / 差多少 / 缺数据原因（不再显示无解释的「--」）
    private func metricBadge(_ metric: HealthMetricSnapshot) -> some View {
        let (text, color): (String, Color) = {
            if metric.isGoalMet {
                return (String(localized: "达标"), Color.holoToolSuccess)
            }
            if let gap = metric.gapText {
                return (String(localized: "差 \(gap)"), Color.holoToolWarning)
            }
            return (metric.statusText, Color.holoToolTextSecondary)
        }()
        return Text(text)
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func metricCellAccessibilityValue(_ metric: HealthMetricSnapshot) -> String {
        var parts = [metric.valueText]
        if metric.availability == .available {
            parts.append(metric.type.unit)
        }
        if metric.isGoalMet {
            parts.append(String(localized: "达标"))
        } else if let gap = metric.gapText {
            parts.append(String(localized: "差 \(gap)"))
        } else {
            parts.append(metric.statusText)
        }
        return parts.joined(separator: " ")
    }

    /// 身体状态窄入口：与今天卡共用表面样式，标题与卡片标题同级。
    private var vitalsEntry: some View {
        Button {
            guard !daySwipeState.isSwiping else { return }
            showVitals = true
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoToolAction)
                    .frame(width: 34, height: 34)
                    .background(Color.holoToolInset)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                VStack(alignment: .leading, spacing: 2) {
                    Text("身体状态")
                        .holoText(.supporting)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoToolText)
                    Text("静息心率 · HRV · 呼吸频率")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("近 30 天")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoToolTextSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 11)
            .holoSurface()
        }
        .buttonStyle(.plain)
    }

    private var dataSourceCard: some View {
        HStack(spacing: HoloSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoToolText)
                    .frame(width: 42, height: 42)

                Image(systemName: "apple.logo")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.holoToolSurface)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(repository.dataSourceState.title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)

                Text(repository.dataSourceState.subtitle)
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }

            Spacer()

            Text(repository.dataSourceState.badgeText)
                .holoText(.metadata)
                .foregroundColor(repository.dataSourceState.badgeColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(repository.dataSourceState.badgeColor.opacity(0.12))
                .clipShape(Capsule())

            // 部分连接时提示可点击进入系统设置补权限
            if repository.dataSourceState == .partiallyConnected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
        .contentShape(Rectangle())
        .onTapGesture {
            // 部分连接时点按跳转系统设置，引导用户补全健康权限
            guard !daySwipeState.isSwiping, repository.dataSourceState == .partiallyConnected else { return }
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            #else
            if let url = URL(string: "x-apple.systempreferences:com.apple.Health") {
                NSWorkspace.shared.open(url)
            }
            #endif
        }
    }

    /// 只展示真实 AI 洞察：本地兜底 core（fallback-core-* 前缀，含「数据正在积累」话术）
    /// 整卡不出现——数据齐全时兜底话与 94 分「状态很好」自相矛盾（11-10 诊断 P0）。
    private var generatedCoreInsight: GeneratedHealthInsight? {
        guard let core = insightViewModel.snapshot?.coreInsight,
              !HealthInsightFallbackBuilder.isFallbackCore(core) else { return nil }
        return core
    }

    private func coreInsightCard(_ insight: GeneratedHealthInsight) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            // 卡头：图标 + 标题 + 周期徽章；窄宽一行放不下时徽章降级第二行
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    coreInsightHeaderTitle
                    insightPeriodBadge
                }

                VStack(alignment: .leading, spacing: 4) {
                    coreInsightHeaderTitle
                    insightPeriodBadge
                }
            }

            Text(insight.title)
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundColor(.holoToolText)
                .fixedSize(horizontal: false, vertical: true)

            Text(insight.summary)
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if !insight.evidenceIds.isEmpty {
                Rectangle()
                    .fill(Color.holoToolBorder)
                    .frame(height: 0.5)
                    .padding(.top, 2)

                HStack(spacing: 4) {
                    Text("证据 · \(insight.evidenceIds.count) 条")
                        .holoText(.metadata)
                        .foregroundColor(.holoToolTextSecondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                }
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
        .contentShape(Rectangle())
        .onTapGesture {
            guard !daySwipeState.isSwiping else { return }
            selectedEvidenceInsight = insight
        }
    }

    /// 卡头标题（图标 + 「HOLO 洞察」），单行与徽章降级两行两种排布复用
    private var coreInsightHeaderTitle: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))

            Text("HOLO 洞察")
                .lineLimit(1)
        }
        .font(.system(.caption2, weight: .semibold))
        .foregroundColor(.holoToolAI)
    }

    /// 周期徽章：真实窗口「近 N 天 · 起日–止日」（连接符 en dash，中文两侧不空格）
    private var insightPeriodBadge: some View {
        Text(insightPeriodBadgeText)
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(Color.holoToolAI)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.holoToolAI.opacity(0.10))
            .clipShape(Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// 洞察周期徽章文案（卡头与证据弹层同源）：有快照 period 时显示真实窗口
    /// 「近 N 天 · 起日–止日」，无 period 时退回固定窗口「近 14 天」
    private var insightPeriodBadgeText: String {
        guard let period = insightViewModel.snapshot?.period else {
            return String(localized: "近 \(HealthThresholds.insightWindowDays) 天")
        }
        let crossYear = !Calendar.current.isDate(period.start, equalTo: period.end, toGranularity: .year)
        let startText = crossYear
            ? Self.insightBadgeCrossYearFormatter.string(from: period.start)
            : Self.insightBadgeDayFormatter.string(from: period.start)
        let endText = Self.insightBadgeDayFormatter.string(from: period.end)
        return String(localized: "近 \(period.days) 天 · \(startText)–\(endText)")
    }

    /// 「MMMd」按 App 语言取模板（照抄 HealthDateNavigator 的种子语言做法，不用 Locale.current；
    /// 简繁：11月10日；英文：Nov 10）
    private static let insightBadgeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = insightBadgeLocale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// 跨年时起始日带年份（2025年12月30日 / Dec 30, 2025）
    private static let insightBadgeCrossYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = insightBadgeLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    private static var insightBadgeLocale: Locale {
        switch SeedLanguage.current {
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .traditionalChinese: return Locale(identifier: "zh_TW")
        case .english: return Locale(identifier: "en_US")
        }
    }

    private var lifestyleInsightCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("生活闭环")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                    .layoutPriority(1)
                Spacer()
                Text("近 \(insightPeriodDays) 天 · \(lifestyleRows.count) 条关联")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if lifestyleRows.isEmpty {
                Text(lifestyleEmptyHint)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: HoloSpacing.md) {
                    ForEach(Array(lifestyleRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: HoloSpacing.sm) {
                            Image(systemName: row.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(row.color)
                                .frame(width: 28, height: 28)
                                .background(row.color.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundColor(.holoToolText)

                                Text(row.detail)
                                    .font(.holoTinyLabel)
                                    .foregroundColor(.holoToolTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .contentShapeIf(row.generated != nil, shape: Rectangle())
                        .onTapGestureIf(row.generated != nil) {
                            guard !daySwipeState.isSwiping, let generated = row.generated else { return }
                            selectedEvidenceInsight = generated
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    // MARK: - 洞察数据源（只认 LLM 生成结果；规则兜底文案不上界面）

    /// 洞察窗口天数：快照 period 的真实天数，无快照时退回固定窗口
    private var insightPeriodDays: Int {
        insightViewModel.snapshot?.period.days ?? HealthThresholds.insightWindowDays
    }

    private var lifestyleRows: [(icon: String, title: String, detail: String, color: Color, generated: GeneratedHealthInsight?)] {
        if let loops = insightViewModel.snapshot?.lifestyleLoops, !loops.isEmpty {
            return loops.map {
                (lifestyleIcon(for: $0.domain), $0.title, $0.summary, lifestyleColor(for: $0.domain), $0)
            }
        }
        // P4：无 LLM 跨域循环时不展示硬编码假洞察，返回空（卡片显示诚实占位）。
        return []
    }

    /// 生活闭环空态文案：按生成状态说实话——数据不足 / 分析失败 / 分析中 / 分析过但无关联。
    private var lifestyleEmptyHint: String {
        switch insightViewModel.snapshot?.status {
        case .insufficientData:
            return String(localized: "数据积累中。连续记录睡眠、运动、记账、待办，HOLO 会从中发现跨域规律。")
        case .fallback:
            return String(localized: "这次分析没有完成。")
        case .generating, .none:
            return String(localized: "HOLO 正在分析近 \(HealthThresholds.insightWindowDays) 天的记录。")
        case .disabled:
            return String(localized: "洞察生成暂不可用。")
        case .fresh, .cached:
            return String(localized: "这 14 天没有发现明显的跨域规律。继续记录，HOLO 会持续观察。")
        }
    }

    private func lifestyleIcon(for domain: HealthInsightDomain) -> String {
        switch domain {
        case .health: return "heart.fill"
        case .task: return "checklist"
        case .habit: return "repeat"
        case .finance: return "creditcard.fill"
        case .thought: return "lightbulb.fill"
        case .mixed: return "link"
        }
    }

    private func lifestyleColor(for domain: HealthInsightDomain) -> Color {
        switch domain {
        case .health: return .holoChart1
        case .task: return .holoPrimary
        case .habit: return .holoSuccess
        case .finance: return .holoChart8
        case .thought: return .holoChart7
        case .mixed: return .holoPurple
        }
    }

    /// 近 7 天趋势卡：指标切换用系统分段控件（§8.8 口径），卡头带「详情」入口
    private var weeklyTrendCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .center) {
                Text("近 7 天 · \(trendMetric.displayName)")
                    .holoText(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)

                Spacer()

                Button {
                    guard !daySwipeState.isSwiping else { return }
                    selectedMetric = trendMetric
                } label: {
                    HStack(spacing: 2) {
                        Text("详情")
                            .holoText(.metadata)
                            .foregroundColor(.holoToolTextSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoToolTextSecondary.opacity(0.5))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Picker("指标", selection: $trendMetric) {
                ForEach([HealthMetricType.sleep, .steps, .workout], id: \.self) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            HealthTrendChart(data: trendData, type: trendMetric, endingOn: selectedDate, showsTitle: false)
        }
        .padding(.top, 6)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.md)
        .holoSurface()
    }

    private var trendData: [DailyHealthData] {
        switch trendMetric {
        case .sleep: return weeklySleepData
        case .steps: return weeklyStepsData
        case .workout: return weeklyWorkoutData
        default: return weeklySleepData
        }
    }

    private var unavailableView: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: repository.dataSourceState == .denied ? "heart.slash.fill" : "iphone.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.holoToolTextSecondary.opacity(0.55))

            VStack(spacing: HoloSpacing.sm) {
                Text(repository.dataSourceState.title)
                    .holoText(.sectionTitle)
                    .foregroundColor(.holoToolText)

                Text(repository.dataSourceState.subtitle)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .multilineTextAlignment(.center)
            }

            if repository.dataSourceState == .denied {
                Button("打开系统设置") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Health") {
                        NSWorkspace.shared.open(url)
                    }
                    #endif
                }
                .holoText(.body)
                .foregroundColor(.holoPrimary)
            }
        }
        .padding(HoloSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.holoToolBackground)
    }

    private func requestPermission() {
        repository.requestAuthorization()
    }

    private func refreshAll() async {
        await repository.refresh()
        await loadDateData(for: selectedDate)
    }

    private func loadDateData(for date: Date) async {
        // R10（2026-10-04 体检）：日期作为请求身份——四路查询一律用捕获的日期，
        // 不在 await 后读变化中的 selectedDate；发布前核对代数，过期请求整体丢弃，
        // 不再出现「标题是新日期、数值来自旧日期」或「日数据与周数据来自不同日期」
        dateLoadGeneration += 1
        let generation = dateLoadGeneration
        let day = await repository.fetchDayData(for: date)
        let sleep = await repository.fetchChartWeeklyData(for: .sleep, endingOn: date)
        let steps = await repository.fetchChartWeeklyData(for: .steps, endingOn: date)
        let workout = await repository.fetchChartWeeklyData(for: .workout, endingOn: date)
        guard generation == dateLoadGeneration else { return }
        dayData = day
        weeklySleepData = sleep
        weeklyStepsData = steps
        weeklyWorkoutData = workout
    }

    /// 左右滑动切天：与日期胶囊共用同一条边界规则（不越过今天）
    private func switchDay(forward: Bool) {
        guard let newDate = HealthDateNavigator.steppedDate(from: selectedDate, forward: forward) else { return }
        // 内容方向性过渡：切到明天新内容从右缘进，切到昨天从左缘进（与滑动方向一致）
        dayContentEdge = forward ? .trailing : .leading
        withAnimation(HoloAnimation.standard) {
            selectedDate = newDate
        }
    }

    @MainActor
    private func runRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await refreshAll()
        isRefreshing = false
    }

}

#Preview {
    HealthView()
}
