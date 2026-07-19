//
//  HoloAgentDebugView.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 6.1 内部 Agent 调试入口
//  仅在 HoloAIFeatureFlags.agentDebugModeEnabled 时由设置页展示。
//  用于输入测试问题、启动 mock/real agent job、查看 job state（内部调试，不面向普通用户）。
//

import SwiftUI

struct HoloAgentDebugView: View {

    @State private var question: String = ""
    @State private var statusText: String = "未启动"
    @State private var isRunning: Bool = false
    @State private var snapshotText: String = ""
    @State private var snapshotStatus: String = "尚未生成"
    @State private var isGeneratingSnapshot: Bool = false

    private let runtime = HoloAgentRuntimeFactory.makeDefaultRuntime()

    var body: some View {
        Form {
            Section("测试问题") {
                TextField("输入要分析的问题", text: $question, axis: .vertical)
                    .lineLimit(2...4)

                Button {
                    startMockJob()
                } label: {
                    HStack {
                        if isRunning { ProgressView().scaleEffect(0.8) }
                        Text(isRunning ? "运行中…" : "启动 Mock Agent Job")
                    }
                }
                .disabled(isRunning || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("任务状态") {
                Text(statusText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section("稳定性诊断") {
                Button {
                    generateSnapshot()
                } label: {
                    HStack {
                        if isGeneratingSnapshot { ProgressView().scaleEffect(0.8) }
                        Text(isGeneratingSnapshot ? "正在汇总…" : "生成脱敏诊断快照")
                    }
                }
                .disabled(isGeneratingSnapshot)

                Text(snapshotStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if !snapshotText.isEmpty {
                    ShareLink(
                        item: snapshotText,
                        subject: Text("Holo Agent 脱敏诊断快照"),
                        message: Text("仅含执行状态、租约、恢复与幂等技术元数据")
                    ) {
                        Label("导出诊断快照", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("说明") {
                Text("此处用于内部调试 Agent 子系统。Feature Flag 开启后才会读取真实数据并调用后端 agent_loop；默认 mock 不产生真实结论。诊断快照只含技术元数据，不导出问题、对话、金额、健康指标或证据正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Agent 调试")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
    }

    private func startMockJob() {
        guard !isRunning else { return }
        isRunning = true
        statusText = "启动中…"
        Task {
            do {
                let now = Date()
                let job = try await runtime.startMockJob(question: question, now: now)
                statusText = """
                jobID: \(job.id.prefix(8))
                state: \(job.state.rawValue)
                step: \(job.currentStep.rawValue)
                checkpointID: \(job.checkpointID?.prefix(8) ?? "无")
                """
            } catch {
                statusText = "错误：\(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    private func generateSnapshot() {
        guard !isGeneratingSnapshot else { return }
        isGeneratingSnapshot = true
        snapshotStatus = "正在读取本地 Agent 状态…"
        Task {
            do {
                async let jobs = HoloAgentJobStore().load()
                async let checkpoints = HoloAgentCheckpointStore().all()
                async let results = HoloAgentResultStore().all()
                async let evidence = HoloEvidenceLedger().load()
                async let events = HoloAgentEventStore.shared.load()
                async let activeLeases = HoloAgentScheduler.shared.debugActiveLeaseKinds()

                let loadedJobs = try await jobs
                let loadedCheckpoints = try await checkpoints
                let loadedResults = try await results
                let loadedEvidence = try await evidence
                let loadedEvents = try await events
                let loadedLeases = await activeLeases
                let metrics = HoloAgentReliabilityMetrics.make(from: loadedEvents)
                snapshotText = HoloAgentDebugExporter.makeSnapshot(
                    jobs: loadedJobs,
                    checkpoints: loadedCheckpoints,
                    results: loadedResults,
                    evidence: loadedEvidence,
                    featureFlags: [
                        "agentRuntimeEnabled": HoloAIFeatureFlags.agentRuntimeEnabled,
                        "agentStepIdempotencyEnabled": HoloAIFeatureFlags.agentStepIdempotencyEnabled,
                        "agentContinuedProcessingEnabled": HoloAIFeatureFlags.agentContinuedProcessingEnabled,
                        "agentObserverTier2Enabled": HoloAIFeatureFlags.agentObserverTier2Enabled
                    ],
                    activeLeases: loadedLeases,
                    events: loadedEvents
                )
                snapshotStatus = "事件 \(metrics.eventCount) · 完成 \(metrics.jobsCompleted) · 恢复 \(metrics.resumesStarted) · 系统中止 \(metrics.executionExpirations)"
            } catch {
                snapshotText = ""
                snapshotStatus = "生成失败：本地状态暂不可读，请解锁设备后重试"
            }
            isGeneratingSnapshot = false
        }
    }
}

#Preview {
    NavigationStack {
        HoloAgentDebugView()
    }
}
