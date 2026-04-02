//
//  DeepLinkState.swift
//  Holo
//
//  Deep Link 状态管理
//  用于通知点击后的导航跳转
//

import Foundation
import Combine

/// Deep Link 状态管理器
/// 管理通知点击后的待跳转目标，各层视图监听此状态实现自动导航
@MainActor
class DeepLinkState: ObservableObject {

    // MARK: - Singleton

    static let shared = DeepLinkState()

    // MARK: - Published Properties

    /// 待跳转的任务 ID
    /// 设置后，HomeView 会自动打开 TasksView，TaskListView 会自动弹出 TaskDetailView
    @Published var pendingTaskId: UUID?

    // MARK: - Initialization

    private init() {}
}
