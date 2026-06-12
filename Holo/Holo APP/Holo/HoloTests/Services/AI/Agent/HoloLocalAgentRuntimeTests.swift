//
//  HoloLocalAgentRuntimeTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 1.5 Mock Runtime 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Persistence/*.swift> \
//    <Services/AI/Agent/HoloLocalAgentRuntime.swift> <Services/AI/Agent/HoloAgentRuntimeFactory.swift> \
//    <本测试> -o /tmp/holo_agent_runtime_test && /tmp/holo_agent_runtime_test
//

import Foundation

/// Runtime 测试专用内存 Evidence Ledger（独立命名，避免与其他测试文件联合编译时重复定义）。
actor RuntimeMockLedger: HoloEvidenceLedgerProtocol {
    private var records: [HoloEvidenceRecord] = []
    func load() -> [HoloEvidenceRecord] { records }
    func upsert(_ newRecords: [HoloEvidenceRecord]) {
        for record in newRecords {
            if let index = records.firstIndex(where: { $0.dedupeKey == record.dedupeKey }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }
    }
}

@main
struct HoloLocalAgentRuntimeTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testStartMockJob_创建后进入running并写入初始checkpoint()
        try await testCompleteCurrentStep_plan完成后推进到executeTools()
        try await testResume_重启后从checkpoint对齐到当前step()
        try await testCancel_状态变为cancelled且resume不恢复执行()
        print("HoloLocalAgentRuntimeTests passed")
    }

    // MARK: - Helpers

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holo-agent-runtime-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用临时目录构造一套隔离的 runtime + store，便于断言落盘内容。
    private static func makeRuntime(dir: URL)
        -> (runtime: HoloLocalAgentRuntime, jobStore: HoloAgentJobStore, checkpointStore: HoloAgentCheckpointStore) {
        let ledger = RuntimeMockLedger()
        let checkpointStore = HoloAgentCheckpointStore(directory: dir)
        let jobStore = HoloAgentJobStore(directory: dir)
        let resultStore = HoloAgentResultStore(directory: dir)
        let persistence = HoloAgentPersistenceManager(
            evidenceLedger: ledger,
            checkpointStore: checkpointStore,
            jobStore: jobStore,
            resultStore: resultStore
        )
        let runtime = HoloLocalAgentRuntime(
            persistence: persistence,
            jobStore: jobStore,
            checkpointStore: checkpointStore
        )
        return (runtime, jobStore, checkpointStore)
    }

    // MARK: - 用例

    /// 创建 mock job 后应立即进入 running，并写入初始 checkpoint（step=plan, completedSteps 为空）。
    private static func testStartMockJob_创建后进入running并写入初始checkpoint() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let now = Date(timeIntervalSince1970: 1000)

        let job = try await fixture.runtime.startMockJob(question: "为什么最近开销变大？", now: now)

        expect(job.state == .running, "startMockJob 后 job 应进入 running，实际 \(job.state)")
        expect(job.currentStep == .plan, "初始 step 应为 plan，实际 \(job.currentStep)")
        expect(job.type == .debugMock, "mock job 类型应为 debugMock")
        expect(job.checkpointID != nil, "应回填 checkpointID")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint != nil, "应能读到初始 checkpoint")
        expect(checkpoint?.step == .plan, "初始 checkpoint step 应为 plan")
        expect(checkpoint?.completedSteps.isEmpty ?? false, "初始 checkpoint completedSteps 应为空")
        expect(checkpoint?.conversationState.isEmpty == false, "初始 checkpoint 应含 mock 消息")
    }

    /// 完成 plan step 后应推进到 executeTools，并写入新 checkpoint（completedSteps 含 plan）。
    private static func testCompleteCurrentStep_plan完成后推进到executeTools() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)

        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        let updated = try await fixture.runtime.completeCurrentStep(jobID: job.id, now: Date(timeIntervalSince1970: 2000))

        expect(updated.currentStep == .executeTools, "plan 完成后应推进到 executeTools，实际 \(updated.currentStep)")
        expect(updated.state == .running, "推进后仍应 running")

        let checkpoint = await fixture.checkpointStore.latestForJob(jobID: job.id)
        expect(checkpoint?.step == .executeTools, "新 checkpoint step 应为 executeTools")
        expect(checkpoint?.completedSteps == [.plan], "completedSteps 应含 plan，实际 \(String(describing: checkpoint?.completedSteps))")
    }

    /// 模拟 app 重启（新 runtime 实例，同一磁盘目录），resume 应从最新 checkpoint 对齐 step。
    private static func testResume_重启后从checkpoint对齐到当前step() async throws {
        let dir = makeTempDir()

        // 第一次运行：start + 完成 plan（推进到 executeTools）
        let run1 = makeRuntime(dir: dir)
        let job = try await run1.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))
        _ = try await run1.runtime.completeCurrentStep(jobID: job.id, now: Date(timeIntervalSince1970: 2000))

        // 模拟重启：新 runtime 实例读取同一目录，resume 对齐 checkpoint
        let run2 = makeRuntime(dir: dir)
        let resumed = try await run2.runtime.resume(jobID: job.id, now: Date(timeIntervalSince1970: 3000))

        expect(resumed.currentStep == .executeTools, "resume 后应从 checkpoint 的 step(executeTools) 继续，实际 \(resumed.currentStep)")
        expect(resumed.state == .running, "resume 后应为 running")
        expect(resumed.checkpointID != nil, "resume 后应回填 checkpointID")
    }

    /// cancel 后状态为 cancelled，且 resume 不应恢复执行（保持 cancelled）。
    private static func testCancel_状态变为cancelled且resume不恢复执行() async throws {
        let dir = makeTempDir()
        let fixture = makeRuntime(dir: dir)
        let job = try await fixture.runtime.startMockJob(question: "q", now: Date(timeIntervalSince1970: 1000))

        let cancelled = try await fixture.runtime.cancel(jobID: job.id, now: Date(timeIntervalSince1970: 2000))
        expect(cancelled.state == .cancelled, "cancel 后状态应为 cancelled")

        let stored = await fixture.jobStore.load().first { $0.id == job.id }
        expect(stored?.state == .cancelled, "落盘 job 状态应为 cancelled")

        // resume 一个 cancelled job 不应恢复执行
        let resumed = try await fixture.runtime.resume(jobID: job.id, now: Date(timeIntervalSince1970: 3000))
        expect(resumed.state == .cancelled, "cancelled job resume 不应恢复执行")
    }
}
