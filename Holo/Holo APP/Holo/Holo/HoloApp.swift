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
        // 同步设置通知代理，确保冷启动时 didReceive 不被错过
        TodoNotificationService.shared.setupDelegate()
        TodoNotificationService.shared.registerNotificationCategories()

        // 后台预加载 Core Data（避免首次导航到 Chat 时阻塞主线程）
        // CoreDataStack 使用 NSLock 保护，可安全从后台线程初始化
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CoreDataStack.shared.persistentContainer
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