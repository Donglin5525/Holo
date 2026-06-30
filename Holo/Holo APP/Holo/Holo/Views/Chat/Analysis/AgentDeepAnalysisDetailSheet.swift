//
//  AgentDeepAnalysisDetailSheet.swift
//  Holo
//
//  Agent 深度分析详情 Sheet：纯叙事观察手记布局。
//

import SwiftUI

nonisolated struct AgentDeepAnalysisNarrativeModel: Equatable, Sendable {
    struct Observation: Equatable, Sendable {
        var label: String
        var title: String
        var body: String
        var accentIndex: Int
    }

    struct Evidence: Equatable, Sendable {
        var label: String
        var summary: String
        var drilldown: HoloRenderedFinanceDrilldown?
    }

    var openingTitle: String
    var openingBody: String
    var openingParagraphs: [String]
    var signalSummaries: [String]
    var observations: [Observation]
    var evidence: [Evidence]
    var closingTitle: String
    var closingBody: String
    var isFinanceLedgerMode: Bool

    init(result: HoloRenderedAgentResult) {
        let summary = Self.clean(result.summary)
        let resolvedSummary = summary.isEmpty ? "本期暂无显著观察" : summary
        let hasContent = !summary.isEmpty || !result.sections.isEmpty
        let isFinanceLedgerMode = result.evidenceReferences.contains { $0.financeDrilldown != nil }

        if isFinanceLedgerMode {
            self.openingTitle = "本月这笔钱，先按账单口径拆开看。"
        } else {
            self.openingTitle = hasContent
                ? "这段时间，有几个信号值得回看。"
                : "本期暂无显著观察"
        }
        self.openingBody = resolvedSummary
        self.openingParagraphs = Self.readingParagraphs(from: resolvedSummary)
        self.signalSummaries = isFinanceLedgerMode ? [] : Self.signalSummaries(from: resolvedSummary)
        self.observations = Self.observations(from: result.sections)
        self.evidence = result.evidenceReferences.enumerated().map { index, ref in
            let labelPrefix = isFinanceLedgerMode ? "账单依据" : "依据"
            return Evidence(
                label: ref.financeDrilldown == nil ? "\(labelPrefix) \(Self.twoDigit(index + 1))" : "\(labelPrefix) \(Self.twoDigit(index + 1)) · 点按核对",
                summary: Self.clean(ref.summary),
                drilldown: ref.financeDrilldown
            )
        }
        if isFinanceLedgerMode {
            self.closingTitle = "先核对最大头的去向。"
            self.closingBody = "从金额最高的分类和大额记录开始核对；如果某类不对，可以点开依据回到明细。"
        } else {
            self.closingTitle = hasContent
                ? "先从最容易稳定的一件事开始。"
                : "继续记录后，Holo 会再帮你回看。"
            self.closingBody = hasContent
                ? "不用同时盯住所有指标。Holo 会继续观察这些信号是否重新回到稳定节奏。"
                : "当睡眠、习惯、消费或任务出现更清晰的变化时，这里会整理成更完整的观察手记。"
        }
        self.isFinanceLedgerMode = isFinanceLedgerMode
    }

    private static func observations(from sections: [HoloRenderedAgentSection]) -> [Observation] {
        let items = sections.enumerated().map { index, section in
            let rawTitle = clean(section.title)
            let body = clean(section.body)
            let title = displayTitle(rawTitle)
            let label = observationLabel(index: index, rawTitle: rawTitle)
            return Observation(
                label: label,
                title: title,
                body: body.isEmpty ? "暂无更多说明" : body,
                accentIndex: index
            )
        }

        if items.isEmpty {
            return [
                Observation(
                    label: "观察 01",
                    title: "本期暂无显著观察",
                    body: "继续记录后，Holo 会在这里整理值得回看的变化。",
                    accentIndex: 0
                )
            ]
        }
        return items
    }

    private static func signalSummaries(from summary: String) -> [String] {
        let separators = Set("，,；;。.!！?？\n")
        let parts = summary
            .split { separators.contains($0) }
            .map { cleanSignalSummary(String($0)) }
            .filter { !$0.isEmpty }
            .prefix(3)

        let result = Array(parts)
        if result == ["本期暂无显著观察"] {
            return ["暂无显著观察"]
        }
        return result.isEmpty ? ["暂无显著观察"] : result
    }

    private static func readingParagraphs(from summary: String) -> [String] {
        let primarySeparators = Set("；;。.!！?？\n")
        let primaryParts = summary
            .split { primarySeparators.contains($0) }
            .map { cleanParagraph(String($0)) }
            .filter { !$0.isEmpty }
        if primaryParts.count > 1 {
            return primaryParts
        }

        let fallbackSeparators = Set("，,")
        let fallbackParts = summary
            .split { fallbackSeparators.contains($0) }
            .map { cleanParagraph(String($0)) }
            .filter { !$0.isEmpty }
        let fallbackSummary = cleanParagraph(summary)
        return fallbackParts.isEmpty ? [fallbackSummary] : fallbackParts
    }

    private static func observationLabel(index: Int, rawTitle: String) -> String {
        let base = "观察 \(twoDigit(index + 1))"
        guard !rawTitle.isEmpty, !isGenericObservationTitle(rawTitle), rawTitle.count <= 8 else {
            return base
        }
        return "\(base) · \(rawTitle)"
    }

    private static func displayTitle(_ rawTitle: String) -> String {
        guard !rawTitle.isEmpty, !isGenericObservationTitle(rawTitle) else {
            return "值得留意的变化"
        }
        return rawTitle
    }

    private static func isGenericObservationTitle(_ title: String) -> Bool {
        let normalized = title
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard normalized.hasPrefix("观察") else { return false }
        let suffix = normalized.dropFirst("观察".count)
        return suffix.isEmpty || suffix.allSatisfy { $0.isNumber }
    }

    private static func twoDigit(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanParagraph(_ text: String) -> String {
        var cleaned = clean(text)
        let trailingPunctuation = Set("，,；;。.!！?？")
        while let last = cleaned.last, trailingPunctuation.contains(last) {
            cleaned.removeLast()
        }
        return clean(cleaned)
    }

    private static func cleanSignalSummary(_ text: String) -> String {
        var cleaned = clean(text)
        let prefixes = ["近两周", "过去 14 天", "过去14天", "最近两周", "本期"]
        for prefix in prefixes where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }
        return clean(cleaned)
    }
}

