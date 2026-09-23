//
//  ContentView.swift
//  Holo
//
//  主导航视图
//  iPhone（compact）：三主 tab（今天/对话/我的）
//  iPad（regular）：v2 侧边栏骨架 + HomeView 宿主（docs/ipad-adaptation/v2-plan.md 阶段 2）
//

import SwiftUI

/// 主导航视图
struct ContentView: View {

    // MARK: - Properties

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 当前选中的 Tab（iPhone 路径；iPad 骨架下固定 .today、由侧边栏驱动）
    @State private var selectedTab: Tab = .today

    /// iPad 侧边栏选中态
    @State private var sidebarSelection: HoloSidebarDestination = .today

    /// iPad 侧边栏形态：用户手动收起/展开后的选择；nil = 未干预，跟随窗口自动策略
    /// （扣 232 后主内容 ≥600 常驻，否则窄条）。旋转/分屏时未干预则自动重估，
    /// 干预过则尊重用户选择——侧边栏形态变化不清空任何业务状态。
    @State private var manualSidebarVisibility: HoloLayoutPolicy.SidebarVisibility?

    @State private var pendingGoalPlanningRequest: GoalPlanningRequest?
    @State private var pendingGoalDetailId: UUID?
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    /// Tab 枚举（iPhone）
    enum Tab: String, CaseIterable {
        case today = "今天"
        case holo = "对话"
        case profile = "我的"
    }

    /// iPad v2 骨架：regular 宽度（iPad 全屏恒为 regular）显示侧边栏
    private var useIPadSidebar: Bool {
        HoloAdaptiveLayout.isRegularWidth(horizontalSizeClass)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 背景色
                Color.holoBackground
                    .ignoresSafeArea()

                if useIPadSidebar {
                    iPadSidebarShell(windowWidth: geo.size.width)
                } else {
                    iPhoneTabs
                }
            }
            .environment(\.holoWindowWidth, geo.size.width)
        }
        .onChange(of: deepLinkState.pendingTarget) { _, target in
            handleDeepLink(target)
        }
        .onAppear {
            handleDeepLink(deepLinkState.pendingTarget)
        }
        // Cmd+1…9 模块直跳：iPad → 侧边栏；iPhone → 映射回主 tab（老习惯不变）
        .onReceive(HoloShortcutBus.shared.$lastEvent) { event in
            guard let event, case .goToSidebar(let dest) = event.action else { return }
            if useIPadSidebar {
                sidebarSelection = dest
            } else {
                switch dest {
                case .today: selectedTab = .today
                case .ai: selectedTab = .holo
                case .profile: selectedTab = .profile
                default: break
                }
            }
        }
    }

    // MARK: - iPad 侧边栏骨架

    /// 左侧边栏（常驻/窄条两态）+ 右侧宿主。宿主是 HomeView：首页内容、七个常驻模块、
    /// 设置/个人页面层都由它承载（常驻栈机制不变，保滚动位置与聊天状态）。
    /// 宿主区注入 `holoContentWidth`（业务模块唯一合法的宽度事实源）。
    private func iPadSidebarShell(windowWidth: CGFloat) -> some View {
        let autoVisibility: HoloLayoutPolicy.SidebarVisibility =
            HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: windowWidth) ? .persistent : .rail
        let visibility = manualSidebarVisibility ?? autoVisibility

        return HStack(spacing: 0) {
            HoloSidebarView(
                selection: $sidebarSelection,
                visibility: visibility,
                onToggleVisibility: { target in
                    withAnimation(.easeInOut(duration: 0.22)) {
                        manualSidebarVisibility = target
                    }
                },
                onQuickCapture: {
                    HoloShortcutBus.shared.post(.newItemAtCurrentModule)
                }
            )

            Rectangle()
                .fill(Color.holoBorder.opacity(0.5))
                .frame(width: 0.5)

            GeometryReader { hostGeo in
                ZStack {
                    Color.holoBackground
                        .ignoresSafeArea()

                    HomeView(sidebarSelection: $sidebarSelection)
                }
                .environment(
                    \.holoContentWidth,
                    HoloLayoutPolicy.contentWidth(windowWidth: windowWidth, sidebar: visibility)
                )
                // GeometryReader 的尺寸读数已扣除侧边栏与分隔线；宿主内容布局
                // 与手算值恒等，直接用 policy 口径注入保证与单测同一公式。
                .environment(\.holoWindowWidth, hostGeo.size.width)
            }
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - iPhone 三 Tab（现状不动）

    private var iPhoneTabs: some View {
        ZStack {
            // 硬件键盘 Cmd 快捷键兼容层：仅 iPhone 挂载（iPad 走系统菜单栏命令，
            // 两套并存会双触发）。label 会出现在长按 Cmd 的提示浮层里，须写清动作。
            Group {
                Button("前往今天") { selectedTab = .today }
                    .keyboardShortcut("1", modifiers: .command)
                Button("前往对话") { selectedTab = .holo }
                    .keyboardShortcut("2", modifiers: .command)
                Button("前往我的") { selectedTab = .profile }
                    .keyboardShortcut("3", modifiers: .command)
                Button("打开设置") { HoloShortcutBus.shared.post(.openSettings) }
                    .keyboardShortcut(",", modifiers: .command)
                Button("新建") { HoloShortcutBus.shared.post(.newItemAtCurrentModule) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("关闭当前模块") { HoloShortcutBus.shared.post(.closeCurrentModule) }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            // 根据选中的 Tab 显示对应页面
            // iPad（regular 宽度）统一限宽居中，覆盖首页与七个常驻模块；
            // iPhone（compact）行为与不包裹完全一致
            switch selectedTab {
            case .today:
                HomeView()
                    .holoContentColumn()
            case .holo:
                NavigationStack {
                    ChatView(goalPlanningRequest: $pendingGoalPlanningRequest)
                        .navigationBarHidden(true)
                }
                .holoContentColumn()
            case .profile:
                PersonalView(onPlanGoal: {
                    pendingGoalPlanningRequest = GoalPlanningRequest(seedText: nil)
                    selectedTab = .holo
                }, pendingGoalDetailId: $pendingGoalDetailId)
                    .holoContentColumn()
            }
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        guard let target else { return }
        switch target {
        case .goalDetail(let goalId):
            pendingGoalDetailId = goalId
            if useIPadSidebar {
                // iPad：个人是侧边栏目的地，HomeView 页面层持有自己的 pendingGoalDetailId，
                // 这里只负责把侧边栏切过去
                sidebarSelection = .profile
            } else {
                selectedTab = .profile
            }
            deepLinkState.pendingTarget = nil
        default:
            // 其余目标（小组件/通知/内部跳转）全部由 HomeView 的常驻模块栈消费：
            // 先把宿主切回「今天」，HomeView 重建后 onAppear/onChange 领取 pendingTarget
            // 落到对应模块。用户停在「对话/我的」时 HomeView 已被卸载，缺这道分发
            // 跳转目标会滞留，App 停在原界面。pendingTarget 由 HomeView 消费后自清。
            if useIPadSidebar {
                sidebarSelection = .today
            } else {
                selectedTab = .today
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
