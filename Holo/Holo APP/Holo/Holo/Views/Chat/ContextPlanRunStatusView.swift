//
//  ContextPlanRunStatusView.swift
//  Holo
//
//  个人情境规划「运行态卡」（实施方案 2026-09-09 §6.2）：同一张 assistant 消息在
//  规划运行期间渲染本卡，展示真实工作阶段与最近更新时间；完成后原位切换为
//  ContextPlanChatCard。阶段来自持久化 run envelope，不是定时轮播的假进度。
//

import SwiftUI

struct ContextPlanRunStatusView: View {
    let envelope: HoloContextPlanRunEnvelope
    /// 失败终态的用户交代文案（类型化失败映射产物）；nil 时用阶段通用文案。
    var failureMessage: String? = nil
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !isTerminal {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(envelope.stage.displayText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onStop {
                    Button(action: onStop) {
                        Text("停止")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("停止本次规划"))
                }
            } else {
                Text(terminalText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(relativeUpdate)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("个性化规划：\(title)。\(isTerminal ? terminalText : envelope.stage.displayText)"))
    }

    private var isTerminal: Bool {
        envelope.stage.isTerminal
    }

    private var title: String {
        switch envelope.stage {
        case .draftReady: return String(localized: "个性化规划已就绪")
        case .failed: return String(localized: "个性化规划未完成")
        case .cancelled: return String(localized: "已停止本次规划")
        default: return String(localized: "Holo 正在为你规划")
        }
    }

    private var iconName: String {
        switch envelope.stage {
        case .draftReady: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "sparkles"
        }
    }

    private var iconColor: Color {
        switch envelope.stage {
        case .draftReady: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var terminalText: String {
        if envelope.stage == .failed, let failureMessage, !failureMessage.isEmpty {
            return failureMessage
        }
        return envelope.stage.displayText
    }

    private var relativeUpdate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let localized = formatter.localizedString(for: envelope.updatedAt, relativeTo: Date())
        return String(localized: "更新于 \(localized)")
    }
}
