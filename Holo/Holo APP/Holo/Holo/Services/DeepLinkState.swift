//
//  DeepLinkState.swift
//  Holo
//
//  Deep Link 状态管理
//  用于通知点击后的导航跳转
//

import Foundation
import Combine

/// Deep Link 跳转目标
/// 各模块通过匹配对应 case 决定是否响应跳转
enum DeepLinkTarget: Equatable {
    case taskDetail(taskId: UUID)
    case dailyReminder
    case habitDetail(habitId: UUID)
    /// 从 AI Chat 卡片跳转到对应模块
    case finance
    case tasks
    /// 从 AI Chat 洞察标签跳转到记忆长廊
    case memoryGallery
}

/// Deep Link 状态管理器
/// 管理通知点击后的待跳转目标，各层视图监听此状态实现自动导航
@MainActor
class DeepLinkState: ObservableObject {

    // MARK: - Singleton

    static let shared = DeepLinkState()

    // MARK: - Published Properties

    /// 待跳转的目标
    /// 设置后，HomeView 会自动打开对应模块，模块内部视图会自动弹出详情页
    @Published var pendingTarget: DeepLinkTarget?

    // MARK: - Initialization

    private init() {}
}
