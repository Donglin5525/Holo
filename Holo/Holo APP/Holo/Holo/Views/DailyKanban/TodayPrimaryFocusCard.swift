//
//  TodayPrimaryFocusCard.swift
//  Holo
//
//  「今天」首屏主卡：今日判断 + 唯一主行动（今日看板 Matter 化方案 §5.1/§9.1）
//
//  - reasonCode 在本 renderer 统一本地化，不拼接/解析自然语言；
//  - loading 用等高 skeleton（200ms 内完成不闪）；
//  - calm state 不展示 0%、不喊口号；
//  - 主行动标题/按钮不因 Dynamic Type 截断（必要时纵向堆叠）。
//

import SwiftUI

struct TodayPrimaryFocusCard: View {

    let focus: HoloTodayFocus?
    let isLoading: Bool
    let inFlightAction: HoloTodayAction?
    let errorMessage: String?
    let onStart: (HoloTodayAction) -> Void
    let onPostpone: () -> Void
    /// calm 态行动出口：指向 AI 一句话记录（激活方案 §3.2；nil 则不显示）
    var onCalmQuickRecord: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                skeleton
            } else if let focus {
                focusContent(focus)
            } else {
                calmContent
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.xl)
                .fill(Color.holoCardBackground)
                .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
        )
    }

    // MARK: 有可执行行动

    @ViewBuilder
    private func focusContent(_ focus: HoloTodayFocus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(Self.headerText(for: focus))
                    .font(.caption.weight(.bold))
                    .tracking(1)
            } icon: {
                Image(systemName: focus.severity == .risk ? "exclamationmark.circle.fill" : "arrow.right.circle.fill")
                    .foregroundStyle(focus.severity == .risk ? Color.holoError : Color.holoPrimary)
            }
            .foregroundStyle(.secondary)

            Text(focus.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let matterTitle = focus.reasonArguments.matterTitle {
                Text(String(localized: "来自：\(matterTitle)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(Self.reasonText(for: focus))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 错误行（局部失败不吞整卡）。
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            actionRow(focus)
        }
    }

    /// 主行动按钮行：大字体时纵向堆叠（AX 不截断）。
    @ViewBuilder
    private func actionRow(_ focus: HoloTodayFocus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons(focus) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(focus) }
        }
    }

    @ViewBuilder
    private func actionButtons(_ focus: HoloTodayFocus) -> some View {
        let label = Self.primaryButtonTitle(for: focus)
        Button {
            onStart(focus.action)
        } label: {
            HStack(spacing: 6) {
                if inFlightAction == focus.action {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
                Text(label)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.holoPrimary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inFlightAction == focus.action)
        .accessibilityLabel(Text("\(label)，\(focus.title)"))

        // 「稍后」：仅会话内降级该候选。
        Button(action: onPostpone) {
            Text(String(localized: "稍后"))
                .font(.subheadline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(.tertiarySystemGroupedBackground))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: calm state（没有紧急事项）

    private var calmContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(String(localized: "今天没有必须立刻处理的事"))
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "leaf.circle.fill")
                    .foregroundStyle(Color.holoSuccess)
            }
            Text(String(localized: "可以按自己的节奏推进安排。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let onCalmQuickRecord {
                Button(action: onCalmQuickRecord) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles")
                        Text(String(localized: "试试对 Holo 说一句话"))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.holoPrimary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .accessibilityIdentifier("todayCalmQuickRecordButton")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: skeleton（与最终卡等高，VoiceOver 隐藏）

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 120, height: 12)
            Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 22)
            Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 14)
            Capsule().fill(Color.holoPrimary.opacity(0.12)).frame(height: 44)
        }
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }

    // MARK: 文案 renderer（reasonCode 的唯一本地化出口）

    nonisolated static func headerText(for focus: HoloTodayFocus) -> String {
        switch focus.severity {
        case .risk: return String(localized: "需要马上处理")
        case .attention: return String(localized: "现在最值得推进")
        case .normal: return String(localized: "现在最值得推进")
        }
    }

    nonisolated static func reasonText(for focus: HoloTodayFocus) -> String {
        let args = focus.reasonArguments
        switch focus.reasonCode {
        case .scheduleInProgress:
            return String(localized: "正在进行中，先照顾好这件事。")
        case .scheduleStartingSoon:
            if let minutes = args.minutesUntilStart {
                return String(localized: "\(minutes) 分钟后开始。")
            }
            return String(localized: "马上就要开始了。")
        case .overdueTask:
            if let days = args.overdueDays, days > 1 {
                return String(localized: "已经逾期 \(days) 天了，越早处理越安心。")
            }
            return String(localized: "已经过了截止时间，今天处理掉它。")
        case .matterAtRisk:
            if let days = args.daysUntilTarget, let title = args.matterTitle {
                return String(localized: "「\(title)」的目标已过或临近，这件事还没确认。")
            }
            return String(localized: "这件事存在已确认的风险，需要今天推进。")
        case .matterNeedsAttention:
            if let days = args.daysUntilTarget, let title = args.matterTitle, days >= 0 {
                return String(localized: "距离「\(title)」的目标还有 \(days) 天，建议今天先处理它。")
            }
            if let title = args.matterTitle {
                return String(localized: "「\(title)」还有未解决的问题，建议今天推进。")
            }
            return String(localized: "还有未解决的问题，建议今天推进。")
        case .dueToday:
            return String(localized: "今天到期，完成它收掉一件事。")
        case .plannedToday:
            return String(localized: "你把它安排进了今天。")
        case .habitWindowOpen:
            return String(localized: "现在正处在它的记录窗口。")
        }
    }

    nonisolated static func primaryButtonTitle(for focus: HoloTodayFocus) -> String {
        switch focus.action {
        case .openTask:
            return String(localized: "查看任务")
        case .openSchedule:
            return String(localized: "查看日程")
        case .createTaskFromOpenLoop:
            return String(localized: "加入今日")
        case .openMatter:
            return String(localized: "查看这件事")
        case .discussMatter:
            return String(localized: "和 Holo 梳理")
        case .none:
            return String(localized: "查看")
        }
    }
}