//
//  ResidentScreenRouteStack.swift
//  Holo
//
//  首页常驻模块的统一导航栈。
//

import Foundation

/// HomeView 可以承载的全屏模块。
enum ActiveScreen: String, Identifiable, CaseIterable {
    case ai, finance, habits, tasks, memoryGallery, health, thoughts

    var id: String { rawValue }
}

/// 单个常驻模块路由。独立 ID 让同一模块也可以出现在不同导航层级中。
struct ResidentScreenRoute: Identifiable, Equatable {
    let id: UUID
    let screen: ActiveScreen

    init(id: UUID = UUID(), screen: ActiveScreen) {
        self.id = id
        self.screen = screen
    }
}

/// 保留来源页面的轻量导航栈。
///
/// - 首页直接入口使用 `openRoot`，建立新的根模块。
/// - 模块间跳转使用 `navigate`，来源页面留在栈内。
/// - 如果目标已在栈中，回退到既有页面，避免重复创建同一模块。
struct ResidentScreenRouteStack: Equatable {
    private(set) var routes: [ResidentScreenRoute] = []

    var current: ActiveScreen? {
        routes.last?.screen
    }

    mutating func openRoot(_ screen: ActiveScreen) {
        guard routes.count != 1 || current != screen else { return }
        routes = [ResidentScreenRoute(screen: screen)]
    }

    mutating func navigate(to screen: ActiveScreen) {
        guard current != screen else { return }

        if let existingIndex = routes.lastIndex(where: { $0.screen == screen }) {
            routes.removeSubrange(routes.index(after: existingIndex)..<routes.endIndex)
        } else {
            routes.append(ResidentScreenRoute(screen: screen))
        }
    }

    @discardableResult
    mutating func dismissCurrent() -> ActiveScreen? {
        guard !routes.isEmpty else { return nil }
        routes.removeLast()
        return current
    }
}
