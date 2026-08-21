//
//  AgentDeepAnalysisCard.swift
//  Holo
//
//  Agent 深度分析结果的紧凑入口卡片（四态：loading / loaded / unloaded / degrade）
//  复用 ChatCardView / CardHeaderView / HoloAIHeroMetric / CardButtonStyle
//

import SwiftUI

/// 结果卡「换范围」快捷档。窗口算法与 HoloAgentTimeSemanticResolver 的 L2 规则保持一致，
/// 但作为 userOverride 显式注入（绕开文本解析层），确定性 100%。
enum AgentScopeChangePreset: String, CaseIterable, Identifiable {
    case last30Days
    case last3Months
    case last6Months
    case last1Year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last30Days: return "近30天"
        case .last3Months: return "近3个月"
        case .last6Months: return "近半年"
        case .last1Year: return "近1年"
        }
    }

    /// 用户可见的换范围话术（会被 FollowUpRouter 识别为 .changeScope 追问）
    var followUpText: String {
        switch self {
        case .last30Days: return "换成最近30天再看"
        case .last3Months: return "换成近三个月再看"
        case .last6Months: return "换成近半年再看"
        case .last1Year: return "换成近一年再看"
        }
    }

    func timeRange(asOf reference: Date = Date(), calendar inputCalendar: Calendar = .current) -> HoloAgentTimeRange {
        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "zh_CN")
        let today = calendar.startOfDay(for: reference)
        let start: Date?
        switch self {
        case .last30Days:
            start = calendar.date(byAdding: .day, value: -29, to: today)
        case .last3Months:
            start = calendar.date(byAdding: .month, value: -3, to: today)
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        case .last6Months:
            start = calendar.date(byAdding: .month, value: -6, to: today)
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        case .last1Year:
            start = calendar.date(byAdding: .year, value: -1, to: today)
                .flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return HoloAgentTimeRange(label: label, start: start, end: end)
    }
}

struct AgentDeepAnalysisCard: View {

    let message: ChatMessageViewData
    var onTap: (() -> Void)? = nil
    /// 换范围重查回调；nil 时 scope 行退化为纯展示（详情页等场景）。
    var onScopeChange: ((AgentScopeChangePreset) -> Void)? = nil
    /// 暂停态「立即继续」回调；nil 时按钮不显示（详情页等场景）。
    var onResumePaused: (() -> Void)? = nil

    var body: some View {
        if message.isStreaming {
            // 分析中：loading 卡片
            loadingCard
        } else if message.metadataState == .loaded, let result = message.agentResult {
            // 已加载且有结果：真实卡片
            realCard(result: result)
        } else if message.metadataState == .unloaded || message.metadataState == .loading {            // 元数据加载中：占位
            placeholderCard
        }
        // .loaded 但 agentResult == nil → 不渲染（退化文本气泡，由 MessageBubbleView 处理）
    }

    // MARK: - Scope Row

    /// 「已存入报告」回执：报告档案的入口回链。点按经路由切到报告 Tab。
    /// 用 Menu 而非嵌套 Button——这是本卡内已验证的子级交互模式（与「换范围」一致）。
    private var archivedReceiptMenu: some View {
        Menu {
            Button("在「报告」中查看") {
                ChatReportTabRouter.shared.openReportTab()
            }
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("已存入报告")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(Color.holoPrimary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.holoPrimary.opacity(0.08))
            .clipShape(Capsule())
        }
        .accessibilityLabel("已存入报告，打开报告档案")
        .accessibilityHint("切换到 Holo AI 页的报告 Tab 查看全部报告")
    }

