//
//  ContentView.swift
//  Holo
//
//  主导航视图 - TabView 容器
//  管理 Today、HOLO、Finance、Health、Profile 五个主要页面
//

import SwiftUI

/// 主导航视图
/// 使用 TabView 管理应用的五个主要模块
struct ContentView: View {
    
    // MARK: - Properties
    
    /// 当前选中的 Tab
    @State private var selectedTab: Tab = .today
    
    /// Tab 枚举
    enum Tab: String, CaseIterable {
        case today = "今天"
        case holo = "对话"
        case finance = "财务"
        case health = "健康"
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
                PlaceholderView(title: "HOLO 对话", icon: "bubble.left.and.bubble.right.fill")
            case .finance:
                PlaceholderView(title: "财务管理", icon: "wallet.pass.fill")
            case .health:
                PlaceholderView(title: "健康记录", icon: "heart.fill")
            case .profile:
                PlaceholderView(title: "个人中心", icon: "person.fill")
            }
        }
    }
}

// MARK: - 占位视图

/// 占位视图 - 用于未完成的页面
struct PlaceholderView: View {
    let title: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoPrimary)
            
            Text(title)
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            
            Text("功能开发中...")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}