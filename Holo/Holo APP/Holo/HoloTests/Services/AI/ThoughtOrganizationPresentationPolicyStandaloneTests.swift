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

        // MARK: V2（2026-09-05 方案 §1.2）：自动标签校验通过即生效，无逐条确认工作流——
        // 含新标签与全复用统一弱提示，pendingConfirmation 分级停用
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["工作与事业/复盘", "埋点口径"],
                recognizedTagKeys: recognizedKeys
            ),
            .weakHint,
            "V2 含新标签也为弱提示（无确认工作流）"
        )
        expectEqual(
            ThoughtOrganizationPresentationPolicy.aiTagPresentation(
                hasAITagAssignments: true,
                aiTagNames: ["新词"],
                recognizedTagKeys: recognizedKeys
            ),
            .weakHint,
            "V2 单新标签也为弱提示"
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
        expectFalse(
            ThoughtOrganizationPresentationPolicy.cardShowsPendingConfirmation(
                organizedStatus: "organized", hasPendingTagConfirmation: true, topicConfidence: 0.9
            ),
            "V2 标签无确认负担，hasPendingTagConfirmation 不再触发角标"
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
