//
//  ThoughtOrganizationPresentationPolicyStandaloneTests.swift
//  Holo
//
//  P0 分级策略 standalone 测试（项目惯例：swiftc 直接编译运行，Executed 0 tests 不算通过）
//  覆盖：D-06′/D-07′/D-08′ 三态 + isNewTag + 卡片「等待确认」
//
//  Run:
//  swiftc "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtTagNormalizer.swift" \
//        "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtOrganizationPresentationPolicy.swift" \
//        "Holo/Holo APP/Holo/HoloTests/Services/AI/ThoughtOrganizationPresentationPolicyStandaloneTests.swift" \
//        -o /tmp/holo_presentation_policy_tests && /tmp/holo_presentation_policy_tests
//

import Foundation

@main
struct ThoughtOrganizationPresentationPolicyStandaloneTests {

    // 认可标签集合：「复盘」「客户沟通」
    private static let recognizedKeys: Set<String> = Set(
        ["复盘", "客户沟通"].map { ThoughtTagNormalizer.key($0) }
    )

    private static var failures: [String] = []

    static func main() {
        // MARK: D-06′ 全复用 → weakHint
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["工作与事业/复盘", "客户沟通"],
                recognizedTagKeys: recognizedKeys
            ),
            .weakHint,
            "全复用认可标签应显示弱提示"
        )

        // MARK: D-07′ 含新标签 → pendingConfirmation
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["工作与事业/复盘", "埋点口径"],
                recognizedTagKeys: recognizedKeys
            ),
            .pendingConfirmation,
            "含新标签应显示待确认"
        )
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["新词"],
                recognizedTagKeys: recognizedKeys
            ),
            .pendingConfirmation,
            "单新标签也应待确认"
        )

        // 大小写/空格变体不算新标签（归一化 key 命中）
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["复盘 "],
                recognizedTagKeys: recognizedKeys
            ),
            .weakHint,
            "归一化变体命中认可集合不算新标签"
        )

        // MARK: D-08′ 空 → silent
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: false,
                aiTagNames: [],
                recognizedTagKeys: recognizedKeys
            ),
            .silent,
            "空分类应为 silent"
        )

        // MARK: isNewTag
        expectTrue(
            ThoughtOrganizationPresentationPolicy.isNewTag("工作与事业/埋点口径", recognizedTagKeys: recognizedKeys),
            "路径新标签应为新"
        )
        expectFalse(
            ThoughtOrganizationPresentationPolicy.isNewTag("工作与事业/复盘", recognizedTagKeys: recognizedKeys),
            "复用路径不算新"
        )

        // MARK: 卡片「等待确认」
        expectTrue(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized", hasPendingTagConfirmation: false, topicConfidence: 0.6
            ),
            "低置信主题应显示等待确认"
        )
        expectTrue(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized", hasPendingTagConfirmation: true, topicConfidence: 0.9
            ),
            "新标签应显示等待确认"
        )
        expectFalse(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized", hasPendingTagConfirmation: false, topicConfidence: 0.9
            ),
            "干净结果不应显示等待确认"
        )
        expectFalse(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "failed", hasPendingTagConfirmation: true, topicConfidence: 0.6
            ),
            "failed 状态不显示等待确认"
        )
        expectFalse(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "processing", hasPendingTagConfirmation: true, topicConfidence: 0.6
            ),
            "processing 状态不显示等待确认"
        )
        // 主题置信度恰为 0（未归属）不触发待确认
        expectFalse(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized", hasPendingTagConfirmation: false, topicConfidence: 0
            ),
            "零置信（未归属）单独不触发等待确认"
        )

        // MARK: 汇总
        if failures.isEmpty {
            print("✅ ThoughtOrganizationPresentationPolicy standalone：全部 \(total) 项断言通过")
        } else {
            print("❌ 失败 \(failures.count)/\(total)：")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }

    private static var total = 0

    private static func expectEqual(
        _ lhs: ThoughtOrganizationPresentationPolicy.AIClassPresentation,
        _ rhs: ThoughtOrganizationPresentationPolicy.AIClassPresentation,
        _ message: String
    ) {
        total += 1
        if lhs != rhs { failures.append("\(message)：\(lhs) != \(rhs)") }
    }

    private static func expectTrue(_ value: Bool, _ message: String) {
        total += 1
        if !value { failures.append(message) }
    }

    private static func expectFalse(_ value: Bool, _ message: String) {
        expectTrue(!value, message)
    }
}
