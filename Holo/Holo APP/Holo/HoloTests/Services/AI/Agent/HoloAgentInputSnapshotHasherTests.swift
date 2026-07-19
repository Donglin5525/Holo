//
//  HoloAgentInputSnapshotHasherTests.swift
//  HoloTests
//
//  Holo Agent 稳定执行 — Phase 1（§5.1，修 P0-1）
//  稳定输入快照 XCTest：固定向量防编码漂移、确定性、UTC 稳定、legacy 识别。
//  跨进程一致性由 HoloAgentInputSnapshotStandaloneTests（两个独立进程 diff）强制验证。
//

import XCTest
@testable import Holo

final class HoloAgentInputSnapshotHasherTests: XCTestCase {

    /// 固定参照时刻（2025-07-04T03:33:20Z），与运行环境时区无关。
    private let fixedTS = Date(timeIntervalSince1970: 1_751_600_000)

    private func vectorA() -> HoloAgentInputSnapshot {
        HoloAgentInputSnapshot(
            schemaVersion: 1, jobType: .deepAnalysis,
            userQuestion: "最近睡眠怎么样？", timeRange: nil,
            referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
        )
    }

    private func vectorB() -> HoloAgentInputSnapshot {
        HoloAgentInputSnapshot(
            schemaVersion: 1, jobType: .deepAnalysis,
            userQuestion: "上个月钱都花哪儿去了？",
            timeRange: HoloAgentTimeRange(
                label: "上月",
                start: Date(timeIntervalSince1970: 1_751_212_800),
                end: Date(timeIntervalSince1970: 1_753_804_800)
            ),
            referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
        )
    }

    private func vectorC() -> HoloAgentInputSnapshot {
        HoloAgentInputSnapshot(
            schemaVersion: 1, jobType: .memoryGallerySummary,
            userQuestion: nil, timeRange: nil,
            referenceDate: fixedTS, snapshotCutoffAt: fixedTS, toolCatalogVersion: 1
        )
    }

    // MARK: - 固定向量（§5.1：写死 canonical payload 与预期摘要，防未来编码漂移）

    func test固定向量A_canonicalJSON与hash() throws {
        let jsonData = try HoloAgentInputSnapshotHasher.canonicalJSONData(for: vectorA())
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertEqual(json, #"{"jobType":"deepAnalysis","referenceDate":"2025-07-04T03:33:20Z","schemaVersion":1,"snapshotCutoffAt":"2025-07-04T03:33:20Z","timeRange":null,"toolCatalogVersion":1,"userQuestion":"最近睡眠怎么样？"}"#)
        XCTAssertEqual(HoloAgentInputSnapshotHasher.hash(for: vectorA()),
                       "0671ed0d575d32196f99dc5f35d68a1dec4ba2e5b7d5d37d3b4cac7061446f99")
    }

    func test固定向量B_含timeRange() {
        XCTAssertEqual(HoloAgentInputSnapshotHasher.hash(for: vectorB()),
                       "78e3b89348c531c658a95c14821e1dea7b0447c443584f31819104a61f876f9d")
    }

    func test固定向量C_可选值为null显式编码() throws {
        let jsonData = try HoloAgentInputSnapshotHasher.canonicalJSONData(for: vectorC())
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains(#""userQuestion":null"#), "nil 可选值应显式编码为 null：\(json)")
        XCTAssertTrue(json.contains(#""timeRange":null"#), "nil 可选值应显式编码为 null：\(json)")
        XCTAssertEqual(HoloAgentInputSnapshotHasher.hash(for: vectorC()),
                       "754de95cb8f3dc138e1c19fb055022bcd94b8f68cad03c89af73b46e105ce5aa")
    }

    // MARK: - 确定性与环境无关性

    /// 同输入两次编码逐字节一致（sortedKeys 保证与字段书写顺序无关）。
    func test同输入两次编码一致() throws {
        let first = try HoloAgentInputSnapshotHasher.canonicalJSONData(for: vectorB())
        let second = try HoloAgentInputSnapshotHasher.canonicalJSONData(for: vectorB())
        XCTAssertEqual(first, second)
        XCTAssertEqual(String(data: first, encoding: .utf8), String(data: second, encoding: .utf8))
    }

    /// 日期必须编码为 ISO-8601 UTC（Z 后缀），不受运行环境时区影响。
    /// （固定 timeIntervalSince1970 输入 → 输出恒定，即跨时区稳定。）
    func test日期编码为UTC稳定() throws {
        let jsonData = try HoloAgentInputSnapshotHasher.canonicalJSONData(for: vectorA())
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains("2025-07-04T03:33:20Z"), "日期必须为 UTC Z 后缀：\(json)")
        XCTAssertFalse(json.contains("+"), "不得含时区偏移：\(json)")
    }

    // MARK: - legacy 识别（§十 Phase 1 任务 2：旧 Hasher 值不得用于拒绝恢复）

    func test旧Hasher十进制值判为legacy() {
        XCTAssertFalse(HoloAgentInputSnapshotHasher.isStableHash("1234567890"))
        XCTAssertFalse(HoloAgentInputSnapshotHasher.isStableHash("-8523015869675982626"))
        XCTAssertFalse(HoloAgentInputSnapshotHasher.isStableHash(""))
        XCTAssertTrue(HoloAgentInputSnapshotHasher.isStableHash(
            "0671ed0d575d32196f99dc5f35d68a1dec4ba2e5b7d5d37d3b4cac7061446f99"))
    }

    // MARK: - 从 Job 构造（冻结字段与回落）

    private func makeJob(question: String, createdAt: Date) -> HoloAgentJob {
        HoloAgentJob(
            id: "job-x", type: .deepAnalysis, userQuestion: question,
            trigger: .userQuestion, state: .running, currentStep: .plan,
            createdAt: createdAt, updatedAt: createdAt,
            lastForegroundRunAt: nil, timeRange: nil,
            budget: HoloAgentBudget.normalDeep(now: createdAt),
            checkpointID: nil, resultID: nil, errorSummary: nil, deviceID: nil
        )
    }

    func test旧Job无冻结字段时回落createdAt() {
        let job = makeJob(question: "最近睡眠怎么样？", createdAt: fixedTS)
        XCTAssertNil(job.referenceDate)
        XCTAssertEqual(HoloAgentInputSnapshotHasher.hash(for: job),
                       HoloAgentInputSnapshotHasher.hash(for: vectorA()))
    }

    func test冻结字段变化改变hash() {
        var job = makeJob(question: "最近睡眠怎么样？", createdAt: fixedTS)
        let base = HoloAgentInputSnapshotHasher.hash(for: job)
        job.snapshotCutoffAt = fixedTS.addingTimeInterval(3600)
        XCTAssertNotEqual(HoloAgentInputSnapshotHasher.hash(for: job), base,
                          "snapshotCutoffAt 变化必须改变输入身份")
    }
}