    /// 查询范围行：展示「范围 · 起止日期 · 来源」并支持一键换档重查。
    /// Menu 嵌在外层 Button 内：Menu 的弹出优先于卡片整击（进详情），互不干扰。
    @ViewBuilder
    private func scopeRow(_ result: HoloRenderedAgentResult) -> some View {
        if let scopeText = result.scope?.displayLabel {
            if let onScopeChange, result.agentJobID != nil, result.agentResultID != nil {
                Menu {
                    ForEach(AgentScopeChangePreset.allCases) { preset in
                        Button(preset.label) {
                            onScopeChange(preset)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Label(scopeText, systemImage: "calendar")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.holoTextSecondary.opacity(0.7))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.holoPrimary.opacity(0.05))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .accessibilityLabel("查询范围 \(scopeText)，点按可换时间范围重新分析")
            } else {
                Label(scopeText, systemImage: "calendar")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
    }

    // MARK: - Real Card

    private func realCard(result: HoloRenderedAgentResult) -> some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                if result.sections.isEmpty && result.recommendations?.isEmpty != false {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color.holoPrimary.opacity(0.10))
                                .frame(width: 48, height: 48)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.holoPrimary.opacity(0.72))
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(result.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.holoTextPrimary)
                            Text(cardEmptySubtitle(for: result.emptyReason))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.holoTextSecondary)
                            if let context = result.contextSourceText {
                                Text("本次读取：\(context)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.holoTextSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.holoPrimary)
                                .frame(width: 30, height: 30)
                                .background(Color.holoPrimary.opacity(0.11))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.headline ?? result.title)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.holoTextPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                Text(result.continuationMetadata?.isFollowUp == true
                                    ? result.continuationMetadata?.shortLabel ?? "继续追问"
                                    : (hasRecommendations(result) ? "优化建议" : "深度分析"))
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.holoPrimary.opacity(0.8))
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.holoPrimary.opacity(0.075))
                                    .clipShape(Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        }

                        if let keyInsight = result.keyInsight?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !keyInsight.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.holoPrimary.opacity(0.55))
                                    .frame(width: 3)
                                Text(keyInsight)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundColor(.holoPrimary.opacity(0.95))
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityLabel("核心发现")
                        }

                        HStack {
                            scopeRow(result)
                            Spacer(minLength: 8)
                            archivedReceiptMenu
                        }

                        if let context = result.contextSourceText {
                            Label("本次读取：\(context)", systemImage: "brain.head.profile")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }

                        Text(directAnswer(result))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundColor(.holoTextPrimary.opacity(0.88))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)

                        let titles = recommendationTitles(in: result)
                        if !titles.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(Array(titles.prefix(2).enumerated()), id: \.offset) { index, title in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .frame(width: 19, height: 19)
                                            .background(Color.holoPrimary)
                                            .clipShape(Circle())
                                        Text(title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.holoTextPrimary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }

                        if let coverage = result.coverageText, !coverage.isEmpty {
                            Label(coverage, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .lineLimit(2)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(result.continuationMetadata?.isFollowUp == true ? "查看完整追问" : "查看完整分析")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        let status = HoloAgentChatStatusPresenter.display(from: message.content)
        // 暂停态（无转圈、进度已保存）：放开交互让「立即继续」可点；执行中保持整卡不可点。
        let isPaused = !status.showsActivityIndicator
        return ChatCardView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if status.showsActivityIndicator {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.holoTextSecondary)
                    }
                    Text(status.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                Text(status.detail)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)

                if isPaused, let onResumePaused {
                    Button {
                        onResumePaused()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("立即继续")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel("立即继续暂停的深度分析")
                }
            }
        }
        .allowsHitTesting(isPaused)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        ChatCardView {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    /// 卡片空状态副标题：简短区分两种空原因（详细文案见详情页）。
    private func cardEmptySubtitle(for reason: HoloAgentEmptyReason?) -> String {
        switch reason {
        case .unverifiable?:
            return "有数据，但结论未通过核验"
        case .noData?, nil:
            return "这次没有形成可信结论"
        }
    }

    private func primarySummary(_ result: HoloRenderedAgentResult) -> String {
        let count = result.sections.count
        if result.summary.isEmpty {
            return count > 0 ? "共 \(count) 条观察" : "这次没有形成可信结论"
        }
        return result.summary
    }

    private func directAnswer(_ result: HoloRenderedAgentResult) -> String {
        if let answer = result.directAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !answer.isEmpty {
            return answer
        }
        if let first = result.sections.first?.body.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty {
            return first
        }
        return primarySummary(result)
    }

    private func hasRecommendations(_ result: HoloRenderedAgentResult) -> Bool {
        !recommendationTitles(in: result).isEmpty
    }

    private func recommendationTitles(in result: HoloRenderedAgentResult) -> [String] {
        if let recommendations = result.recommendations, !recommendations.isEmpty {
            return recommendations.map(\.title)
        }
        return result.sections.compactMap { section in
            let kind = section.kind?.lowercased() ?? ""
            return ["suggestion", "recommendation", "action"].contains(kind)
                ? section.title
                : nil
        }
    }
}
