import SwiftUI

@main
struct CalendarHeatmapDarkModeStandaloneTests {
    static func main() {
        expect(
            (0...4).map { CalendarHeatmap.hex(forLevel: $0, colorScheme: .light) }
                == ["#F6F8FB", "#EAF2FF", "#D9ECFF", "#CFE7F7", "#C8DDF8"],
            "Light Mode 必须保持现有月历色阶"
        )

        let darkPalette = (0...4).map {
            CalendarHeatmap.hex(forLevel: $0, colorScheme: .dark)
        }
        expect(Set(darkPalette).count == 5, "Dark Mode 的五级月历色阶必须能够区分")

        for level in 0...4 {
            expect(
                CalendarHeatmap.hex(forLevel: level, colorScheme: .light)
                    != CalendarHeatmap.hex(forLevel: level, colorScheme: .dark),
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