struct AgentDeepAnalysisDetailSheet: View {

    let result: HoloRenderedAgentResult
    var onFinanceDrilldown: ((HoloRenderedFinanceDrilldown) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isEvidenceExpanded = false

    private var narrative: AgentDeepAnalysisNarrativeModel {
        AgentDeepAnalysisNarrativeModel(result: result)
    }

    var body: some View {
        let model = narrative
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                opening(model)
                if !model.signalSummaries.isEmpty {
                    signalStrip(model.signalSummaries)
                }
                observationsSection(model.observations)
                closingSection(model)
                evidenceSection(model.evidence)
            }
            .padding(.horizontal, 23)
            .padding(.top, 10)
            .padding(.bottom, 38)
        }
        .background(sheetBackground)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 34, height: 34)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())

                Text("深度分析")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }

            Spacer(minLength: 12)

            Text(result.title.isEmpty ? "Holo 观察" : result.title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.holoCardBackground.opacity(0.68))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
                )
        }
    }

    // MARK: - Opening

    private func opening(_ model: AgentDeepAnalysisNarrativeModel) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(model.isFinanceLedgerMode ? "HOLO 账单复核" : "HOLO 观察手记")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoPrimary)

            Text(model.openingTitle)
                .font(.system(size: 31, weight: .heavy))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(model.openingParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextPrimary.opacity(0.76))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 21)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.48))
                .frame(height: 1)
        }
    }

    private func signalStrip(_ summaries: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(summaries.enumerated()), id: \.offset) { index, summary in
                VStack(alignment: .leading, spacing: 8) {
                    Text(signalTitle(summary))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(summary)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.78), Color.holoCardBackground.opacity(0.84)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.holoBorder.opacity(index == 0 ? 0.62 : 0.42), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Observations

    private func observationsSection(_ observations: [AgentDeepAnalysisNarrativeModel.Observation]) -> some View {
        VStack(spacing: 14) {
            ForEach(Array(observations.enumerated()), id: \.offset) { _, observation in
                narrativeChapter(observation)
            }
        }
    }

    private func narrativeChapter(_ observation: AgentDeepAnalysisNarrativeModel.Observation) -> some View {
        let accent = accentColor(for: observation.accentIndex)
        return VStack(alignment: .leading, spacing: 11) {
            Text(observation.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoTextSecondary)

            Text(observation.title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(observation.body)
                .font(.system(size: 15.5, weight: .regular))
                .foregroundColor(.holoTextPrimary.opacity(0.86))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.88), Color.holoCardBackground.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent.opacity(0.62))
                .frame(width: 3)
                .padding(.vertical, 22)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.48), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 16, x: 0, y: 10)
    }

    // MARK: - Evidence

    @ViewBuilder
    private func evidenceSection(_ evidence: [AgentDeepAnalysisNarrativeModel.Evidence]) -> some View {
        if !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        isEvidenceExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("查看数据依据")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.holoTextPrimary.opacity(0.62))

                                HStack(spacing: 4) {
                                    ForEach(0..<min(evidence.count, 4), id: \.self) { _ in
                                        Circle()
                                            .fill(Color.holoPrimary.opacity(0.55))
                                            .frame(width: 5, height: 5)
                                    }
                                }
                            }

                            Text("\(evidence.count) 条可核对来源")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.holoTextSecondary.opacity(0.5))
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.holoTextSecondary.opacity(0.52))
                            .frame(width: 26, height: 26)
                            .background(Color.holoTextPrimary.opacity(0.045))
                            .clipShape(Circle())
                            .rotationEffect(.degrees(isEvidenceExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if isEvidenceExpanded {
                    VStack(spacing: 0) {
                        ForEach(Array(evidence.enumerated()), id: \.offset) { index, item in
                            if index > 0 {
                                Divider()
                                    .overlay(Color.holoBorder.opacity(0.42))
                                    .padding(.leading, 16)
                            }

                            if let drilldown = item.drilldown {
                                Button {
                                    dismiss()
                                    onFinanceDrilldown?(drilldown)
                                } label: {
                                    evidenceCard(item)
                                }
                                .buttonStyle(.plain)
                            } else {
                                evidenceCard(item)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(Color.white.opacity(0.44))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.holoBorder.opacity(0.42), lineWidth: 1)
            )
        }
    }

    private func evidenceCard(_ evidence: AgentDeepAnalysisNarrativeModel.Evidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(evidence.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.holoPrimary)

            Text(evidence.summary)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(.holoTextPrimary.opacity(0.78))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Closing

    private func closingSection(_ model: AgentDeepAnalysisNarrativeModel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("下一步")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(model.isFinanceLedgerMode ? Color.holoPrimary.opacity(0.82) : .white.opacity(0.58))

            Text(model.closingTitle)
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(model.isFinanceLedgerMode ? .holoTextPrimary : .white)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.closingBody)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(model.isFinanceLedgerMode ? Color.holoTextPrimary.opacity(0.72) : .white.opacity(0.78))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(closingBackground(isFinanceLedgerMode: model.isFinanceLedgerMode))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(model.isFinanceLedgerMode ? Color.holoPrimary.opacity(0.18) : Color.clear, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(model.isFinanceLedgerMode ? 0.045 : 0.16), radius: 18, x: 0, y: 12)
    }

    // MARK: - Styling Helpers

    private var sheetBackground: some View {
        ZStack {
            Color.holoBackground
            LinearGradient(
                colors: [
                    Color.white.opacity(0.58),
                    Color.holoBackground.opacity(0.2),
                    Color.holoBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func accentColor(for index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.43, green: 0.55, blue: 0.49),
            Color.holoPrimary,
            Color(red: 0.72, green: 0.52, blue: 0.38)
        ]
        return colors[index % colors.count]
    }

    private func closingBackground(isFinanceLedgerMode: Bool) -> some View {
        Group {
            if isFinanceLedgerMode {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.94),
                        Color(red: 0.91, green: 0.97, blue: 0.96).opacity(0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.14, blue: 0.12),
                        Color(red: 0.31, green: 0.25, blue: 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func signalTitle(_ summary: String) -> String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "观察" }
        let keywords = ["睡眠", "戒烟", "消费", "任务", "习惯", "收入", "支出", "步数", "心情"]
        if let keyword = keywords.first(where: { text.contains($0) }) {
            return keyword
        }
        return "观察"
    }
}
