//
//  MatterFocusCard.swift
//  Holo
//
//  首页焦点卡（方案 §13.2）：插在今日日程条下方、中央主内容上方。
//
//  两档形态：完整卡（标题+关注+下一步）/ 紧凑条（一行），按 compact 参数切换；
//  小屏由 HomeView 按实际可用高度降档。没有可展示的 Matter 时整个卡片不出现。
//

import SwiftUI

struct MatterFocusCard: View {

    // MARK: - 展示模型

    nonisolated struct Item: Identifiable, Equatable {
        let id: UUID
        let title: String
        let attention: HoloMatterAttention
        let attentionReason: String?
        let nextActionTitle: String?
        /// 与目标日期的剩余天数（nil = 未知日期，不显示）。
        let daysUntilTarget: Int?

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.attention == rhs.attention
                && lhs.nextActionTitle == rhs.nextActionTitle && lhs.daysUntilTarget == rhs.daysUntilTarget
        }
    }

    let item: Item
    /// 紧凑档（一行条）。
    var compact: Bool = false
    var showViewAll: Bool = true
    var onTap: (() -> Void)? = nil
    var onViewAll: (() -> Void)? = nil

    var body: some View {
        if compact {
            compactCard
        } else {
            fullCard
        }
    }

    // MARK: - 完整档

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "正在进行"))
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.holoPrimary)
                Spacer()
                if showViewAll {
                    Button {
                        onViewAll?()
                    } label: {
                        Text(String(localized: "查看全部"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                attentionBadge
            }

            HStack(spacing: 4) {
                if let days = item.daysUntilTarget {
                    Text(Self.daysText(days))
                }
                if let reason = item.attentionReason, !reason.isEmpty {
                    Text(reason)
                        .foregroundStyle(attentionTint)
                        .fontWeight(.medium)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let next = item.nextActionTitle {
                HStack(spacing: 6) {
                    Text(String(localized: "下一步"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(next)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .strokeBorder(attentionTint.opacity(0.25), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(String(localized: "正在进行"))，\(item.title)，\(item.nextActionTitle ?? "")")
    }

    // MARK: - 紧凑档

    private var compactCard: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(attentionTint)
                .frame(width: 7, height: 7)
            Text(item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let next = item.nextActionTitle {
                Text(String(localized: "下一步：\(next)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 小件

    private var attentionBadge: some View {
        Group {
            switch item.attention {
            case .needsAttention:
                badge(String(localized: "需要关注"), color: .orange)
            case .atRisk:
                badge(String(localized: "有风险"), color: .red)
            case .waiting:
                badge(String(localized: "等待中"), color: .secondary)
            case .onTrack:
                EmptyView()
            case .unknown:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var attentionTint: Color {
        switch item.attention {
        case .atRisk: return .red
        case .needsAttention: return .orange
        default: return .secondary
        }
    }

    nonisolated static func daysText(_ days: Int) -> String {
        if days < 0 {
            return String(localized: "已过期 \(-days) 天")
        } else if days == 0 {
            return String(localized: "就是今天")
        } else {
            return String(localized: "还有 \(days) 天")
        }
    }
}
