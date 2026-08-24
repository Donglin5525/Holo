//
//  ReportArchiveCard.swift
//  Holo
//
//  报告档案行卡：深度分析 / 周期回放 两类已完成报告 + 生成中状态卡。
//  版式对齐原型：原始提问（引言）→ 结论摘要（左竖条）→ 计数与「读报告」尾行。
//

import SwiftUI

struct ReportArchiveCard: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    let entry: ReportArchiveDTO
    var onTap: () -> Void

    private var accentColor: Color {
        entry.kind == .deepAnalysis ? .holoPrimary : .indigo
    }

    var body: some View {
        ChatCardView(onTap: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    kindBadge

                    // 场景徽标（回放/其他不另显：回放类型徽标已表明，其他无场景可言）
                    if entry.scenarioTag != .replay && entry.scenarioTag != .general {
                        Text(entry.scenarioTag.label)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(entry.scenarioTag.badgeColors.foreground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(entry.scenarioTag.badgeColors.background, in: Capsule())
                    }

                    Text(entry.scopeLabel ?? "自定义范围")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    // 追问产物徽标：档案平铺里区分「根报告」与「追问出的报告」
                    if entry.isFollowUp {
                        followUpBadge
                    }

                    if entry.isFavorited {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.holoStarTint)
                            .accessibilityLabel("已收藏")
                    }

                    Text(Self.dateText(entry.timestamp))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }

                // 原始提问：先看到当时问了什么，再看 Holo 看出了什么
                if let question = entry.question {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.holoTextSecondary.opacity(0.85))
                            .padding(.top, 1.5)
                        Text(question)
                            .font(.system(size: 11.5))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(2)
                    }
                }

                if let issue = entry.issueText {
                    Text(issue)
                        .font(.system(size: 12.5))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(2)
                } else {
                    // 结论摘要：左侧彩色竖条（分析=橙 / 回放=靛），与原型一致
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(accentColor.opacity(0.55))
                            .frame(width: 3)

                        Text(entry.summary ?? entry.title ?? "本周期完成了一次报告。")
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 8) {
                    if entry.kind == .deepAnalysis {
                        Text(Self.countsText(entry))
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()

                    HStack(spacing: 2.5) {
                        Text("读报告")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var kindBadge: some View {
        Text(entry.kind == .deepAnalysis ? "深度分析" : "周期回放")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(accentColor.opacity(0.10), in: Capsule())
    }

    /// 追问徽标：这份报告是某次追问的产物（如「继续深挖」出的报告）。
    /// 双模式配色（holoFollowUpTint），深色模式下依然可读。
    private var followUpBadge: some View {
        Text("追问")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(Color.holoFollowUpTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Color.holoFollowUpTint.opacity(0.14), in: Capsule())
    }

    private static func countsText(_ entry: ReportArchiveDTO) -> String {
        var parts: [String] = []
        if entry.observationCount > 0 {
            parts.append("观察 ×\(entry.observationCount)")
        }
        if entry.evidenceCount > 0 {
            parts.append("证据 ×\(entry.evidenceCount)")
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

// MARK: - 生成中状态卡

/// 报告 Tab 列表顶部的生成中卡片。存在性由持久化消息的 streaming 状态派生
/// （冷启动可恢复）；状态文案与聊天卡同源（HoloAgentChatStatusPresenter），
/// 不另起一套、不虚构百分比。
struct ReportInProgressCard: View {
    let message: ChatMessageViewData

    var body: some View {
        let status = HoloAgentChatStatusPresenter.display(from: message.content)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if status.showsActivityIndicator {
                    ProgressView()
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }

                Text("生成中")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(red: 0.63, green: 0.38, blue: 0.03))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(Color(red: 1.0, green: 0.93, blue: 0.68), in: Capsule())

                Text(status.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("刚刚")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }

            Text(status.detail)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)

            Text("可以先切回对话继续聊，完成时「报告」会亮红点")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.holoPrimary.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.holoCardBackground, in: RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
        )
    }
}
