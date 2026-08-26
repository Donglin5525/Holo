//
//  ContentView.swift
//  Holo
//
//  主导航视图 - TabView 容器
//  管理 Today、HOLO、Profile 三个主要页面
//

import SwiftUI

/// 主导航视图
/// 使用 TabView 管理应用的五个主要模块
struct ContentView: View {
    
    // MARK: - Properties
    
    /// 当前选中的 Tab
    @State private var selectedTab: Tab = .today
    @State private var pendingGoalPlanningRequest: GoalPlanningRequest?
    @State private var pendingGoalDetailId: UUID?
    @ObservedObject private var deepLinkState = DeepLinkState.shared
    
    /// Tab 枚举
    enum Tab: String, CaseIterable {
        case today = "今天"
        case holo = "对话"
        case profile = "我的"
    }
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            // 背景色
            Color.holoBackground
                .ignoresSafeArea()

            // 硬件键盘 Cmd 快捷键（iPad 适配 D3）：透明按钮常驻视图树。
            // label 会出现在 iPad 长按 Cmd 的快捷键提示浮层里，须写清动作。
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
        .onChange(of: deepLinkState.pendingTarget) { _, target in
            handleDeepLink(target)
        }
        .onAppear {
            handleDeepLink(deepLinkState.pendingTarget)
        }
    }

    private func handleDeepLink(_ target: DeepLinkTarget?) {
        guard let target else { return }
        switch target {
        case .goalDetail(let goalId):
            pendingGoalDetailId = goalId
            selectedTab = .profile
            deepLinkState.pendingTarget = nil
        default:
            break
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
