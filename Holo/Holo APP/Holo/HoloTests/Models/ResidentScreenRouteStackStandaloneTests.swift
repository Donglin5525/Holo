import Foundation

@main
struct ResidentScreenRouteStackStandaloneTests {
    static func main() {
        var stack = ResidentScreenRouteStack()

        stack.openRoot(.ai)
        expect(stack.routes.map(\.screen) == [.ai], "首页入口应建立根模块")

        stack.navigate(to: .finance)
        expect(stack.routes.map(\.screen) == [.ai, .finance], "跨模块跳转应保留来源")

        _ = stack.dismissCurrent()
        expect(stack.routes.map(\.screen) == [.ai], "返回应回到来源模块")

        stack.navigate(to: .memoryGallery)
        stack.navigate(to: .finance)
        stack.navigate(to: .ai)
        expect(stack.routes.map(\.screen) == [.ai], "返回既有模块时应弹回而不是重复创建")

        stack.openRoot(.habits)
        expect(stack.routes.map(\.screen) == [.habits], "首页新入口应清空旧链路")

        _ = stack.dismissCurrent()
        expect(stack.current == nil, "根模块返回后应回到首页")

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
