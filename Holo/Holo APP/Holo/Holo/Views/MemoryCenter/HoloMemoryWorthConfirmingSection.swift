//
//  HoloMemoryWorthConfirmingSection.swift
//  Holo
//
//  「值得确认」分段（减法版原型 ②；方案 v2.2 §5）：
//  一次最多 3 条，可主动查看全部成熟候选；不展示后台半成品数量、
//  不做红点/推送/每日清空任务。
//  卡片减法：统计表 8 个数字 → 一句人话（完整数据点卡片展开「看数据」）；
//  4 个等权按钮 → 「对，记住」主按钮 + 「不对」+「···」（修改/暂不处理收进菜单）。
//

import SwiftUI

struct HoloMemoryWorthConfirmingSection: View {
    @ObservedObject var viewModel: HoloMemoryCenterViewModel

    @State private var correctingKnowledge: HoloResolvedKnowledge?
    @State private var correctionText = ""
    @State private var inaccurateKnowledge: HoloResolvedKnowledge?

    var body: some View {
        let items = viewModel.showsAllWorthConfirming
            ? viewModel.worthConfirming
            : viewModel.recommendedWorthConfirming
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .padding(.top, 2)
                (
                    Text("Holo 从你的记录里看到的规律，")
                        .foregroundStyle(Color.holoToolTextSecondary)
                    + Text("确认后才会在相关帮助里使用")
                        .foregroundStyle(Color.holoToolText)
                    + Text("。")
                        .foregroundStyle(Color.holoToolTextSecondary)
                )
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 12))

            if viewModel.hasMoreWorthConfirming || viewModel.showsAllWorthConfirming {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(HoloAnimation.standard) {
                            viewModel.showsAllWorthConfirming.toggle()
                        }
                    } label: {
                        Text(viewModel.showsAllWorthConfirming ? "只看推荐" : "查看全部")
                            .holoText(.supporting)
                            .foregroundStyle(Color.holoToolAction)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memoryCenter.worthConfirming.toggleAll")
                }
            }

            if items.isEmpty {
                Text("眼下没有值得确认的规律。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.8))
                    .padding(.top, 10)
            } else {
                ForEach(items) { knowledge in
                    HoloMemoryWorthConfirmingCard(
                        knowledge: knowledge,
                        onConfirm: { Task { await viewModel.performKnowledge(.confirm, on: knowledge) } },
                        onCorrect: {
                            correctionText = knowledge.displayText
                            correctingKnowledge = knowledge
                        },
                        onInaccurate: { inaccurateKnowledge = knowledge },
                        onDefer: { Task { await viewModel.performKnowledge(.deferCooldown, on: knowledge) } }
                    )
                }
                Text("为什么这么说？点卡片可看完整依据")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memoryCenter.worthConfirming")
        .sheet(item: $correctingKnowledge) { knowledge in
            HoloMemoryKnowledgeCorrectionSheet(
                original: knowledge.displayText,
                text: $correctionText,
                onSave: {
                    let statement = correctionText
                    correctingKnowledge = nil
                    Task { await viewModel.performKnowledge(.correct(statement: statement), on: knowledge) }
                },
                onCancel: { correctingKnowledge = nil }
            )
        }
        .sheet(item: $inaccurateKnowledge) { knowledge in
            HoloMemoryInaccurateFeedbackSheet(
                onCancel: { inaccurateKnowledge = nil },
                onSubmit: { reason, scope in
                    inaccurateKnowledge = nil
                    Task {
                        await viewModel.performKnowledge(
                            .markInaccurate(reason: reason, scope: scope),
                            on: knowledge
                        )
                    }
                }
            )
        }
    }
}

/// 单条候选卡（减法原型 ②）：一句陈述 + 一句人话统计 + 主按钮「对，记住」+
/// 「不对」（弹「哪里不对？」）+「···」（修改/暂不处理）。点陈述区展开完整数据。
struct HoloMemoryWorthConfirmingCard: View {
    let knowledge: HoloResolvedKnowledge
    let onConfirm: () -> Void
    let onCorrect: () -> Void
    let onInaccurate: () -> Void
    let onDefer: () -> Void

