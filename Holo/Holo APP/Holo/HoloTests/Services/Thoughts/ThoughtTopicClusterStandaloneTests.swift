//
//  ThoughtTopicClusterStandaloneTests.swift
//  Holo
//
//  新脉络候选簇引擎 standalone 测试（V3 Phase 5）：只测纯函数核心
//  （并查集聚类/内聚度/阈值过滤/fingerprint），不依赖索引与网络。
//  运行入口：scripts/run-thought-cluster-standalone.sh
//

import Foundation

// V3 Phase 5 standalone：候选簇引擎纯函数核心行为锁定。
// 运行方式见 scripts/run-thought-cluster-standalone.sh（swiftc 直编，不挂 pbxproj）。

@main
struct ThoughtTopicClusterStandaloneTests {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        precondition(condition, "check failed: \(message()) (line \(line))")
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0) // precondition 崩溃时 stdout 缓冲会丢，先关缓冲
        sameDirectionCluster_andOrthogonalPairTooSmall()
        chainTransitivity_andCohesion()
        belowThresholdNoEdge()
        fingerprintDeterminism()
        print("PASS: 同向成簇/孤对不足额、链式传递归簇+内聚度=边均值、阈值过滤、指纹确定性")
    }

    private static func unitVector(_ first: Float, _ second: Float) -> [Float] {
        let norm = (first * first + second * second).squareRoot()
        return [first / norm, second / norm]
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: - 1. 同向三条成一簇；正交对只有两条不足 minSize

    static func sameDirectionCluster_andOrthogonalPairTooSmall() {
        let ids = (0..<5).map { _ in UUID() }
        let vectors: [UUID: [Float]] = [
            ids[0]: unitVector(1, 0.1),
            ids[1]: unitVector(1, 0.15),
            ids[2]: unitVector(0.95, 0.1),
            ids[3]: unitVector(0.05, 1),
            ids[4]: unitVector(0.1, 0.95),
        ]
        let threshold: Float = 0.55
        let components = ThoughtTopicClusterEngine.clusterComponents(
            ids: ids, vectors: vectors, threshold: threshold,
            minSize: ThoughtTopicClusterEngine.minClusterSize,
            neighborLookup: { id in
                ids.filter { $0 != id }.map { ($0, cosine(vectors[id]!, vectors[$0]!)) }
            })

        check(components.count == 1, "只有 3 条主组够格成簇，正交对 2 条不足 minSize：\(components.count)")
        check(Set(components[0].members) == Set([ids[0], ids[1], ids[2]]), "成员必须是主组三条")
        check(components[0].cohesion > 0.9, "同向簇内聚度接近 1：\(components[0].cohesion)")
    }

    // MARK: - 2. 链式相似（A~B~C，A⊥C）经并查集传递归簇；内聚度=边均值

    static func chainTransitivity_andCohesion() {
        let a = UUID(), b = UUID(), c = UUID()
        let adjacency: [UUID: [(id: UUID, similarity: Float)]] = [
            a: [(b, 0.9)],
            b: [(a, 0.9), (c, 0.8)],
            c: [(b, 0.8)],
        ]
        let components = ThoughtTopicClusterEngine.clusterComponents(
            ids: [a, b, c],
            vectors: [a: [1], b: [1], c: [1]],
            threshold: 0.55,
            minSize: 3,
            neighborLookup: { adjacency[$0] ?? [] })

        check(components.count == 1, "链式传递应归成一簇：\(components.count)")
        check(Set(components[0].members) == Set([a, b, c]), "成员 A/B/C")
        check(abs(components[0].cohesion - 0.85) < 0.001, "内聚度=边均值 0.85：\(components[0].cohesion)")
    }

    // MARK: - 3. 低于阈值的相似不建边

    static func belowThresholdNoEdge() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let adjacency: [UUID: [(id: UUID, similarity: Float)]] = [
            a: [(b, 0.5)],
            b: [(a, 0.5)],
            c: [(d, 0.9)],
            d: [(c, 0.9)],
        ]
        let components = ThoughtTopicClusterEngine.clusterComponents(
            ids: [a, b, c, d],
            vectors: [a: [1], b: [1], c: [1], d: [1]],
            threshold: 0.55,
            minSize: 3,
            neighborLookup: { adjacency[$0] ?? [] })

        check(components.isEmpty, "0.5 边不成簇、0.9 对只有 2 条不足 minSize：\(components.count)")
    }

    // MARK: - 4. 指纹：确定性、顺序无关、成员/版本敏感

    static func fingerprintDeterminism() {
        let a = UUID(), b = UUID(), c = UUID()
        let fp1 = ThoughtTopicClusterEngine.fingerprint(memberIDs: [a, b, c])
        let fp2 = ThoughtTopicClusterEngine.fingerprint(memberIDs: [c, a, b])
        check(fp1 == fp2, "指纹顺序无关")
        check(fp1 != ThoughtTopicClusterEngine.fingerprint(memberIDs: [a, b]), "成员变化必须变")
        check(fp1.count == 32, "SHA256 前 16 字节 hex = 32 字符：\(fp1.count)")
    }
}
