//
//  HoloAgentInputSnapshotStandaloneTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 1（§5.1 / §11.3）
//  稳定输入快照 standalone 验证：固定向量 + 跨进程一致性。
//  旧实现用 Swift `Hasher`（每进程随机 seed），两个进程对同一输入必得不同 hash；
//  本测试用两个独立进程跑同一可执行文件，输出必须完全一致（§十 Phase 1 验收门）。
//
//  编译（在 "Holo/Holo APP/Holo" 目录下）：
//  swiftc -parse-as-library \
//    "Holo/Models/AI/Agent/HoloAgentJobModels.swift" \
//    "Holo/Models/AI/Agent/HoloAgentTimeRange.swift" \
//    "Holo/Models/AI/Agent/HoloAgentExecutionModels.swift" \
//    "Holo/Services/AI/Agent/HoloAgentInputSnapshotHasher.swift" \
//    <本测试> -o /tmp/holo_snapshot_test
//
//  运行：
//  1) 自校验：/tmp/holo_snapshot_test
//  2) 跨进程一致性（两个独立进程，diff 必须为空）：
//     /tmp/holo_snapshot_test --print-hash A > /tmp/holo_hash_run1.txt
//     /tmp/holo_snapshot_test --print-hash A > /tmp/holo_hash_run2.txt
//     diff /tmp/holo_hash_run1.txt /tmp/holo_hash_run2.txt && echo CROSS-PROCESS-OK
//

import Foundation

