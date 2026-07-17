import Foundation

@main
struct ThoughtAIClassificationPolicyStandaloneTests {
    static func main() {
        testDefaultAndStoredSetting()
        testInitialStatus()
        testDisabledThoughtCanStillBeManuallyOrganized()
        print("ThoughtAIClassificationPolicyStandaloneTests passed")
    }

    private static func testDefaultAndStoredSetting() {
        let suiteName = "ThoughtAIClassificationPolicyStandaloneTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建测试 UserDefaults")
        }
        defaults.removePersistentDomain(forName: suiteName)

        expect(ThoughtAIClassificationPolicy.isEnabled(in: defaults), "首次使用应默认开启")
        defaults.set(false, forKey: ThoughtAIClassificationPolicy.isEnabledKey)
        expect(!ThoughtAIClassificationPolicy.isEnabled(in: defaults), "应读取用户关闭状态")
        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func testInitialStatus() {
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 20, isEnabled: false) == "disabled",
            "关闭时新想法应标记为 disabled"
        )
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 9, isEnabled: true) == "skipped",
            "过短内容应跳过 AI 分类"
        )
        expect(
            ThoughtAIClassificationPolicy.initialStatus(contentLength: 10, isEnabled: true) == "pending",
            "达到长度阈值后应进入自动分类队列"
        )
    }

    private static func testDisabledThoughtCanStillBeManuallyOrganized() {
        expect(
            !ThoughtAIClassificationPolicy.manualBatchTerminalStatuses.contains("disabled"),
            "关闭自动分类创建的想法必须仍可手动批量整理"
        )
        expect(
            ThoughtAIClassificationPolicy.manualBatchTerminalStatuses.contains("organized"),
            "已整理想法不应重复进入手动批量"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
