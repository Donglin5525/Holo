//
//  AgentDeepReportView.swift
//  Holo
//
//  v27 研报式报告版式（方案 docs/finance/plans/2026-10-17-HoloAI深度洞察升级与财务试评/
//  card-designs/e-report-v3.html 的 SwiftUI 落地）：
//  图文分工——图负责精确数据（HoloReportTrendDataResolver 本地核算 + 标准图表组件），
//  文字负责解读（章节/节导语来自云端 reportStructure，段落正文=已核验 claim）。
//  报告头/导语/编号章节/重要事项提示/结论条目/数据说明；旧结果无 reportStructure
//  时详情页回退原版式（双轨兼容）。
//

import SwiftUI

struct AgentDeepReportView: View {
    let result: HoloRenderedAgentResult
    let report: HoloRenderedReportStructure
    var scopeLabel: String?

    @Environment(\.colorScheme) private var colorScheme
    @State private var trendSeriesByDataset: [String: HoloReportTrendSeries] = [:]

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            titleBlock
            if let lede = result.narrativeSummary, !lede.isEmpty {
                ledeBlock(lede)
            }
            ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
            if !report.conclusionItems.isEmpty {
                conclusionSection
            }
            if !report.disclosureNotes.isEmpty {
                disclosureBlock
            }
        }
        .task { await loadCharts() }
    }

    // MARK: - 报告头

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOLO 深度洞察")
                .font(.system(size: 12.5, weight: .bold))
                .tracking(2.5)
                .foregroundColor(.holoPrimary)
            Text(scopeLabel ?? "")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
            Rectangle()
                .fill(dark ? Color.white : Color.black)
                .frame(height: 2.5)
        }
    }

    private var titleBlock: some View {
        Text(result.title)
            .font(.system(size: 25, weight: .bold))
            .foregroundColor(dark ? .white : .holoTextPrimary)
            .lineSpacing(4)
            .padding(.top, 26)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func ledeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundColor(dark ? .white.opacity(0.92) : .holoTextPrimary)
            .lineSpacing(6)
            .padding(15)
            .background(Color.holoBackground.opacity(dark ? 0.55 : 1))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.holoPrimary).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 22)
    }

    // MARK: - 章节

    private func sectionView(_ section: HoloRenderedReportStructure.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                if !section.no.isEmpty {
                    Text(section.no)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .tracking(1)
                }
                Text(section.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(dark ? .white : .holoTextPrimary)
            }
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.holoTextSecondary.opacity(0.18)).frame(height: 1)
            }
            .padding(.top, 46)

            if let kicker = section.kicker, !kicker.isEmpty {
                Text(kicker)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoPrimary.opacity(0.95))
                    .lineSpacing(5)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(Self.boldLeadSentence(paragraph))
                    .font(.system(size: 15.5))
                    .foregroundColor(dark ? .white.opacity(0.9) : .holoTextPrimary.opacity(0.92))
                    .lineSpacing(8)
                    .padding(.top, 16)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let chart = section.chartHint, let series = trendSeriesByDataset[chart.dataset] {
                VStack(alignment: .leading, spacing: 0) {
                    ReportTrendChart(series: series)
                    Text(chart.caption)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
                .padding(.top, 22)
            }

            if let body = section.noticeBody {
                noticeBlock(body, window: section.noticeWindow)
            }
        }
    }

    private func noticeBlock(_ body: String, window: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("重要事项提示")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.5)
                .foregroundColor(.holoPrimary)
            Text(body)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(dark ? .white : .holoTextPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if let window, !window.isEmpty {
                Text(window)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(14)
        .background(Color.holoPrimary.opacity(dark ? 0.10 : 0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.32), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 20)
    }

    // MARK: - 结论

    private var conclusionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(no: conclusionNo, title: "结论与建议")
            ForEach(Array(report.conclusionItems.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(Color.holoPrimary, lineWidth: 1.2)
                            .frame(width: 18, height: 18)
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.holoPrimary)
                    }
                    .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.text)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(dark ? .white : .holoTextPrimary)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !item.sub.isEmpty {
                            Text(item.sub)
                                .font(.system(size: 13))
                                .foregroundColor(.holoTextSecondary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 18)
            }
        }
    }

    /// 结论节编号：接续正文最后一节递增（正文到「三」，结论为「四」）。
    private var conclusionNo: String {
        let order = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        let last = report.sections.compactMap(\.no).filter { !$0.isEmpty }.last
        guard let last, let i = order.firstIndex(of: last), i + 1 < order.count else { return "一" }
        return order[i + 1]
    }

    // MARK: - 数据说明

    private var disclosureBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("数 据 说 明")
                .font(.system(size: 12, weight: .bold))
                .tracking(2)
                .foregroundColor(.holoTextSecondary)
                .padding(.top, 44)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.holoTextSecondary.opacity(0.18)).frame(height: 1)
                }
            ForEach(report.disclosureNotes, id: \.self) { note in
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(4)
                    .padding(.top, 9)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 图表数据（本地核算，模型只表态）

    private func loadCharts() async {
        guard let scope = result.scope, let start = scope.start, let end = scope.end, end > start else { return }
        var loaded: [String: HoloReportTrendSeries] = [:]
        for section in report.sections {
            guard let chart = section.chartHint, chart.kind == "trend",
                  loaded[chart.dataset] == nil,
                  HoloReportTrendDataResolver.isSupported(dataset: chart.dataset),
                  let series = await HoloReportTrendDataResolver.resolve(dataset: chart.dataset, start: start, end: end)
            else { continue }
            loaded[chart.dataset] = series
        }
        trendSeriesByDataset = loaded
    }

    /// 首句加粗（新闻编辑扫读手法）：到第一个句末标点为止的子串用 heavier 字重。
    static func boldLeadSentence(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .system(size: 15.5)
        let terminators: Set<Character> = ["。", "！", "？", "；"]
        guard let idx = text.firstIndex(where: { terminators.contains($0) }) else {
            attr.font = .system(size: 15.5, weight: .semibold)
            return attr
        }
        let leadLength = text.distance(from: text.startIndex, to: idx) + 1
        guard leadLength < text.count else {
            attr.font = .system(size: 15.5, weight: .semibold)
            return attr
        }
        let leadRange = attr.startIndex..<attr.index(attr.startIndex, offsetByCharacters: leadLength)
        attr[leadRange].font = .system(size: 15.5, weight: .semibold)
        return attr
    }

    private func sectionHeader(no: String, title: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(no)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.holoPrimary)
                .tracking(1)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(dark ? .white : .holoTextPrimary)
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.holoTextSecondary.opacity(0.18)).frame(height: 1)
        }
        .padding(.top, 46)
    }
}
