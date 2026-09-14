//
//  TodayMatterSection.swift
//  Holo
//
//  「进行中的事」区块：0/1/多 Matter 与稳定入口（今日看板 Matter 化方案 §5.2/§9.1）
//
//  - 0 件：整块不隐藏，给「开始一件事」与「查看已完成」稳定入口；
//  - 1 件：完整卡；多件：首件完整 + 其余紧凑行，右上「全部 N 件」；
//  - 无 Next Action 显示「还没有明确下一步」；suggested 带明确建议标注。
//

import SwiftUI

struct TodayMatterSection: View {

    let matters: [HoloTodayMatterItem]
    let sectionState: HoloTodaySectionState?
    let onCard: (HoloTodayMatterItem) -> Void
    let onStartNew: () -> Void
    let onViewAll: () -> Void
    let onDiscuss: (HoloTodayMatterItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(String(localized: "进行中的事"))
                Spacer()
                if matters.count > 1 {
                    Button(action: onViewAll) {
                        Text(String(localized: "全部 \(matters.count) 件"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.holoPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("todayMatterViewAll")
                }
            }

            switch sectionState {
            case .loading:
                skeleton
            case .empty, .failed:
                emptyState
            default:
                if matters.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(matters.enumerated()), id: \.element.id) { index, item in
                            if index == 0 {
                                fullCard(item)
                            } else {
                                compactRow(item)
                            }
                        }
                        startNewRow
                    }
                }
            }
        }
    }

    // MARK: 完整卡（第一件）

    private func fullCard(_ item: HoloTodayMatterItem) -> some View {
        Button {
            onCard(item)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item.attention))
                        .font(.caption)
                        .foregroundStyle(Color.holoPrimary)
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let days = item.daysUntilTarget, days >= 0 {
                        Text(String(localized: "还有 \(days) 天"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let reason = item.attentionReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let nextTitle = item.nextActionTitle {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                        Text(String(localized: "下一步：\(nextTitle)"))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text(String(localized: "还没有明确下一步"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if item.suggestedCount > 0 {
                    Text(String(localized: "建议 · \(item.suggestedCount) 项待你确认"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    if let next = item.nextAction {
                        Button {
                            onCard(item)
                        } label: {
                            Text(String(localized: "查看这件事"))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            onDiscuss(item)
                        } label: {
                            Text(String(localized: "和 Holo 梳理"))
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().strokeBorder(Color.holoPrimary.opacity(0.4)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            onDiscuss(item)
                        } label: {
                            Text(String(localized: "和 Holo 梳理"))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayMatterCard")
    }

    // MARK: 紧凑行（其余件）

    private func compactRow(_ item: HoloTodayMatterItem) -> some View {
        Button {
            onCard(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: item.attention))
                    .font(.caption2)
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 16)
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let next = item.nextActionTitle {
                    Text(String(localized: "下一步：\(next)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 「＋开始一件事」

    private var startNewRow: some View {
        Button(action: onStartNew) {
            Label(String(localized: "开始一件事"), systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.holoPrimary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg)
                        .strokeBorder(Color.holoPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("todayMatterStartNew")
    }

    // MARK: 空态（整块不隐藏）

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "最近有什么想让 Holo 一起推进？"))
                .font(.subheadline.weight(.medium))
            Text(String(localized: "例如旅行、搬家、求职或一次重要发布。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            startNewRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var skeleton: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.1))
            .frame(height: 84)
            .accessibilityHidden(true)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }

    private func icon(for attention: HoloMatterAttention) -> String {
        switch attention {
        case .atRisk: return "exclamationmark.triangle.fill"
        case .needsAttention: return "circle.badge.exclamationmark"
        case .waiting: return "hourglass"
        case .onTrack: return "checkmark.circle"
        case .unknown: return "circle.dashed"
        }
    }
}