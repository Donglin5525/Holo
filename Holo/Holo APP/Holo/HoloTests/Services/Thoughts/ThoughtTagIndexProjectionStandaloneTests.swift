import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ThoughtTagIndexProjectionStandaloneTests.main()
    }
}
#endif

/// 想法自动整理 V2 纯逻辑测试（投影/策略/目录构造）
/// 直编译：swiftc -o /tmp/thoughtIndexV2Tests \
///   "Holo/Holo APP/Holo/Holo/Services/Thoughts/ThoughtTagIndexProjection.swift" \
///   "Holo/Holo APP/Holo/Holo/Services/Thoughts/ThoughtTagNormalizer.swift" \
///   "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtIndexV2Policy.swift" \
///   "Holo/Holo APP/Holo/Holo/Services/AI/ThoughtIndexDTOs.swift" \
///   "Holo/Holo APP/Holo/HoloTests/Services/Thoughts/ThoughtTagIndexProjectionStandaloneTests.swift" && /tmp/thoughtIndexV2Tests
struct ThoughtTagIndexProjectionStandaloneTests {
    static func main() {
        var passed = 0
        func run(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1 } catch {
                FileHandle.standardError.write("FAILED: \(name) — \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        run("textHash 稳定且区分正文", testTextHash)
        run("canonical 解析：重定向链与环防护", testCanonicalResolution)
        run("effectiveTags：用户决定优先、legacy 与失效 hash 不进有效集", testEffectiveTags)
        run("autoCollections：≥3 成集、正文变化失效、hidden 过滤、按最近想法排序", testAutoCollections)
        run("目录资格：legacy/provisional/重定向词条不进目录", testCatalogEligibility)
        run("脱敏：邮箱/手机/长数字占位", testRedaction)
        run("本地跳过：空白与仅标点跳过，短文本不跳过", testSkipRules)
        run("目录构造：ref 映射、blocked 约束、排除项与版本稳定", testCatalogBuilder)
        run("迁移规则所需枚举原值稳定", testRawValues)

        print("ThoughtTagIndexProjectionStandaloneTests passed (\(passed) tests)")
    }

    // MARK: - Helpers

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { self.description = message }
    }

    private static func tag(
        _ id: UUID, name: String = "AI", semantic: String? = nil,
        kind: ThoughtTagIndexKind? = nil, mergedInto: UUID? = nil,
        blocked: Bool = false, hidden: Bool = false
    ) -> ThoughtTagIndexSnapshot {
        ThoughtTagIndexSnapshot(
            id: id, name: name, semanticName: semantic, semanticDefinition: nil,
            aliases: [], indexKind: kind, nameLockedByUser: false,
            mergedIntoTagID: mergedInto, autoSuggestionBlocked: blocked,
            autoCollectionHidden: hidden
        )
    }

    private static func assignment(
        _ id: UUID, thought: UUID, tag: UUID,
        source: ThoughtTagAssignment.Source,
        version: Int16 = 2, state: ThoughtIndexState? = .active,
        hash: String? = "h", quote: String? = nil
    ) -> ThoughtAssignmentIndexSnapshot {
        ThoughtAssignmentIndexSnapshot(
            id: id, thoughtId: thought, tagId: tag, source: source,
            indexVersion: version, indexState: state,
            basisTextHash: hash, evidenceQuote: quote
        )
    }

    // MARK: - Tests

    private static func testTextHash() throws {
        let a = ThoughtTagIndexProjection.textHash("今天用 AI 写周报")
        let b = ThoughtTagIndexProjection.textHash("今天用 AI 写周报")
        let c = ThoughtTagIndexProjection.textHash("今天用 AI 写周报。")
        guard a == b else { throw TestError("同文不同 hash") }
        guard a != c else { throw TestError("异文同 hash") }
        guard a.count == 16 else { throw TestError("hash 长度应为 16 hex") }
        // emoji（代理对）不影响 UTF-8 稳定性
        let emoji = ThoughtTagIndexProjection.textHash("🙂测试🙂")
        guard emoji == ThoughtTagIndexProjection.textHash("🙂测试🙂") else { throw TestError("emoji 不稳定") }
    }

    private static func testCanonicalResolution() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var tags: [UUID: ThoughtTagIndexSnapshot] = [:]
        tags[a] = tag(a, name: "AI", mergedInto: b)
        tags[b] = tag(b, name: "人工智能", mergedInto: c)
        tags[c] = tag(c, name: "AI技术")
        // 链式解析到终点
        guard ThoughtTagIndexProjection.canonicalTagId(a, tags: tags) == c else {
            throw TestError("链式重定向未解析到终点")
        }
        // 环防护：b→c→b 构成环时回落稳定值（不死循环）
        tags[c] = tag(c, name: "AI技术", mergedInto: b)
        _ = ThoughtTagIndexProjection.canonicalTagId(a, tags: tags) // 不挂起即通过
        // 断链：目标不存在回落自身
        tags[b] = tag(b, name: "人工智能", mergedInto: UUID())
        guard ThoughtTagIndexProjection.canonicalTagId(b, tags: tags) != nil else {
            throw TestError("断链崩溃")
        }
    }

