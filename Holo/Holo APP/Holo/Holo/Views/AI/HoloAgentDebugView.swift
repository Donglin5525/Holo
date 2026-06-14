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

            Section("说明") {
                Text("此处用于内部调试 Agent 子系统。Feature Flag 开启后才会读取真实数据并调用后端 agent_loop；默认 mock 不产生真实结论。")
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
}

#Preview {
    NavigationStack {
        HoloAgentDebugView()
    }
}
