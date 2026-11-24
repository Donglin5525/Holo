import SwiftUI

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        CalendarHeatmapDarkModeStandaloneTests.main()
    }
}
#endif
struct CalendarHeatmapDarkModeStandaloneTests {
    static func main() {
        // 色值已收口到 DesignSystem.holoHeatmapColor token，不再暴露 hex；
        // 这里验证各级色阶在深/浅色下均能区分，且同等级深浅色不同
        let lightPalette = (0...4).map {
            CalendarHeatmap.color(forLevel: $0, colorScheme: .light)
        }
        expect(
            Set(lightPalette.map { "\($0)" }).count == 5,
            "Light Mode 的五级月历色阶必须能够区分"
        )

        let darkPalette = (0...4).map {
            CalendarHeatmap.color(forLevel: $0, colorScheme: .dark)
        }
        expect(Set(darkPalette.map { "\($0)" }).count == 5, "Dark Mode 的五级月历色阶必须能够区分")

        for level in 0...4 {
            expect(
                CalendarHeatmap.color(forLevel: level, colorScheme: .light)
                    != CalendarHeatmap.color(forLevel: level, colorScheme: .dark),
                "同一活跃等级在 Light/Dark Mode 下必须使用不同色值"
            )
        }

        print("CalendarHeatmapDarkModeStandaloneTests passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
    }
}