    private static func testEffectiveTags() throws {
        let thoughtId = UUID()
        let userTag = UUID(), autoTag = UUID(), legacyTag = UUID(), staleTag = UUID()
        let dupTag = UUID() // 与 userTag canonical 相同的自动副本
        var tags: [UUID: ThoughtTagIndexSnapshot] = [:]
        tags[userTag] = tag(userTag, name: "工作/Holo", semantic: "Holo", kind: .user)
        tags[autoTag] = tag(autoTag, name: "AI", kind: .auto)
        tags[legacyTag] = tag(legacyTag, name: "旧AI词", kind: .legacy)
        tags[staleTag] = tag(staleTag, name: "过期", kind: .auto)
        tags[dupTag] = tag(dupTag, name: "AI副本", mergedInto: autoTag)

        let currentHash = "current"
        let effective = ThoughtTagIndexProjection.effectiveTags(
            assignments: [
                assignment(UUID(), thought: thoughtId, tag: userTag, source: .manual),
                assignment(UUID(), thought: thoughtId, tag: autoTag, source: .ai, hash: currentHash),
                assignment(UUID(), thought: thoughtId, tag: legacyTag, source: .ai, version: 0, state: nil, hash: currentHash),
                assignment(UUID(), thought: thoughtId, tag: staleTag, source: .ai, hash: "old-hash"),
                assignment(UUID(), thought: thoughtId, tag: dupTag, source: .ai, hash: currentHash),
            ],
            tags: tags,
            currentTextHash: currentHash
        )
        guard effective.count == 2 else { throw TestError("有效集应为 2（用户1+自动1），实际 \(effective.count)") }
        guard effective.contains(where: { $0.canonicalTagId == userTag && $0.isUserDecision }) else {
            throw TestError("用户手动标签缺失")
        }
        guard effective.contains(where: { $0.canonicalTagId == autoTag && $0.isAutoIndex }) else {
            throw TestError("V2 有效自动标签缺失")
        }
        // legacy（version 0）与 hash 不符的旧关系都不进有效集；
        // 重定向副本 canonical 去重（dupTag→autoTag，与 autoTag 同概念只保留一次）

        // blocked 词条的自动关系不产生入口
        let blockedTag = UUID()
        tags[blockedTag] = tag(blockedTag, name: "被拒", kind: .auto, blocked: true)
        let withBlocked = ThoughtTagIndexProjection.effectiveTags(
            assignments: [assignment(UUID(), thought: thoughtId, tag: blockedTag, source: .ai, hash: currentHash)],
            tags: tags,
            currentTextHash: currentHash
        )
        guard withBlocked.isEmpty else { throw TestError("blocked 词条仍产生自动入口") }
    }

