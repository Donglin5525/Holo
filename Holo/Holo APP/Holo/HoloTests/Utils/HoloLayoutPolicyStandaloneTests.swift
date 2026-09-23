//
//  HoloLayoutPolicyStandaloneTests.swift
//  Holo
//
//  运行：
//    cd "Holo/Holo APP/Holo"
//    swiftc Holo/Utils/HoloLayoutPolicy.swift \
//      HoloTests/Utils/HoloLayoutPolicyStandaloneTests.swift \
//      -o /tmp/holo-layout-policy-tests && /tmp/holo-layout-policy-tests
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloLayoutPolicyStandaloneTests.main()
    }
}
#endif
struct HoloLayoutPolicyStandaloneTests {

    // 断言计数器（standalone 路径无 XCTest 运行时，用自制断言）
    private static var failures: [String] = []
    private static var passed = 0

    private static func expect(
        _ condition: Bool,
        _ label: String,
        _ detail: String = ""
    ) {
        if condition {
            passed += 1
        } else {
            failures.append(label + (detail.isEmpty ? "" : " — \(detail)"))
        }
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ label: String
    ) {
        if actual == expected {
            passed += 1
        } else {
            failures.append("\(label) — 期望 \(expected)，实际 \(actual)")
        }
    }

    // MARK: - 侧边栏常驻决策

    /// 真机尺寸对照：
    /// iPad mini 竖 744 / 11 寸竖 834 / 11 寸横 1194 / 13 寸竖 1024 / 13 寸横 1366
    static func testSidebarPersistence() {
        // 11 寸竖屏 834：834−232=602 ≥ 600 → 默认常驻（与现状一致，但可手动收起）
        expect(HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 834),
               "11寸竖屏 834 默认侧边栏常驻")
        // iPad mini 竖屏 744：744−232=512 < 600 → 默认收成窄条
        expect(!HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 744),
               "mini 竖屏 744 默认收窄条")
        // 13 寸竖屏 1024：792 ≥ 600 → 常驻
        expect(HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 1024),
               "13寸竖屏 1024 侧边栏常驻")
        // 分屏半窗 ~505：273 < 600 → 窄条
        expect(!HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 505),
               "分屏半窗 505 收窄条")
        // 边界：600+232=832 恰好常驻，831 不行
        expect(HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 832),
               "边界 832（600+232）恰好常驻")
        expect(!HoloLayoutPolicy.prefersPersistentSidebar(windowWidth: 831),
               "边界 831 不足常驻")
    }

    // MARK: - 内容宽度推导

    static func testContentWidth() {
        expectEqual(
            HoloLayoutPolicy.contentWidth(windowWidth: 834, sidebar: .persistent),
            834 - 232 - 0.5,
            "834 常驻侧边栏后主内容 601.5")
        expectEqual(
            HoloLayoutPolicy.contentWidth(windowWidth: 744, sidebar: .rail),
            744 - 60 - 0.5,
            "744 窄条后主内容 683.5")
        expectEqual(
            HoloLayoutPolicy.contentWidth(windowWidth: 1024, sidebar: .rail),
            1024 - 60 - 0.5,
            "1024 收窄条后主内容 963.5（可重新评估双栏）")
        expectEqual(
            HoloLayoutPolicy.contentWidth(windowWidth: 390, sidebar: nil),
            390,
            "iPhone（无侧边栏）contentWidth=窗口宽")
    }

    // MARK: - 双栏就绪判定

    static func testSplitReady() {
        // 方案关键示例：1024 窗口常驻侧边栏后 791.5 → 不双栏（旧断点按全窗口 1024 会强行双栏）
        expect(!HoloLayoutPolicy.isSplitReady(
            contentWidth: HoloLayoutPolicy.contentWidth(windowWidth: 1024, sidebar: .persistent)),
               "1024 常驻侧边栏后 791.5 不双栏")
        // 同一窗口用户收起侧边栏 → 963.5 ≥ 860 → 双栏（用户选择改变呈现）
        expect(HoloLayoutPolicy.isSplitReady(
            contentWidth: HoloLayoutPolicy.contentWidth(windowWidth: 1024, sidebar: .rail)),
               "1024 收窄条后 963.5 可双栏")
        // 11 寸横屏 1194 常驻 → 961.5 双栏
        expect(HoloLayoutPolicy.isSplitReady(
            contentWidth: HoloLayoutPolicy.contentWidth(windowWidth: 1194, sidebar: .persistent)),
               "11寸横屏 1194 常驻双栏")
        // 11 寸竖屏 834 常驻 → 601.5 单列
        expect(!HoloLayoutPolicy.isSplitReady(
            contentWidth: HoloLayoutPolicy.contentWidth(windowWidth: 834, sidebar: .persistent)),
               "11寸竖屏 834 单列")
        // 边界与 nil（iPhone：环境未注入恒 false，保证手机零变化）
        expect(HoloLayoutPolicy.isSplitReady(contentWidth: 860), "边界 860 恰好双栏")
        expect(!HoloLayoutPolicy.isSplitReady(contentWidth: 859.9), "边界 859.9 不双栏")
        expect(!HoloLayoutPolicy.isSplitReady(contentWidth: nil), "nil（iPhone/未注入）恒不双栏")
    }

    // MARK: - 双栏栏宽分配

    static func testColumnWidths() {
        // 双栏就绪区间内，master 始终在 [360, 520]，detail ≥ 440
        let probes: [CGFloat] = [860, 900, 961.5, 1024, 1133.5, 1366]
        for width in probes {
            let master = HoloLayoutPolicy.masterColumnWidth(forSplitWidth: width)
            let detail = HoloLayoutPolicy.detailColumnWidth(forSplitWidth: width)
            expect(master >= HoloLayoutPolicy.masterColumnMinWidth,
                   "master ≥ 360（宽 \(width)）", "实际 \(master)")
            expect(master <= HoloLayoutPolicy.masterColumnMaxWidth,
                   "master ≤ 520（宽 \(width)）", "实际 \(master)")
            expect(detail >= HoloLayoutPolicy.detailColumnMinWidth,
                   "detail ≥ 440（宽 \(width)）", "实际 \(detail)")
        }
        // 具体分配快照（变更需伴随方案修订说明）
        expectEqual(HoloLayoutPolicy.masterColumnWidth(forSplitWidth: 860), 395.6, "860 → master 395.6")
        expectEqual(HoloLayoutPolicy.masterColumnWidth(forSplitWidth: 961.5), 442.29, "961.5 → master 442.29")
        expectEqual(HoloLayoutPolicy.masterColumnWidth(forSplitWidth: 1133.5), 520, "1133.5 → master 封顶 520")
    }

    // MARK: - 入口

    static func main() {
        testSidebarPersistence()
        testContentWidth()
        testSplitReady()
        testColumnWidths()

        if failures.isEmpty {
            print("✅ HoloLayoutPolicyStandaloneTests 全部通过（\(passed) 断言）")
        } else {
            print("❌ HoloLayoutPolicyStandaloneTests \(failures.count) 项失败：")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }
}

#if HOLO_XCTEST_BRIDGE
extension HoloLayoutPolicyStandaloneTests: XCTestCase {
    func testAll() {
        HoloLayoutPolicyStandaloneTests.main()
    }
}
#endif
