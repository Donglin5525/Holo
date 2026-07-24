import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        InstallmentNoteSanitizerStandaloneTests.main()
    }
}
#endif
struct InstallmentNoteSanitizerStandaloneTests {
    static func main() {
        expect(InstallmentNoteSanitizer.clean("[分期 1/12] 智谱 max") == "智谱 max", "应移除单个旧前缀")
        expect(
            InstallmentNoteSanitizer.clean("[分期 2/12] [分期 1/12] [分期 1/12] 智谱 max") == "智谱 max",
            "应一次移除重复叠加的旧前缀"
        )
        expect(InstallmentNoteSanitizer.clean("智谱 max") == "智谱 max", "正常商品名称不应变化")
        expect(InstallmentNoteSanitizer.clean("[分期 1/12]") == nil, "仅含分期前缀时应视为空名称")
        expect(InstallmentNoteSanitizer.clean(nil) == nil, "空名称应保持为空")
        print("InstallmentNoteSanitizerStandaloneTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
