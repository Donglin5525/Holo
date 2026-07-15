#if DEBUG
//
//  AIMemoryLabDomainView.swift
//  Holo
//
//  单领域 dry-run 管线、跨域四门审计与单条记录检查。
//

import SwiftUI

struct AIMemoryLabDomainView: View {
    let scope: AIMemoryLabScope
    let allRecords: [HoloMemoryRecord]

    @State private var tombstoneIDs = Set<String>()
    @State private var latestPipeline: HoloMemoryTraceEntry?

    private var records: [HoloMemoryRecord] {
        switch scope {
        case .domain(let domain):
            return allRecords.filter { $0.scope == .domain && $0.primaryDomain == domain }
        case .crossDomain:
            return allRecords.filter { $0.scope == .crossDomain }
        }
    }

    var body: some View {
        List {
            if case .domain = scope {
                livePipelineSection
            }
            dryRunSection
            if scope == .crossDomain {
                crossDomainAuditSection
            }
            recordsSection
        }
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTombstonesAndTrace() }
    }

    private var dryRunSection: some View {
        Section {
            Label("只读仓库快照：不发网络请求，不写仓库", systemImage: "shield.checkered")
                .foregroundColor(.green)
            pipelineRow("Persisted evidence", value: "\(records.flatMap(\.evidenceRefs).count) 条证据元数据")
            pipelineRow("Persisted records", value: "\(records.count) 条现有记录")
            pipelineRow(
                "Repository state",
                value: "active \(records.filter { $0.state == .active }.count) / candidate \(records.filter { $0.state == .candidate }.count)"
            )
        } header: {
            Text("当前仓库")
        } footer: {
            Text("需要查看敏感摘要时，只能进入单条记录后主动开启临时显示；退出页面即释放。")
        }
    }

    private var livePipelineSection: some View {
        Section {
            if let trace = latestPipeline {
                pipelineRow("Signal", value: "\(trace.signalCount ?? 0) 条真实输入信号")
                pipelineRow(
                    "Package",
                    value: "\(trace.packageRecordCount ?? 0) 条既有记忆进入上下文"
                )
                pipelineRow("AI request", value: aiRequestText(trace))
                pipelineRow("Validator", value: validatorText(trace))
                pipelineRow(
                    "Planned mutation",
                    value: "\(trace.plannedMutationCount ?? 0) 条"
                )
                pipelineRow(
                    "Committed mutation",
                    value: "\(trace.committedMutationCount ?? 0) 条"
                )
                pipelineRow("Outcome", value: outcomeText(trace))
                Text(trace.createdAt.formatted(.dateTime.month().day().hour().minute().second()))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("还没有真实运行回执。请返回实验室，先重置验证状态，再运行一次真实观察。")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("最近一次真实运行")
        } footer: {
            Text("这里只保存数量、阶段和拒绝代码，不保存模型原文、记忆正文或证据摘要。")
        }
    }

    private var crossDomainAuditSection: some View {
        Section {
            if crossDomainAudits.isEmpty {
                Text("当前没有可审计的领域记忆组合。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(crossDomainAudits.prefix(40)) { audit in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(audit.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(audit.passed ? "候选" : "未通过")
                                .font(.caption2)
                                .foregroundColor(audit.passed ? .green : .orange)
                        }
                        gateLine("跨领域", passed: audit.crossDomainGate)
                        gateLine("共同时间", passed: audit.timeGate)
                        gateLine("共同锚点", passed: audit.anchorGate)
                        gateLine("独立底层证据", passed: audit.lineageGate)
                        Text(audit.reason)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if !audit.lineageKeys.isEmpty {
                            Text("lineage: \(audit.lineageKeys.joined(separator: ", "))")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("跨域四道门")
        } footer: {
            Text("这里同时展示通过与未通过组合，便于验证为什么没有形成跨域记忆。")
        }
    }

    private var recordsSection: some View {
        Section {
            if records.isEmpty {
                Text("当前没有记录")
                    .foregroundColor(.secondary)
            } else {
                ForEach(records) { record in
                    NavigationLink {
                        AIMemoryLabRecordInspectorView(
                            record: record,
                            tombstoneHit: tombstoneIDs.contains(record.id)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displaySummary.isEmpty ? "[正文已擦除]" : record.displaySummary)
                                .lineLimit(2)
                            Text("\(record.state.rawValue) · v\(record.recordVersion) · evidence \(record.evidenceRefs.count) · counter \(record.counterEvidenceRefs.count)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("记录检查")
        }
    }

    private func pipelineRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold).monospaced())
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func gateLine(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "xmark.circle")
            .font(.caption2)
            .foregroundColor(passed ? .green : .orange)
    }

    private func aiRequestText(_ trace: HoloMemoryTraceEntry) -> String {
        guard let status = trace.aiRequestStatus else { return "未发起" }
        if status == "succeeded" { return "成功返回" }
        if status.hasPrefix("failed:") {
            return "失败 · \(status.replacingOccurrences(of: "failed:", with: ""))"
        }
        return status
    }

    private func validatorText(_ trace: HoloMemoryTraceEntry) -> String {
        let accepted = trace.validatorAcceptedCount ?? 0
        let rejected = trace.validatorRejections ?? []
        if rejected.isEmpty { return "通过 \(accepted) 条；无拒绝" }
        return "通过 \(accepted) 条；拒绝：\(rejected.joined(separator: ", "))"
    }

    private func outcomeText(_ trace: HoloMemoryTraceEntry) -> String {
        guard let outcome = trace.outcome else { return "未记录" }
        if outcome == "succeeded" { return "成功完成" }
        if outcome == "validatorRejected" { return "Validator 拒绝，未写入" }
        if outcome == "requestFailed" { return "AI 请求失败，未写入" }
        if outcome.hasPrefix("persistenceFailed:") {
            return "仓库写入失败 · \(outcome.replacingOccurrences(of: "persistenceFailed:", with: ""))"
        }
        return outcome
    }

    private var crossDomainAudits: [AIMemoryLabCrossDomainAudit] {
        AIMemoryLabCrossDomainAudit.build(from: allRecords)
    }

    @MainActor
    private func loadTombstonesAndTrace() async {
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            tombstoneIDs = Set(try await repository.queryTombstones().map(\.identityKey))
        } catch {
            tombstoneIDs = []
        }

        if case .domain(let domain) = scope {
            latestPipeline = await HoloMemoryTraceStore.shared.latestDomainPipeline(domain: domain)
        }
    }
}

private struct AIMemoryLabCrossDomainAudit: Identifiable {
    var id: String
    var title: String
    var crossDomainGate: Bool
    var timeGate: Bool
    var anchorGate: Bool
    var lineageGate: Bool
    var lineageKeys: [String]
    var reason: String

    var passed: Bool { crossDomainGate && timeGate && anchorGate && lineageGate }

    static func build(from records: [HoloMemoryRecord]) -> [AIMemoryLabCrossDomainAudit] {
        let eligible = Array(records.filter {
            $0.scope == .domain && [.candidate, .active].contains($0.state)
        }.prefix(16))
        var result: [AIMemoryLabCrossDomainAudit] = []
        for leftIndex in eligible.indices {
            for rightIndex in eligible.indices where rightIndex > leftIndex {
                let left = eligible[leftIndex]
                let right = eligible[rightIndex]
                let crossDomain = left.primaryDomain != right.primaryDomain
                let time = hasCommonWindow(left, right)
                let leftAnchors = Set(left.anchorRefs.map(\.stableKey))
                let rightAnchors = Set(right.anchorRefs.map(\.stableKey))
                let anchor = !leftAnchors.isDisjoint(with: rightAnchors)
                let evidence = HoloEvidenceLineageResolver.independentEvidence(from: [left, right])
                let lineage = evidence.count >= 2 && Set(evidence.map(\.sourceDomain)).count >= 2
                let reason: String
                if !crossDomain { reason = "未通过：两个记忆属于同一领域" }
                else if !time { reason = "未通过：有效时间没有重叠" }
                else if !anchor { reason = "未通过：没有共同 canonical anchor" }
                else if !lineage { reason = "未通过：独立底层证据不足或来自同一领域" }
                else { reason = "四道门通过，可进入融合候选" }
                result.append(AIMemoryLabCrossDomainAudit(
                    id: "\(left.id)|\(right.id)",
                    title: "\(left.primaryDomain?.rawValue ?? "?") × \(right.primaryDomain?.rawValue ?? "?")",
                    crossDomainGate: crossDomain,
                    timeGate: time,
                    anchorGate: anchor,
                    lineageGate: lineage,
                    lineageKeys: evidence.map(\.lineageKey),
                    reason: reason
                ))
            }
        }
        return result.sorted {
            if $0.passed != $1.passed { return $0.passed && !$1.passed }
            return $0.id < $1.id
        }
    }

    private static func hasCommonWindow(_ lhs: HoloMemoryRecord, _ rhs: HoloMemoryRecord) -> Bool {
        guard let lhsStart = lhs.validFrom, let lhsEnd = lhs.validTo,
              let rhsStart = rhs.validFrom, let rhsEnd = rhs.validTo else { return false }
        return max(lhsStart, rhsStart) <= min(lhsEnd, rhsEnd)
    }
}

private struct AIMemoryLabRecordInspectorView: View {
    let record: HoloMemoryRecord
    let tombstoneHit: Bool
    @State private var revealSensitiveSummary = false

    var body: some View {
        List {
            Section("身份与版本") {
                debugRow("stable ID", record.id)
                debugRow("version", "v\(record.recordVersion)")
                debugRow("predecessor", record.predecessorVersionID ?? "—")
                debugRow("state", record.state.rawValue)
                debugRow("user decision", record.userDecision.rawValue)
                debugRow("tombstone hit", tombstoneHit ? "YES" : "NO")
            }

            Section("评分明细（仅 Debug）") {
                debugRow("confidence", String(format: "%.3f", record.confidenceScore))
                debugRow("freshness", String(format: "%.3f", record.freshnessScore))
                debugRow("scoring version", "\(record.scoringVersion)")
                debugRow("extractor/prompt", "\(record.extractorVersion)/\(record.promptVersion)")
            }

            Section("Anchors") {
                ForEach(record.anchorRefs, id: \.stableKey) { anchor in
                    debugRow(anchor.type.rawValue, anchor.stableKey)
                }
            }

            Section("Evidence metadata") {
                Toggle("临时显示 evidence 摘要", isOn: $revealSensitiveSummary)
                ForEach(record.evidenceRefs) { evidence in
                    VStack(alignment: .leading, spacing: 4) {
                        debugRow("id", evidence.id)
                        debugRow("lineage", evidence.lineageKey)
                        debugRow("revision", evidence.revisionDigest)
                        if revealSensitiveSummary {
                            Text(evidence.summary ?? "[无摘要]")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Section("Counter evidence") {
                if record.counterEvidenceRefs.isEmpty {
                    Text("无")
                } else {
                    ForEach(record.counterEvidenceRefs) { evidence in
                        debugRow(evidence.id, evidence.lineageKey)
                    }
                }
            }
        }
        .navigationTitle("记录检查")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
#endif
