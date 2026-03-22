//
//  HoloApp.swift
//  Holo
//
//  应用入口 - Holo AI 个人助理
//

import SwiftUI

/// Holo 应用入口
/// 一款"个人数据资产 + AI 规划"一体化的个人 AI 助理
@main
struct HoloApp: App {

    // MARK: - Observed Objects

    /// 深色模式管理器
    @StateObject private var darkModeManager = DarkModeManager.shared

    // MARK: - Initialization

    init() {
        // 设置通知代理和注册分类
        Task { @MainActor in
            TodoNotificationService.shared.setupDelegate()
            TodoNotificationService.shared.registerNotificationCategories()
        }
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(darkModeManager.colorScheme)
                .task {
                    // 检查通知权限状态
                    TodoNotificationService.shared.checkAuthorizationStatus()
                }
        }
    }
}