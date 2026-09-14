//
//  MatterOpenLoopRow.swift
//  Holo
//
//  Open Loop 行组件：confirmed（橙色实线）与 suggested（虚线弱化「AI 猜的」）视觉永分离。
//

import SwiftUI

/// 一条「还没解决」问题的展示行。
/// 省略号为显式 Menu（§8.5：点按直接弹出，不依赖长按发现）。
struct MatterOpenLoopRow<MenuContent: View>: View {

    let title: String
    let epistemic: HoloMatterOpenLoopEpistemic
    let state: HoloMatterOpenLoopState
    /// 关联任务说明（如「已建任务：问妈妈是否方便」），nil 不显示。
    var taskLine: String? = nil
    /// 点按省略号弹出的操作菜单；nil 时省略号按钮不显示。
    private let menuContent: (() -> MenuContent)?

    init(
        title: String,
        epistemic: HoloMatterOpenLoopEpistemic,
        state: HoloMatterOpenLoopState,
        taskLine: String? = nil,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) {
        self.title = title
        self.epistemic = epistemic
        self.state = state
        self.taskLine = taskLine
        self.menuContent = menuContent
    }

    init(
        title: String,
        epistemic: HoloMatterOpenLoopEpistemic,
        state: HoloMatterOpenLoopState,
        taskLine: String? = nil
    ) where MenuContent == EmptyView {
        self.title = title
        self.epistemic = epistemic
        self.state = state
        self.taskLine = taskLine
        self.menuContent = nil
    }

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(epistemic == .confirmed ? .semibold : .regular))
                    .foregroundStyle(epistemic == .confirmed ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let taskLine {
                    Text(taskLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if epistemic == .suggested {
                    Text(String(localized: "AI 从对话里猜的，等你确认"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let menuContent {
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "更多操作"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(epistemic == .confirmed ? Color(.secondarySystemGroupedBackground) : Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .strokeBorder(
                    epistemic == .confirmed ? Color.clear : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var statusIcon: some View {
        Group {
            switch state {
            case .open:
                Circle()
                    .strokeBorder(Color.holoPrimary, lineWidth: 1.6)
                    .frame(width: 13, height: 13)
            case .waiting:
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
            default:
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 13, height: 13)
            }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if epistemic == .suggested {
            parts.append(String(localized: "AI 建议"))
        }
        parts.append(title)
        if state == .waiting {
            parts.append(String(localized: "等待中"))
        }
        return parts.joined(separator: "，")
    }
}

/// 「已经解决」的展示行（置灰 + 划线 + 来源说明）。
struct MatterResolvedLoopRow: View {
    let title: String
    let resolvedNote: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .strikethrough(color: .secondary.opacity(0.6))
                    .foregroundStyle(.secondary)
                Text(resolvedNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
    }
}
