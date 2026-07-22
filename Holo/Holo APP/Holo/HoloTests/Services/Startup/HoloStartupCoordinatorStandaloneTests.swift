import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async {
        await HoloStartupCoordinatorStandaloneTests.main()
    }
}
#endif
struct HoloStartupCoordinatorStandaloneTests {
    private static var assertions = 0

    @MainActor
    static func main() async {
        testCriticalStageIsIdempotent()
        await testAsyncStageIsIdempotent()
        print("✅ HoloStartupCoordinatorStandaloneTests: \(assertions) assertions passed")
    }

    @MainActor
    private static func testCriticalStageIsIdempotent() {
        let coordinator = HoloStartupCoordinator()
        var executions = 0
        coordinator.runCriticalOnce { executions += 1 }
        coordinator.runCriticalOnce { executions += 1 }

        expect(executions == 1, "critical 阶段重复触发时只能执行一次")
        expect(coordinator.hasCompleted(.critical), "critical 阶段应记录完成状态")
    }

    @MainActor
    private static func testAsyncStageIsIdempotent() async {
        let coordinator = HoloStartupCoordinator()
        var executions = 0
        await coordinator.runOnce(.afterFirstFrame) { executions += 1 }
        await coordinator.runOnce(.afterFirstFrame) { executions += 1 }

        expect(executions == 1, "首帧后阶段因 View 重建再次触发时不能重复执行")
        expect(coordinator.metrics.count == 1, "每个阶段只应留下一个耗时观测")
    }

    @MainActor
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError("❌ \(message)") }
    }
}
