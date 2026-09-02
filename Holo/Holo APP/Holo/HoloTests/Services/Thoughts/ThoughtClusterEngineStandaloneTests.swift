import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        ThoughtClusterEngineStandaloneTests.main()
    }
}
#endif
struct ThoughtClusterEngineStandaloneTests {
    static func main() {
        testClusterBySharedTag()
        testMinClusterSizeScatter()
        testCrossFormIdentityClustering()
        testClusterNameUsesLeafSegment()
        testEmptyInput()
        print("ThoughtClusterEngineStandaloneTests passed")
    }

    /// 共享标签的想法聚成一簇，簇名取该标签
    private static func testClusterBySharedTag() {
        let result = ThoughtClusterEngine.cluster([
            snap("a1", ["阅读"], "深度工作法笔记"),
            snap("a2", ["阅读", "专注"], "Cal Newport 摘录"),
            snap("a3", ["阅读"], "速读存疑"),
        ])

        expect(result.clusters.count == 1, "应聚成一簇")
        expect(result.clusters[0].name == "阅读", "簇名应取共现标签")
        expect(result.clusters[0].thoughtIds.count == 3, "三条都应入簇")
        expect(result.clusters[0].samples.count == 3, "样例引用原话")
        expect(result.scatteredIds.isEmpty, "无散苗")
    }

    /// 低于成簇阈值的想法进散苗
    private static func testMinClusterSizeScatter() {
        let result = ThoughtClusterEngine.cluster([
            snap("s1", ["睡眠"], "睡得晚"),
            snap("s2", ["咖啡"], "下午咖啡"),
        ])

        expect(result.clusters.isEmpty, "单条不成簇")
        expect(result.scatteredIds.count == 2, "两条都应散苗")
    }

    /// 双形态身份：#books 与 AI「主题/books」是同一信号，应聚拢
    private static func testCrossFormIdentityClustering() {
        let result = ThoughtClusterEngine.cluster([
            snap("c1", ["books"], "reading notes"),
            snap("c2", ["工作与事业/books"], "another book note"),
            snap("c3", ["books"], "third note"),
        ])

        expect(result.clusters.count == 1, "跨形态应聚成一簇")
        expect(result.clusters[0].thoughtIds.count == 3, "三条都应入簇")
    }

    /// 多标签想法归入簇更大的那个，不重复入簇
    private static func testClusterNameUsesLeafSegment() {
        let result = ThoughtClusterEngine.cluster([
            snap("m1", ["生活与健康/晨跑"], "早起跑步"),
            snap("m2", ["生活与健康/晨跑"], "配速记录"),
            snap("m3", ["晨跑", "生活与健康"], "拉伸"),
        ])

        expect(result.clusters.count == 1, "路径与叶子应聚成同一簇")
        expect(result.clusters[0].name == "晨跑", "簇名应取叶段展示名")
        expect(result.clusters[0].thoughtIds.count == 3, "多标签想法只入一次簇")
    }

    private static func testEmptyInput() {
        let result = ThoughtClusterEngine.cluster([])
        expect(result.isEmpty, "空输入应得空结果")
    }

    private static func snap(_ suffix: String, _ tags: [String], _ line: String) -> ThoughtClusterEngine.ThoughtSnapshot {
        ThoughtClusterEngine.ThoughtSnapshot(id: UUID(), tagNames: tags, firstLine: line)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
