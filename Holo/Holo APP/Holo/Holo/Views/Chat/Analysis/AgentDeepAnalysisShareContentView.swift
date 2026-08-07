//
//  AgentDeepAnalysisShareContentView.swift
//  Holo
//
//  分享专用的深度分析「完整详情长图」内容视图。
//  复用 AgentDeepAnalysisNarrativeModel（与详情页同一套纯数据模型），
//  按详情页的叙事布局渲染：header / 开场 / 优先建议 / 观察章节 / 数据范围 / 下一步。
//  与详情页的区别：只读、无交互态（无折叠、无点击跳转、无 textSelection），
//  用于被 CardShareImageRenderer 渲染成带水印的长图分享出去。
//

import SwiftUI

struct AgentDeepAnalysisShareContentView: View {

    let result: HoloRenderedAgentResult

    private var narrative: AgentDeepAnalysisNarrativeModel {
        AgentDeepAnalysisNarrativeModel(result: result)
    }

    var body: some View {
        let model = narrative
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.isEmptyState {
                    emptyState
                } else {
                    opening(model)
                    recommendationsSection(model.recommendations)
                    observationsSection(model.observations)
                    dataContextSection(model)
                    if model.shouldShowClosing {
                        closingSection(model)
                    }
                }
            }
            .padding(.horizontal, 23)
            .padding(.top, 10)
            .padding(.bottom, 38)
        }
        .frame(width: 360)
        .background(shareBackground)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.06))
                    .frame(width: 154, height: 154)
                Circle()
                    .stroke(Color.holoPrimary.opacity(0.10), lineWidth: 1)
                    .frame(width: 112, height: 112)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundColor(.holoPrimary.opacity(0.62))
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .offset(x: 45, y: -43)
            }

            VStack(spacing: 10) {
                Text("这次没有形成可信结论")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundColor(.holoTextPrimary)
                    .multilineTextAlignment(.center)

                Text(emptyStateSubtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 46)
    }

    private var emptyStateSubtitle: String {
        switch narrative.emptyReason {
        case .unverifiable:
            return "已查到相关数据，但未能形成通过核验的可信结论。可以换个问法或扩大时间范围再试一次。"
        case .noData, nil:
            return "所选时间范围内没有足够的可用数据，暂时无法形成可信结论。请确认数据权限和记录覆盖后再试。"
        }
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

            Label("结论已核对", systemImage: "checkmark.seal.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Opening

    private func opening(_ model: AgentDeepAnalysisNarrativeModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(model.isFinanceLedgerMode ? "HOLO 账单复核" : "HOLO 数据分析")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.holoPrimary)

                if let scope = model.scopeLabel {
                    Text(scope)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.holoBackground.opacity(0.86))
                        .clipShape(Capsule())
                }
            }

            Text(model.openingTitle)
                .font(.system(size: 25, weight: .bold))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(model.openingParagraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundColor(.holoTextPrimary.opacity(0.78))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Recommendations

    @ViewBuilder
    private func recommendationsSection(
        _ recommendations: [AgentDeepAnalysisNarrativeModel.Recommendation]
    ) -> some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("优先建议")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                    Spacer()
                    Text("\(recommendations.count) 项")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                ForEach(Array(recommendations.enumerated()), id: \.offset) { index, recommendation in
                    HStack(alignment: .top, spacing: 13) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 25, height: 25)
                            .background(Color.holoPrimary)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(recommendation.title)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .layoutPriority(1)

                                if let priority = recommendation.priorityLabel {
                                    Text(priority)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.holoPrimary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.holoPrimary.opacity(0.09))
                                        .clipShape(Capsule())
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }

                            if let scope = recommendation.scopeLabel {
                                Label(scope, systemImage: "calendar")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.holoTextSecondary)
                            }

                            Text(recommendation.body)
                                .font(.system(size: 14.5, weight: .regular))
                                .foregroundColor(.holoTextPrimary.opacity(0.8))
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.holoBorder.opacity(0.55), lineWidth: 1)
                    )
                }
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
            if !observation.label.isEmpty {
                Text(observation.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.holoTextSecondary)
            }

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
        }
        .padding(.leading, 20)
        .padding(.trailing, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(observationBackground)
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

    // MARK: - Data Context

    @ViewBuilder
    private func dataContextSection(_ model: AgentDeepAnalysisNarrativeModel) -> some View {
        if model.contextSourceText != nil || model.coverageText != nil || !model.limitations.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let context = model.contextSourceText {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("个性化上下文")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.holoTextSecondary)
                            Text("本次读取：\(context)")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary.opacity(0.8))
                                .lineSpacing(4)
                        }
                    }
                }

                if let coverage = model.coverageText {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "calendar.badge.checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("数据范围")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.holoTextSecondary)
                            Text(coverage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.holoTextPrimary.opacity(0.8))
                                .lineSpacing(4)
                        }
                    }
                }

                ForEach(Array(model.limitations.enumerated()), id: \.offset) { _, limitation in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 20)
                        Text(limitation)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .lineSpacing(4)
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoPrimary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.holoPrimary.opacity(0.11), lineWidth: 1)
            )
        }
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

    /// 分享长图统一用浅色背景，保证分享出去的视觉稳定（不随系统深色模式变化）。
    private var shareBackground: some View {
        ZStack {
            Color.holoBackground
            LinearGradient(
                colors: [
                    Color.holoCardBackground.opacity(0.62),
                    Color.holoBackground.opacity(0.30),
                    Color.holoBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
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

    private var observationBackground: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.88),
                Color.holoCardBackground.opacity(0.9)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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
}
