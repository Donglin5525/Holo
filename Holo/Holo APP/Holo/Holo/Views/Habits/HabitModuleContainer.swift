//
//  HabitModuleContainer.swift
//  Holo
//
//  习惯模块根容器（V2 §4）：今天 / 回顾两页签；右上角更多承载低频选项。
//  回顾路由（整体 ↔ 单习惯）与模块级月份、弹层集中在根容器；
//  整体页在单习惯页期间常驻底层，返回时月份与滚动位置自然保留。
//

import SwiftUI

struct HabitModuleContainer: View {

    @Environment(\.dismiss) var dismiss
    @Environment(\.holoDismiss) private var holoDismiss
    @Environment(\.holoContentWidth) private var holoContentWidth
    private var isExpandedWidth: Bool {
        HoloAdaptiveLayout.isExpandedWidth(holoContentWidth)
    }
    private var close: () -> Void { holoDismiss ?? { dismiss() } }

    @StateObject private var model = HabitModuleViewModel()
    @ObservedObject private var deepLinkState = DeepLinkState.shared
    @ObservedObject private var retroOpener = PendingRetroactiveOpener.shared
    @Namespace private var tabNamespace

    // MARK: 弹层状态（一次一个 sheet；跨层交接用待办，不靠 Bool 竞争）

    /// 新增习惯（nil = 关闭）
    @State private var addHabitDraft: HabitPrefillDraft? = nil
    /// 编辑目标（习惯设置）
    @State private var editTarget: Habit? = nil
    /// 「今天的记录」弹层目标
    @State private var todayRecordTarget: UUID? = nil
    /// 更多选项弹层
    @State private var showOptionsSheet = false
    /// 更多弹层打开后直接进入的二级页（今天页「已暂停 N 项」→ 名单）
    @State private var optionsInitialPage: HabitModuleOptionsSheetInitial? = nil
    /// 补签弹层目标
    @State private var retroactiveTarget: HabitRetroactiveSheetContext? = nil
    /// 「去今天记录」定位（回今天后滚动到该习惯）
    @State private var focusHabitId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch model.selectedTab {
                case .today:
                    HabitTodayView(
                        model: model,
                        onOpenAddHabit: { addHabitDraft = HabitPrefillDraft() },
                        onOpenTodayRecords: { todayRecordTarget = $0 },
                        onOpenLifecycleList: {
                            optionsInitialPage = .lifecycle
                            showOptionsSheet = true
                        },
                        focusHabitId: focusHabitId,
                        onFocusConsumed: { focusHabitId = nil }
                    )
                case .review:
                    reviewStack
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 单习惯回顾页是 ZStack 覆盖层（无 NavigationStack 可让位），容器手势必须在
        // 该页期间整层失效穿透，由单习惯页自己的右滑手势接管「返回回顾整体」——
        // 否则让位判断找不到导航栈恒失效，子页右滑会把整个模块滑出去直达首页
        .swipeBackToDismiss(isEnabled: !isSingleReviewShown, isResidentScreenRoot: true) { close() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isExpandedWidth, !isSingleReviewShown {
                tabBar
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isExpandedWidth, !isSingleReviewShown {
                topTabBar
            }
        }
        // 每个节点只挂一个 sheet（同一节点双 sheet 会互相吞掉）
        .sheet(item: $addHabitDraft) { draft in
            AddHabitSheet(prefill: draft)
        }
        .sheet(item: $editTarget) { habit in
            AddHabitSheet(editingHabit: habit)
        }
        .sheet(item: todayRecordItemBinding) { item in
            HabitTodayRecordSheet(
                habitId: item.id,
                model: model,
                onOpenSettings: { id in
                    // 明确路由交接：先收弹层，再开编辑（§9）
                    todayRecordTarget = nil
                    openSettingsAfterSheetDismiss(id)
                }
            )
        }
        .sheet(isPresented: $showOptionsSheet, onDismiss: { optionsInitialPage = nil }) {
            HabitModuleOptionsSheet(
                model: model,
                initialPage: optionsInitialPage,
                onOpenSingleReview: { id in
                    // 名单点名称：关弹层 → 单习惯回顾（默认继承当前月份）
                    showOptionsSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        model.reviewRoute = .single(id)
                    }
                },
                onOpenSettings: { id in
                    showOptionsSheet = false
                    openSettingsAfterSheetDismiss(id)
                }
            )
        }
        .sheet(item: $retroactiveTarget) { context in
            HabitRetroactiveSheet(context: context)
        }
        .onAppear {
            model.warmUp()
            handleDeepLink(deepLinkState.pendingTarget)
        }
        .onChange(of: deepLinkState.pendingTarget) { _, target in
            handleDeepLink(target)
        }
        .onChange(of: retroOpener.habitId) { _, habitId in
            guard let habitId else { return }
            if let habit = HabitRepository.shared.findHabit(by: habitId) {
                retroactiveTarget = HabitRetroactiveSheetContext(habit: habit, preselectedDay: nil, mode: .sign)
            }
            retroOpener.habitId = nil
        }
        .onChange(of: model.reviewRoute) { _, route in
            // 习惯对象失效（删除/归档后离开页面）时收回整体
            if case .single(let id) = route,
               HabitRepository.shared.findHabit(by: id) == nil {
                model.reviewRoute = .overview
            }
        }
    }

