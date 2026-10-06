//
//  HabitModuleContainer.swift
//  Holo
//
//  新交互（2026-10 重构）模块根容器：今天 / 回顾 / 管理三页签。
//  回顾页暂接旧统计页（G4 替换为新回顾页）；详情/编辑/补签弹层集中在此挂载。
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
    @StateObject private var statsState = HabitStatsState()
    @ObservedObject private var deepLinkState = DeepLinkState.shared
    @ObservedObject private var retroOpener = PendingRetroactiveOpener.shared
    @Namespace private var tabNamespace

    /// 新增习惯（nil = 关闭）
    @State private var addHabitDraft: HabitPrefillDraft? = nil
    /// 编辑目标
    @State private var editTarget: Habit? = nil
    /// 详情弹层（仅持 id；关闭动画不触碰 Core Data 对象）
    @State private var detailSelection: DetailSelection? = nil
    /// 详情删除/归档的待执行操作
    @State private var pendingAction: PendingHabitAction? = nil
    /// 补签弹层目标
    @State private var retroactiveTarget: HabitRetroactiveSheetContext? = nil
    /// 月度概览（旧统计页全量统计能力）
    @State private var showMonthlyOverview = false
    /// 管理页进入时强制选中的分组（从今天页「暂停管理」来 = 已暂停）
    @State private var manageSectionOverride = false

    private struct DetailSelection: Identifiable {
        let id: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch model.selectedTab {
                case .today:
                    HabitTodayView(
                        model: model,
                        onOpenDetail: { openDetail($0) },
                        onOpenAddHabit: { addHabitDraft = HabitPrefillDraft() },
                        onOpenPausedManagement: {
                            manageSectionOverride = true
                            model.selectedTab = .manage
                        }
                    )
                case .review:
                    HabitReviewView(
                        model: model,
                        onOpenMonthlyOverview: {
                            showMonthlyOverview = true
                        },
                        onOpenDetail: { openDetail($0) }
                    )
                case .manage:
                    HabitManagementView(
                        model: model,
                        initialSection: manageSectionOverride ? .manage : nil,
                        onOpenDetail: { openDetail($0) },
                        onEditHabit: { editTarget = $0 },
                        onOpenStatsSettings: {
                            // 旧设置页承载回顾展示设置（回到管理页）
                            model.selectedTab = .review
                        },
                        onOpenStats: {
                            showMonthlyOverview = true
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .swipeBackToDismiss(isResidentScreenRoot: true) { close() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isExpandedWidth {
                tabBar
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isExpandedWidth {
                topTabBar
            }
        }
        // 每个节点只挂一个 sheet（同一节点双 sheet 会互相吞掉）
        .sheet(item: $addHabitDraft) { draft in
            AddHabitSheet(prefill: draft)
        }
        .sheet(item: $detailSelection, onDismiss: {
            executePendingAction()
        }) { selection in
            if let habit = HabitRepository.shared.findHabit(by: selection.id) {
                HabitDetailView(habit: habit, onWillDelete: { action in
                    pendingAction = action
                    detailSelection = nil
                })
            } else {
                // 已软删/物理删除：明确说明并返回，不重建占位数据（方案 §3）
                VStack(spacing: HoloSpacing.md) {
                    Text(String(localized: "这个习惯已不可用"))
                        .holoText(.body)
                        .foregroundColor(.holoToolTextSecondary)
                    Button(String(localized: "返回")) { detailSelection = nil }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .presentationDetents([.height(220)])
            }
        }
        .sheet(item: $editTarget) { habit in
            AddHabitSheet(editingHabit: habit)
        }
        .sheet(item: $retroactiveTarget) { context in
            HabitRetroactiveSheet(context: context)
        }
        .sheet(isPresented: $showMonthlyOverview) {
            NavigationStack {
                HabitStatsView(onBack: { showMonthlyOverview = false }, state: statsState)
            }
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
    }

    // MARK: 头部（返回 / 标题 / 新增）

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.holoToolText)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("habit.back")

                Spacer()

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
            }

            Text(String(localized: "习惯"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.holoToolText)
                .padding(.top, 0)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, -6)
        .padding(.bottom, HoloSpacing.xs)
        .background(Color.holoToolBackground)
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
                                .matchedGeometryEffect(id: "habitV1TabCapsule", in: tabNamespace)
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

    // MARK: 导航与弹层

    private func openDetail(_ id: UUID) {
        detailSelection = DetailSelection(id: id)
    }

    private func executePendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task { @MainActor in
                switch action {
                case .delete(let id): try? HabitRepository.shared.deleteHabitById(id)
                case .archive(let id): try? HabitRepository.shared.archiveHabitById(id)
                }
            }
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        guard case .habitDetail(let habitId) = target else { return }
        model.selectedTab = .today
        openDetail(habitId)
        deepLinkState.pendingTarget = nil
    }
}
