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

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(darkModeManager.colorScheme)
        }
    }
}