    @State private var showsFullEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(HoloAnimation.standard) { showsFullEvidence.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 4) {
                        Text(knowledge.displayText)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.holoToolText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: showsFullEvidence ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                            .padding(.top, 3)
                    }
                    Text(statsSentence)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsFullEvidence {
                        HoloMemoryEvidenceStatsList(
                            data: knowledge.latestEvidenceSnapshot.map(HoloMemoryEvidenceStatsData.init(snapshot:))
                        )
                        .padding(.top, 5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memoryCenter.worthConfirming.text")

            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    Text("对，记住")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolOnAction)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.holoToolAction, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .accessibilityIdentifier("memoryCenter.worthConfirming.confirm")

                Button(action: onInaccurate) {
                    Text("不对")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .frame(width: 76, height: 44)
                        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: HoloRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
                }
                .accessibilityIdentifier("memoryCenter.worthConfirming.inaccurate")

                Menu {
                    Button("修改") { onCorrect() }
                    Button("暂不处理") { onDefer() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多操作")
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }

    // MARK: 一句人话统计（原型 ②：42 次里 30 次式的翻译；不堆 8 个数字）

    private var statsSentence: String {
        guard let snapshot = knowledge.latestEvidenceSnapshot else {
            return "依据已记录，点开可看完整依据。"
        }
        var sentence = ""
        let count = snapshot.independentEventCount
        if let windowText = Self.windowText(snapshot) {
            sentence = count > 0
                ? "看了\(windowText)的 \(count) 条记录"
                : "看了\(windowText)的记录"
        } else if count > 0 {
            sentence = "看了 \(count) 条记录"
        } else {
            sentence = "看了你的相关记录"
        }
        if let coverage = snapshot.coveragePercent {
            sentence += "，约 \(Int((coverage * 100).rounded()))% 的情况相符"
        }
        if !snapshot.counterRefs.isEmpty {
            sentence += "，也有 \(snapshot.counterRefs.count) 次例外"
        } else if snapshot.counterexampleSearch == .searchedNoneFound {
            sentence += "，没找到反例"
        }
        return sentence + "。"
    }

    /// 观察窗 → 「最近 N 周」；窗口不可得时返回 nil。
    static func windowText(_ snapshot: HoloKnowledgeEvidenceSnapshot) -> String? {
        guard let from = snapshot.observationWindowFrom,
              let to = snapshot.observationWindowTo,
              to > from else { return nil }
        let weeks = max(1, Int((to.timeIntervalSince(from) / 86_400 / 7).rounded()))
        return "最近 \(weeks) 周"
    }
}

/// 完整数据卡（「看数据」展开态，原型 ④）：窗口、记录数、覆盖、例外、
/// 反例检索、组成记录清单；数据字段全部保留，不删数据只收层级。
/// 知识层（值得确认卡）与记录层（详情页规律型）共用同一展示。
struct HoloMemoryEvidenceStatsData {
    var windowFrom: Date?
    var windowTo: Date?
    var eventCount: Int
    var coveragePercent: Double?
    var counterCount: Int
    var counterexampleSearch: HoloKnowledgeCounterexampleSearchStatus?
    var supportRefs: [HoloMemoryEvidenceRef]

    init(snapshot: HoloKnowledgeEvidenceSnapshot) {
        windowFrom = snapshot.observationWindowFrom
        windowTo = snapshot.observationWindowTo
        eventCount = snapshot.independentEventCount
        coveragePercent = snapshot.coveragePercent
        counterCount = snapshot.counterRefs.count
        counterexampleSearch = snapshot.counterexampleSearch
        supportRefs = snapshot.supportRefs
    }

    /// 规律型记录：从汇总证据与反例证据取数（sampleCount 无则用组成记录数）。
    init(record: HoloMemoryRecord) {
        let aggregate = record.evidenceRefs.first { $0.kind == .aggregateSnapshot }
        windowFrom = aggregate?.validFrom
        windowTo = aggregate?.validTo
        eventCount = aggregate?.sampleCount ?? record.evidenceRefs.filter { $0.kind != .aggregateSnapshot }.count
        coveragePercent = nil
        counterCount = record.counterEvidenceRefs.count
        counterexampleSearch = nil
        supportRefs = record.evidenceRefs.filter { $0.kind != .aggregateSnapshot }
    }
}

struct HoloMemoryEvidenceStatsList: View {
    let data: HoloMemoryEvidenceStatsData?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data {
                statRow("观察窗口", windowRangeText(data))
                statRow("记录条数", data.eventCount > 0 ? "\(data.eventCount) 条独立记录" : "已记录")
                if let coverage = data.coveragePercent {
                    statRow("覆盖率", "\(Int((coverage * 100).rounded()))%")
                }
                statRow("例外", data.counterCount > 0 ? "\(data.counterCount) 次" : "无")
                if let search = data.counterexampleSearch {
                    statRow("反例检索", counterexampleText(search))
                }
                if !data.supportRefs.isEmpty {
                    statRow("组成记录", "")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(data.supportRefs.prefix(5)) { ref in
                            Text("· \(HoloMemoryCenterViewModel.domainTitle(ref.sourceDomain))记录 · \(HoloMemorySourceLine.shortDate(ref.observedAt))")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if data.supportRefs.count > 5 {
                            Text("等 \(data.supportRefs.count) 条")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.holoToolTextSecondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            } else {
                Text("暂无完整数据。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolInset, in: RoundedRectangle(cornerRadius: 10))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.holoToolText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func windowRangeText(_ data: HoloMemoryEvidenceStatsData) -> String {
        switch (data.windowFrom, data.windowTo) {
        case let (from?, to?):
            return "\(HoloMemorySourceLine.shortDate(from)) – \(HoloMemorySourceLine.shortDate(to))"
        case let (from?, nil):
            return "\(HoloMemorySourceLine.shortDate(from)) 起"
        case let (nil, to?):
            return "至 \(HoloMemorySourceLine.shortDate(to))"
        default:
            return "已记录的内容"
        }
    }

    private func counterexampleText(_ status: HoloKnowledgeCounterexampleSearchStatus) -> String {
        switch status {
        case .notSearched: return "未检索"
        case .searchedNoneFound: return "已检索，未见反例"
        case .searchedFound: return "已检索，存在反例"
        }
    }
}

/// 「已记住 · 你确认的理解」行（知识层确认条目：规律确认/发现保存）。
/// 两行式与记录行同宽：一句陈述 + 一句来源灰字；点陈述区展开完整依据。
struct HoloMemoryConfirmedKnowledgeRow: View {
    let knowledge: HoloResolvedKnowledge

    @State private var showsFullEvidence = false

    var body: some View {
        Button {
            withAnimation(HoloAnimation.standard) { showsFullEvidence.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolAction.opacity(0.85))
                        .padding(.top, 3)
                    Text(knowledge.displayText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.holoToolText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: showsFullEvidence ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.holoToolTextSecondary.opacity(0.6))
                        .padding(.top, 3)
                    Spacer(minLength: 0)
                }
                Text("\(knowledge.formationLabel) · 相关回答会参考")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                if showsFullEvidence {
                    HoloMemoryEvidenceStatsList(
                        data: knowledge.latestEvidenceSnapshot.map(HoloMemoryEvidenceStatsData.init(snapshot:))
                    )
                    .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoloSpacing.md)
            .holoSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memoryCenter.confirmedKnowledge.row")
    }
}

/// 「修改」：用户新陈述成为独立来源的修订（不制造行为次数）。
struct HoloMemoryKnowledgeCorrectionSheet: View {
    let original: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HoloSheetScaffold(
            title: "改一下这条理解",
            onClose: onCancel,
            primaryTitle: "保存",
            primaryAction: onSave,
            primaryDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                Text("Holo 的理解")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Text(original)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("你的说法")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .padding(HoloSpacing.sm)
                    .holoSurface()
                    .accessibilityIdentifier("memoryCenter.worthConfirming.correctionEditor")
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.vertical, HoloSpacing.md)
        }
        .presentationDetents([.medium, .large])
    }
}
