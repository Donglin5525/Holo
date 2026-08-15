import SwiftUI

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
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
            fatalError(message)
        }
    }
}
