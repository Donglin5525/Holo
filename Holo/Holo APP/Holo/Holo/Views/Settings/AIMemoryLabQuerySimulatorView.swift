#if DEBUG
//
//  AIMemoryLabQuerySimulatorView.swift
//  Holo
//
//  Debug-only 统一记忆查询模拟器。
//

import SwiftUI

struct AIMemoryLabQuerySimulatorView: View {
    @State private var question = "我最近状态如何"
    @State private var context: HoloMemoryQueryContext?
    @State private var renderedContext = ""
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField("输入要模拟的问题", text: $question, axis: .vertical)
                    .lineLimit(2...5)

                Button {
                    Task { await simulate() }
                } label: {
                    HStack {
                        if isRunning { ProgressView() }
                        Label("运行只读模拟", systemImage: "play.fill")
                    }
                }
                .disabled(isRunning || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("问题")
            } footer: {
                Text("使用真实 Query Service 与 Holo AI 开关，但不调用大模型、不修改记忆。问题正文和上下文只保留在当前临时页面。")
            }

            if let context {
                Section("路由结果") {
                    debugRow("route", context.route.rawValue)
                    debugRow("authority", context.answerAuthority.rawValue)
                    debugRow("detail fallback", context.requiresDetailData ? "YES" : "NO")
                    debugRow("estimated tokens", "\(context.estimatedTokens)")
                    debugRow("SWR", refreshText(context.refreshDecision))
                }

                Section("选中的记忆 ID") {
                    if context.records.isEmpty {
                        Text("无。可能是开关关闭、没有 active 记忆，或问题需要查询明细。")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(context.records) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.id)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text("\(record.scope.rawValue) · \(record.primaryDomain?.rawValue ?? "cross-domain") · \(record.state.rawValue)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if renderedContext.isEmpty {
                        Text("[空上下文]")
                            .foregroundColor(.secondary)
                    } else {
                        Text(renderedContext)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("最终模型上下文（临时敏感视图）")
                } footer: {
                    Text("这段正文不会写入 Trace；离开页面后即释放。")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }
        }
        .navigationTitle("查询模拟器")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func simulate() async {
        isRunning = true
        errorMessage = nil
        context = nil
        renderedContext = ""
        do {
            let service = try await HoloMemoryQueryService.live()
            let result = try await service.query(
                question: question,
                consumer: .analysis
            )
            context = result
            renderedContext = HoloMemoryContextEnvelope.render(result)
            await HoloMemoryTraceStore.shared.appendSelection(
                HoloMemorySelectionTrace(context: result),
                question: question
            )
        } catch {
            errorMessage = "模拟失败：\(error.localizedDescription)"
        }
        isRunning = false
    }

    private func refreshText(_ decision: HoloMemoryRefreshDecision) -> String {
        switch decision {
        case .none: return "none"
        case .disabled: return "disabled"
        case .scheduled(let targets):
            return "scheduled: \(targets.map(\.stableKey).joined(separator: ", "))"
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        } label: {
            Text(label).font(.caption)
        }
    }
}
#endif
