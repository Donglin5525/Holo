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
    @State private var operationResult: String?
    @State private var isRunningObservation = false
    @State private var isResettingValidation = false
    @State private var inboxSnapshot = HoloMemoryInboxSnapshot(
        newMemoryCount: 0,
        pendingConfirmationCount: 0,
        hasUnreadMigrationSummary: false
    )

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
            LabeledContent("验证模式", value: "手动真实运行 + 只读检查")
            LabeledContent("记忆总数", value: "\(records.count)")
            LabeledContent(
                "采用状态",
                value: "自动 \(automaticCount) / 待确认 \(pendingCount) / 归档 \(archivedCount)"
            )
            LabeledContent("汇总回执", value: inboxSnapshot.isEmpty ? "无未读" : inboxSnapshot.summaryText)
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
            Text("进入领域后可检查最近一次真实阶段回执和当前仓库快照；只有上方“运行一次真实观察”会发起请求。")
        }
    }

    private var toolsSection: some View {
        Section {
            Button {
                Task { await runLiveObservation() }
            } label: {
                HStack(spacing: 8) {
                    if isRunningObservation {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.circle")
                    }
                    Text(isRunningObservation ? "真实观察运行中…" : "运行一次真实观察")
                }
            }
            .disabled(isRunningObservation || isResettingValidation)

            if let operationResult {
                Label {
                    Text(operationResult)
                } icon: {
                    Image(
                        systemName: operationResult.hasPrefix("成功")
                            ? "checkmark.circle.fill" : "info.circle"
                    )
                }
                .font(.caption)
                .foregroundColor(operationResult.hasPrefix("成功") ? .green : .orange)
            }

            Button {
                Task { await resetValidationState() }
            } label: {
                Label(
                    isResettingValidation ? "正在重置…" : "重置今日验证状态",
                    systemImage: "arrow.counterclockwise.circle"
                )
            }
            .disabled(isRunningObservation || isResettingValidation)

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
        } header: {
            Text("验证工具")
        } footer: {
            Text("重置只清除 Debug 调用额度、dirty、退避和脱敏回执，不删除用户记忆或任何业务数据。")
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

    private var automaticCount: Int {
        records.filter {
            $0.state == .active && $0.adoptionMetadata?.disposition == .automatic
        }.count
    }

    private var pendingCount: Int { records.filter { $0.state == .candidate }.count }

    private var archivedCount: Int { records.filter { $0.state == .archived }.count }

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
            inboxSnapshot = await HoloMemoryReceiptStore.inboxSnapshot()
        } catch {
            errorMessage = "诊断数据读取失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    @MainActor
    private func runLiveObservation() async {
        isRunningObservation = true
        operationResult = nil
        let summary = await HoloMemoryLiveObservationCoordinator.shared.run(trigger: .dataChanged)
        operationResult = summary.developerMessage
        await refresh()
        isRunningObservation = false
    }

    @MainActor
    private func resetValidationState() async {
        isResettingValidation = true
        operationResult = nil
        let didReset = await HoloMemoryLiveObservationCoordinator.shared.debugResetValidationState()
        operationResult = didReset
            ? "已重置：可以立即重新运行；用户记忆和业务数据未改动"
            : "未重置：记忆任务正在运行，请等待完成后重试"
        await refresh()
        isResettingValidation = false
    }
}
#endif
