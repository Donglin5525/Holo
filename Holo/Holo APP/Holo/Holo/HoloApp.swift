//
//  HoloApp.swift
//  Holo
//
//  应用入口 - Holo AI 个人助理
//

import SwiftUI
import BackgroundTasks

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

        // 注册后台洞察生成任务
        MemoryInsightBackgroundService.shared.registerBackgroundTask()

        // 触发 Core Data 异步加载（不阻塞主线程，避免首次创建 SQLite 时死锁）
        // store 加载在后台进行，UI 先以默认值渲染，加载完成后通过 await 切换
        CoreDataStack.shared.prepareIfNeeded()
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