@main
struct HoloAgentInputSnapshotStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    /// 固定参照时刻（2025-07-04T03:33:20Z），与环境时区无关。
    static let fixedTS = Date(timeIntervalSince1970: 1_751_600_000)

    /// 固定向量 payload（A/B/C 三组，覆盖可选值有无与不同 jobType）。
    static func vectorPayload(_ name: String) -> HoloAgentInputSnapshot {
        switch name {
        case "A":
            return HoloAgentInputSnapshot(
                schemaVersion: 1, jobType: .deepAnalysis,
                userQuestion: "最近睡眠怎么样？", timeRange: nil,
                referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
            )
        case "B":
            return HoloAgentInputSnapshot(
                schemaVersion: 1, jobType: .deepAnalysis,
                userQuestion: "上个月钱都花哪儿去了？",
                timeRange: HoloAgentTimeRange(
                    label: "上月",
                    start: Date(timeIntervalSince1970: 1_751_212_800),
                    end: Date(timeIntervalSince1970: 1_753_804_800)
                ),
                referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
            )
        default: // "C"
            return HoloAgentInputSnapshot(
                schemaVersion: 1, jobType: .memoryGallerySummary,
                userQuestion: nil, timeRange: nil,
                referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
            )
        }
    }

    static func main() async {
        // --print-hash <A|B|C>：只打印 hash 一行，供 shell 两个独立进程 diff。
        let args = CommandLine.arguments
        if let flagIndex = args.firstIndex(of: "--print-hash"), args.count > flagIndex + 1 {
            print(HoloAgentInputSnapshotHasher.hash(for: vectorPayload(args[flagIndex + 1])))
            return
        }

        test固定向量canonicalJSON与摘要()
        test同输入两次编码一致()
        test可选值显式编码为null()
        test旧Hasher值识别为legacy()
        test从Job构造快照旧字段回落createdAt()
        print("HoloAgentInputSnapshotStandaloneTests passed")
    }

    /// §5.1 验收：canonical payload 与预期摘要写死，防止未来编码漂移。
    static func test固定向量canonicalJSON与摘要() {
        let a = vectorPayload("A")
        let aJSON = String(data: try! HoloAgentInputSnapshotHasher.canonicalJSONData(for: a), encoding: .utf8)!
        expect(aJSON == #"{"jobType":"deepAnalysis","referenceDate":"2025-07-04T03:33:20Z","schemaVersion":1,"snapshotCutoffAt":"2025-07-04T03:33:20Z","timeRange":null,"toolCatalogVersion":1,"userQuestion":"最近睡眠怎么样？"}"#,
               "A canonical JSON 漂移：\(aJSON)")
        expect(HoloAgentInputSnapshotHasher.hash(for: a) == "0671ed0d575d32196f99dc5f35d68a1dec4ba2e5b7d5d37d3b4cac7061446f99",
               "A hash 漂移：\(HoloAgentInputSnapshotHasher.hash(for: a))")

        let b = vectorPayload("B")
        expect(HoloAgentInputSnapshotHasher.hash(for: b) == "78e3b89348c531c658a95c14821e1dea7b0447c443584f31819104a61f876f9d",
               "B hash 漂移：\(HoloAgentInputSnapshotHasher.hash(for: b))")

        let c = vectorPayload("C")
        expect(HoloAgentInputSnapshotHasher.hash(for: c) == "754de95cb8f3dc138e1c19fb055022bcd94b8f68cad03c89af73b46e105ce5aa",
               "C hash 漂移：\(HoloAgentInputSnapshotHasher.hash(for: c))")
    }

    /// 同输入两次编码必须逐字节一致（字段顺序无关：sortedKeys 保证 canonical）。
    static func test同输入两次编码一致() {
        let payload = vectorPayload("B")
        let first = try! HoloAgentInputSnapshotHasher.canonicalJSONData(for: payload)
        let second = try! HoloAgentInputSnapshotHasher.canonicalJSONData(for: payload)
        expect(first == second, "同输入两次 canonical 编码必须一致")
        expect(HoloAgentInputSnapshotHasher.hash(for: payload) == HoloAgentInputSnapshotHasher.hash(for: payload),
               "同输入两次 hash 必须一致")
    }

    /// 可选值必须显式编码（null），不能省略 key（省略与 null 在语义合并时不可区分）。
    static func test可选值显式编码为null() {
        let c = vectorPayload("C")
        let json = String(data: try! HoloAgentInputSnapshotHasher.canonicalJSONData(for: c), encoding: .utf8)!
        expect(json.contains(#""userQuestion":null"#), "nil userQuestion 应编码为 null：\(json)")
        expect(json.contains(#""timeRange":null"#), "nil timeRange 应编码为 null：\(json)")
        expect(json.contains("Z"), "日期必须为 ISO-8601 UTC（Z 后缀）：\(json)")
    }

    /// 旧 Swift `Hasher` 值（十进制整数串，可能为负）必须识别为 legacy，不得用于拒绝恢复。
    static func test旧Hasher值识别为legacy() {
        expect(!HoloAgentInputSnapshotHasher.isStableHash("1234567890"), "十进制串应判为 legacy")
        expect(!HoloAgentInputSnapshotHasher.isStableHash("-8523015869675982626"), "负数十进制串应判为 legacy")
        expect(!HoloAgentInputSnapshotHasher.isStableHash(""), "空串应判为 legacy")
        expect(HoloAgentInputSnapshotHasher.isStableHash(
            "0671ed0d575d32196f99dc5f35d68a1dec4ba2e5b7d5d37d3b4cac7061446f99"), "64 位小写 hex 应判为稳定 hash")
        expect(!HoloAgentInputSnapshotHasher.isStableHash(
            "0671ED0D575D32196F99DC5F35D68A1DEC4BA2E5B7D5D37D3B4CAC7061446F99"), "大写 hex 不是本实现输出，判为 legacy")
    }

    /// 从 job 构造快照：referenceDate/snapshotCutoffAt 缺失（旧数据）时回落 createdAt。
    static func test从Job构造快照旧字段回落createdAt() {
        let created = Date(timeIntervalSince1970: 1_751_600_000)
        var job = HoloAgentJob(
            id: "job-x", type: .deepAnalysis, userQuestion: "最近睡眠怎么样？",
            trigger: .userQuestion, state: .running, currentStep: .plan,
            createdAt: created, updatedAt: created,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: created),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
        // 旧数据：referenceDate/snapshotCutoffAt 为 nil → 回落 createdAt，与固定向量 A 一致
        expect(HoloAgentInputSnapshotHasher.hash(for: job)
               == HoloAgentInputSnapshotHasher.hash(for: vectorPayload("A")),
               "旧 job（无冻结字段）应回落 createdAt 并与向量 A 一致")

        // 新数据：创建时写入冻结字段 = createdAt，同样一致
        job.referenceDate = created
        job.snapshotCutoffAt = created
        expect(HoloAgentInputSnapshotHasher.hash(for: job)
               == HoloAgentInputSnapshotHasher.hash(for: vectorPayload("A")),
               "新 job（冻结字段 = createdAt）应与向量 A 一致")

        // 输入变化（改问题）→ hash 必须变化
        job.userQuestion = "改了问题"
        expect(HoloAgentInputSnapshotHasher.hash(for: job)
               != HoloAgentInputSnapshotHasher.hash(for: vectorPayload("A")),
               "输入变化后 hash 必须不同")
    }
}