    private static func testAutoCollections() throws {
        let tagAI = UUID(), tagSolo = UUID(), tagHidden = UUID()
        var tags: [UUID: ThoughtTagIndexSnapshot] = [:]
        tags[tagAI] = tag(tagAI, name: "AI", kind: .auto)
        tags[tagSolo] = tag(tagSolo, name: "孤独方向", kind: .auto)
        tags[tagHidden] = tag(tagHidden, name: "隐藏方向", kind: .auto, hidden: true)

        let t1 = UUID(), t2 = UUID(), t3 = UUID(), t4 = UUID()
        var hashes: [UUID: String] = [:]
        var createdAt: [UUID: Date] = [:]
        for (i, tid) in [t1, t2, t3, t4].enumerated() {
            hashes[tid] = "h\(i)"
            createdAt[tid] = Date(timeIntervalSince1970: Double(1000 + i))
        }
        // t4 的正文已编辑 → 旧关系失效，AI 合集只剩 3 条（仍达标）
        hashes[t4] = "changed"

        let relations = [
            assignment(UUID(), thought: t1, tag: tagAI, source: .ai, hash: "h0"),
            assignment(UUID(), thought: t2, tag: tagAI, source: .ai, hash: "h1"),
            assignment(UUID(), thought: t3, tag: tagAI, source: .ai, hash: "h2"),
            assignment(UUID(), thought: t4, tag: tagAI, source: .ai, hash: "h3"),
            // 只有 2 条 → 不成集
            assignment(UUID(), thought: t1, tag: tagSolo, source: .ai, hash: "h0"),
            assignment(UUID(), thought: t2, tag: tagSolo, source: .ai, hash: "h1"),
            // hidden 合集不出现
            assignment(UUID(), thought: t1, tag: tagHidden, source: .ai, hash: "h0"),
            assignment(UUID(), thought: t2, tag: tagHidden, source: .ai, hash: "h1"),
            assignment(UUID(), thought: t3, tag: tagHidden, source: .ai, hash: "h2"),
        ]

        let collections = ThoughtTagIndexProjection.autoCollections(
            effectiveAutoRelations: relations,
            thoughtContentHashes: hashes,
            thoughtCreatedAt: createdAt,
            tags: tags,
            minCount: 3
        )
        guard collections.count == 1 else { throw TestError("应只有 AI 一个合集（2条不成集/hidden过滤/失效不计），实际 \(collections.count)") }
        guard collections[0].displayName == "AI" else { throw TestError("合集名错误") }
        guard collections[0].count == 3 else { throw TestError("失效关系未剔除，count=\(collections[0].count)") }
        guard collections[0].tagName == "AI" else { throw TestError("筛选通道名缺失") }
    }

    private static func testCatalogEligibility() throws {
        guard ThoughtTagIndexProjection.isEligibleForCatalog(tag(UUID(), kind: .user)) else { throw TestError("user 应可入目录") }
        guard ThoughtTagIndexProjection.isEligibleForCatalog(tag(UUID(), kind: .auto)) else { throw TestError("auto 应可入目录") }
        guard !ThoughtTagIndexProjection.isEligibleForCatalog(tag(UUID(), kind: .legacy)) else { throw TestError("legacy 不应入目录") }
        guard !ThoughtTagIndexProjection.isEligibleForCatalog(tag(UUID(), kind: .provisional)) else { throw TestError("provisional 不应入目录") }
        guard !ThoughtTagIndexProjection.isEligibleForCatalog(tag(UUID(), kind: .auto, mergedInto: UUID())) else { throw TestError("重定向词条不应入目录") }
    }

    private static func testRedaction() throws {
        let input = "联系 foo@example.com 或 13812345678，身份证 11010119900307123X"
        let output = ThoughtIndexV2Policy.redactedText(forUpload: input)
        guard !output.contains("foo@example.com") else { throw TestError("邮箱未脱敏") }
        guard !output.contains("13812345678") else { throw TestError("手机号未脱敏") }
        guard !output.contains("11010119900307123") else { throw TestError("证件长数字未脱敏") }
        guard output.contains("[email]") && output.contains("[phone]") else { throw TestError("占位符缺失") }
        // 普通内容不受影响
        let plain = ThoughtIndexV2Policy.redactedText(forUpload: "今天用 AI 写周报，省了半小时")
        guard plain == "今天用 AI 写周报，省了半小时" else { throw TestError("普通文本被误改") }
    }