    // MARK: 回顾栈（整体常驻底层；单习惯覆盖，返回保留月份与滚动位置）

    private var isSingleReviewShown: Bool {
        if case .single = model.reviewRoute { return true }
        return false
    }

    private var reviewStack: some View {
        ZStack {
            HabitReviewView(model: model) { id in
                model.reviewRoute = .single(id)
            }
            .allowsHitTesting(!isSingleReviewShown)
            .opacity(isSingleReviewShown ? 0 : 1)

            if case .single(let id) = model.reviewRoute {
                HabitSingleReviewView(
                    habitId: id,
                    model: model,
                    onOpenSettings: { settingsId in
                        openSettingsAfterSheetDismiss(settingsId)
                    },
                    onGoTodayRecord: { targetId in
                        focusHabitId = targetId
                        model.reviewRoute = .overview
                        model.selectedTab = .today
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.reviewRoute)
    }

    // MARK: 头部（按当前页面切换标题与动作）

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if isSingleReviewShown {
                    Button {
                        model.reviewRoute = .overview
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoToolText)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityIdentifier("habit.single.back")
                    .accessibilityLabel(Text(String(localized: "返回回顾整体")))
                } else {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoToolText)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityIdentifier("habit.back")
                }

                Spacer()

                if isSingleReviewShown {
                    Button {
                        if case .single(let id) = model.reviewRoute {
                            openSettingsAfterSheetDismiss(id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoToolText)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text(String(localized: "习惯设置")))
                } else if model.selectedTab == .today {
                    Button {
                        addHabitDraft = HabitPrefillDraft()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.holoToolAction))
                    }
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("habit.add")
                    .accessibilityLabel(Text(String(localized: "新增习惯")))

                    moreButton
                } else {
                    // 回顾页没有新增/打卡主动作（V2 §4）
                    moreButton
                }
            }

            Text(headerTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.holoToolText)
                .accessibilityIdentifier("habit.title")
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, -6)
        .padding(.bottom, HoloSpacing.xs)
        .background(Color.holoToolBackground)
    }

    private var headerTitle: String {
        if isSingleReviewShown { return String(localized: "习惯回顾") }
        return model.selectedTab == .today ? String(localized: "习惯") : String(localized: "回顾")
    }

    private var moreButton: some View {
        Button {
            optionsInitialPage = nil
            showOptionsSheet = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.holoToolText)
                .frame(width: 44, height: 44)
        }
        .accessibilityIdentifier("habit.more")
        .accessibilityLabel(Text(String(localized: "更多选项")))
    }

    // MARK: 底部导航

    private var tabBar: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 20)
            HStack(spacing: 0) {
                ForEach(HabitModuleViewModel.Tab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, bottomInset)
            .background(
                Color.holoToolSurface
                    .shadow(color: HoloShadow.card, radius: 10, x: 0, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        .frame(height: 88)
        .frame(maxWidth: .infinity)
        .background(Color.holoToolSurface.ignoresSafeArea(edges: .bottom))
        .zIndex(40)
    }

    private var topTabBar: some View {
        HStack(spacing: 8) {
            ForEach(HabitModuleViewModel.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(HoloAnimation.quick) { model.selectedTab = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(tab.displayName)
                            .font(.system(size: 13, weight: model.selectedTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        if model.selectedTab == tab {
                            Capsule().fill(Color.holoPrimary.opacity(0.15))
                                .matchedGeometryEffect(id: "habitV2TabCapsule", in: tabNamespace)
                        } else {
                            Capsule().fill(Color.holoToolSurface)
                        }
                    }
                    .foregroundColor(model.selectedTab == tab ? .holoPrimary : .holoToolTextSecondary)
                }
                .buttonStyle(PlainButtonStyle())
                .holoHover()
            }
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolBackground)
    }

    private func tabButton(_ tab: HabitModuleViewModel.Tab) -> some View {
        Button {
            withAnimation(HoloAnimation.quick) { model.selectedTab = tab }
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(model.selectedTab == tab ? Color.holoPrimary : Color.clear)
                    .frame(width: 4, height: 4)
                Image(systemName: tab.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(model.selectedTab == tab ? .holoPrimary : .holoToolTextSecondary)
                Text(tab.displayName)
                    .font(.holoTinyLabel)
                    .foregroundColor(model.selectedTab == tab ? .holoPrimary : .holoToolTextSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("habit.tab.\(tab.rawValue)")
    }

    // MARK: 弹层交接

    private var todayRecordItemBinding: Binding<TodayRecordItem?> {
        Binding(
            get: { todayRecordTarget.map(TodayRecordItem.init) },
            set: { todayRecordTarget = $0?.id }
        )
    }

    private struct TodayRecordItem: Identifiable {
        let id: UUID
    }

    /// 等当前 sheet 收起后再开习惯设置（同一节点不竞争双 sheet）
    private func openSettingsAfterSheetDismiss(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            editTarget = HabitRepository.shared.findHabit(by: id)
        }
    }

    // MARK: 深链（§9：habitDetail 统一进单习惯回顾，根页选回顾）

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        guard case .habitDetail(let habitId) = target else { return }
        let exists = HabitRepository.shared.findHabit(by: habitId) != nil
        model.selectedTab = .review
        model.reviewRoute = exists ? .single(habitId) : .overview
        deepLinkState.pendingTarget = nil
    }
}
