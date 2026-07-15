#if DEBUG
//
//  AIMemoryLabView.swift
//  Holo
//
//  统一记忆系统的 Debug-only 总览与显性验证入口。
//

import SwiftUI

enum AIMemoryLabScope: Hashable, Identifiable {
    case domain(HoloMemoryDomain)
    case crossDomain

    var id: String {
        switch self {
        case .domain(let domain): return domain.rawValue
        case .crossDomain: return "cross-domain"
        }
    }

    var title: String {
        switch self {
        case .domain(let domain): return domain.userFacingName
        case .crossDomain: return "跨域融合"
        }
    }

    var targetKey: String {
        switch self {
        case .domain(let domain): return HoloMemoryObservationTarget.domain(domain).stableKey
        case .crossDomain: return HoloMemoryObservationTarget.crossDomain.stableKey
        }
    }

    static var all: [AIMemoryLabScope] {
        HoloMemoryDomain.allCases.map(AIMemoryLabScope.domain) + [.crossDomain]
    }
}

struct AIMemoryLabView: View {
    @State private var records: [HoloMemoryRecord] = []
    @State private var scheduler: HoloMemorySchedulerDebugSnapshot?
    @State private var traces: [HoloMemoryTraceEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            operatingModeSection
            domainOverviewSection
            toolsSection
            recentTraceSection
        }
        .navigationTitle("AI 记忆实验室")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var operatingModeSection: some View {
        Section("当前运行状态") {
            LabeledContent("验证模式", value: "Dry-run 优先")
            LabeledContent("记忆总数", value: "\(records.count)")
            LabeledContent(
                "今日静默 AI 调用",
                value: scheduler.map { "\($0.aiCallsToday)/\($0.dailyCallLimit)" } ?? "—"
            )
            LabeledContent(
                "后台任务",
                value: scheduler?.isRunning == true ? "运行中" : "空闲"
            )

            if isLoading {
                HStack { ProgressView(); Text("读取诊断状态…") }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }
        }
    }

    private var domainOverviewSection: some View {
        Section {
            ForEach(AIMemoryLabScope.all) { scope in
                NavigationLink {
                    AIMemoryLabDomainView(scope: scope, allRecords: records)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(scope.title)
                            Spacer()
                            Text("\(records(for: scope).count) 条")
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 10) {
                            debugStatus(scope)
                            Text(lastRunText(scope))
                            if let retry = schedulerTarget(scope)?.retryAt {
                                Text("重试 \(retry.formatted(.relative(presentation: .numeric)))")
                                    .foregroundColor(.orange)
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("领域状态")
        } footer: {
            Text("进入领域后可检查 signal → package → 模型输出 → validator → planned mutation。默认只读，不发起网络请求，也不写入记忆仓库。")
        }
    }

    private var toolsSection: some View {
        Section("验证工具") {
            NavigationLink {
                AIMemoryLabQuerySimulatorView()
            } label: {
                Label("查询模拟器", systemImage: "text.magnifyingglass")
            }

            Button {
                Task {
                    await HoloMemoryTraceStore.shared.removeAll()
                    traces = []
                }
            } label: {
                Label("清空脱敏 Trace", systemImage: "trash")
            }
            .disabled(traces.isEmpty)
        }
    }

    @ViewBuilder
    private var recentTraceSection: some View {
        Section {
            if traces.isEmpty {
                Text("暂无 Trace。使用查询模拟器后，这里只会记录路由、记忆 ID 和刷新决策。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(traces.prefix(20)) { trace in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(trace.category.rawValue)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(trace.createdAt.formatted(.dateTime.hour().minute().second()))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let route = trace.route {
                            Text("route=\(route) · IDs=\(trace.selectedMemoryIDs.count) · refresh=\(trace.refreshDecision ?? "—")")
                                .font(.caption2.monospaced())
                        } else if let domain = trace.domain {
                            Text("domain=\(domain) · signals=\(trace.signalCount ?? 0) · mutations=\(trace.plannedMutationCount ?? 0)")
                                .font(.caption2.monospaced())
                        }
                    }
                }
            }
        } header: {
            Text("最近的脱敏 Trace")
        } footer: {
            Text("普通 Trace 不保存问题正文、记忆正文或 evidence 摘要。")
        }
    }

    private func records(for scope: AIMemoryLabScope) -> [HoloMemoryRecord] {
        switch scope {
        case .domain(let domain):
            return records.filter { $0.scope == .domain && $0.primaryDomain == domain }
        case .crossDomain:
            return records.filter { $0.scope == .crossDomain }
        }
    }

    private func schedulerTarget(
        _ scope: AIMemoryLabScope
    ) -> HoloMemorySchedulerDebugTargetSnapshot? {
        scheduler?.targets.first { $0.targetKey == scope.targetKey }
    }

    private func debugStatus(_ scope: AIMemoryLabScope) -> some View {
        let target = schedulerTarget(scope)
        return Label(
            target?.isDirty == true ? "dirty \(target?.changeCount ?? 0)" : "clean",
            systemImage: target?.isDirty == true ? "circle.fill" : "checkmark.circle"
        )
        .foregroundColor(target?.isDirty == true ? .orange : .green)
    }

    private func lastRunText(_ scope: AIMemoryLabScope) -> String {
        guard let date = schedulerTarget(scope)?.lastSuccessfulAt else { return "未成功运行" }
        return "上次成功 \(date.formatted(.relative(presentation: .numeric)))"
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            async let loadedRecords = repository.query(.all)
            async let loadedScheduler = HoloMemoryObservationScheduler.shared.debugSnapshot()
            async let loadedTraces = HoloMemoryTraceStore.shared.snapshot()
            records = try await loadedRecords
            scheduler = await loadedScheduler
            traces = await loadedTraces
        } catch {
            errorMessage = "诊断数据读取失败：\(error.localizedDescription)"
        }
        isLoading = false
    }
}
#endif