    private static func testSkipRules() throws {
        guard ThoughtIndexV2Policy.shouldSkipLocally("   \n  ") else { throw TestError("纯空白应跳过") }
        guard ThoughtIndexV2Policy.shouldSkipLocally("#标签 #另一个") else { throw TestError("仅 # 应跳过") }
        guard ThoughtIndexV2Policy.shouldSkipLocally("！！！？？") else { throw TestError("仅标点应跳过") }
        // 取消旧的 10 字门槛：短而有对象的不跳过（方案 §5.4）
        guard !ThoughtIndexV2Policy.shouldSkipLocally("GLM5.3发布了") else { throw TestError("短对象文本被误跳过") }
        guard !ThoughtIndexV2Policy.shouldSkipLocally("现在发现无论怎么努力用，买了") else { throw TestError("半句话被误跳过") }
        guard ThoughtIndexV2Policy.isTooLarge(String(repeating: "字", count: 8001)) else { throw TestError("超长未判 tooLarge") }
        guard !ThoughtIndexV2Policy.isTooLarge(String(repeating: "字", count: 8000)) else { throw TestError("8000 恰好不应超限") }
    }

    private static func testCatalogBuilder() throws {
        let userTag = UUID(), autoTag = UUID(), blockedTag = UUID(), legacyTag = UUID()
        let snapshots = [
            tag(userTag, name: "工作/写作", semantic: "写作", kind: .user),
            tag(autoTag, name: "AI", kind: .auto, blocked: true),   // 全局拒绝 → 目录内 + blockedRefs
            tag(blockedTag, name: "烟", kind: .auto),
            tag(legacyTag, name: "旧词", kind: .legacy),             // 不进目录
        ]
        let result = ThoughtIndexCatalogBuilder.build(
            snapshots: snapshots,
            legacyRejectedNames: ["旧词", "不存在的拒绝词"]
        )
        guard result.entries.count == 3 else { throw TestError("目录应 3 条（legacy 排除），实际 \(result.entries.count)") }
        // 用户词条排前 + userNamed 标注
        guard result.entries[0].name == "写作", result.entries[0].userNamed == true else { throw TestError("用户词条排序/标注错误") }
        guard result.entries[0].path == "工作/写作" else { throw TestError("多级路径未传 path") }
        // autoSuggestionBlocked 词条进 blockedRefs
        let blockedRef = result.refToTagId.first { $0.value == autoTag }?.key
        guard let blockedRef, result.blockedRefs.contains(blockedRef) else { throw TestError("全局拒绝词条未进 blockedRefs") }
        // legacy 词「旧词」不在目录 → 落 blockedNames；未知词同样进 blockedNames
        guard result.blockedNames.contains("旧词"), result.blockedNames.contains("不存在的拒绝词") else {
            throw TestError("无词条拒绝名未进 blockedNames")
        }
        // 版本稳定（同输入同 revision）
        let again = ThoughtIndexCatalogBuilder.build(snapshots: snapshots, legacyRejectedNames: ["旧词", "不存在的拒绝词"])
        guard result.revision == again.revision else { throw TestError("revision 不稳定") }
    }

    private static func testRawValues() throws {
        guard ThoughtTagIndexKind.user.rawValue == "user"
            && ThoughtTagIndexKind.auto.rawValue == "auto"
            && ThoughtTagIndexKind.provisional.rawValue == "provisional"
            && ThoughtTagIndexKind.legacy.rawValue == "legacy" else {
            throw TestError("IndexKind 原值漂移（存储兼容字段）")
        }
        guard ThoughtIndexState.active.rawValue == "active"
            && ThoughtIndexState.superseded.rawValue == "superseded"
            && ThoughtIndexState.legacy.rawValue == "legacy" else {
            throw TestError("IndexState 原值漂移（存储兼容字段）")
        }
        guard ThoughtIndexV2Policy.engineVersion == "thought_index_v2.1" else { throw TestError("引擎版本漂移") }
    }
}

#if HOLO_XCTEST_BRIDGE
extension ThoughtTagIndexProjectionStandaloneTests {
    static func main() { /* 桥接模式下由 XCTest 运行测试方法 */ }
}
#endif
