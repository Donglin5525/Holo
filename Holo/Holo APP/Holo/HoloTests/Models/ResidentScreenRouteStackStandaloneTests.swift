import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ResidentScreenRouteStackStandaloneTests.main()
    }
}
#endif
/// 常驻模块导航栈契约（挂载集合 + 导航历史双概念）：
/// 模块挂载后不销毁（跨侧边栏切换保状态、重入零重建），
/// 历史（current / 返回顺序）沿用销毁式时代的链路语义。
struct ResidentScreenRouteStackStandaloneTests {
    static func main() {
        var stack = ResidentScreenRouteStack()

        stack.openRoot(.ai)
        expect(stack.routes.map(\.screen) == [.ai], "首页入口应建立根模块")
        expect(stack.current == .ai, "根模块应为当前可见")

        stack.navigate(to: .finance)
        expect(stack.routes.map(\.screen) == [.ai, .finance], "跨模块跳转应保留来源")
        expect(stack.current == .finance, "跳转目标应为当前可见")

        _ = stack.dismissCurrent()
        expect(stack.current == .ai, "返回应回到来源模块")
        expect(stack.routes.map(\.screen) == [.ai, .finance], "关闭的模块应保持常驻挂载")

        stack.navigate(to: .memoryGallery)
        stack.navigate(to: .finance)
        stack.navigate(to: .ai)
        expect(stack.current == .ai, "返回既有模块时应弹回而不是重复创建")
        expect(stack.routes.map(\.screen) == [.ai, .finance, .memoryGallery], "弹回链路不新增挂载")

        let aiRouteId = stack.routes.first { $0.screen == .ai }?.id
        stack.openRoot(.habits)
        expect(stack.current == .habits, "首页新入口应清空旧链路，指向新根模块")
        expect(stack.routes.map(\.screen) == [.ai, .finance, .memoryGallery, .habits], "首页新入口保留已挂载模块")
        expect(stack.routes.first { $0.screen == .ai }?.id == aiRouteId, "挂载路由 ID 稳定，视图身份不复重建")

        stack.openRoot(.habits)
        expect(stack.current == .habits, "重复入口同一模块不重建")
        expect(stack.routes.filter { $0.screen == .habits }.count == 1, "同一模块至多一条挂载路由")

        _ = stack.dismissCurrent()
        expect(stack.current == nil, "根模块返回后应回到首页")
        expect(stack.routes.map(\.screen).contains(.habits), "回首页后模块保持常驻（隐藏不销毁）")

        // 首页直接入栈新模块：模块间深链目标已挂载时只入历史、不重建视图
        stack.navigate(to: .finance)
        expect(stack.current == .finance, "已挂载模块直跳应直接可见")
        expect(stack.routes.count == 4, "已挂载模块直跳不新增挂载")

        stack.dismissAll()
        expect(stack.current == nil, "清空历史应回到首页")
        expect(stack.routes.count == 4, "清空历史不清挂载（模块常驻）")

        print("ResidentScreenRouteStackStandaloneTests passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError(message)
        }
    }
}
