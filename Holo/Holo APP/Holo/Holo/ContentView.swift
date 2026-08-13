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
            
            // 根据选中的 Tab 显示对应页面
            switch selectedTab {
            case .today:
                HomeView()
            case .holo:
                NavigationStack {
                    ChatView(goalPlanningRequest: $pendingGoalPlanningRequest)
                        .navigationBarHidden(true)
                }
            case .profile:
                PersonalView(onPlanGoal: {
                    pendingGoalPlanningRequest = GoalPlanningRequest(seedText: nil)
                    selectedTab = .holo
                }, pendingGoalDetailId: $pendingGoalDetailId)
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
