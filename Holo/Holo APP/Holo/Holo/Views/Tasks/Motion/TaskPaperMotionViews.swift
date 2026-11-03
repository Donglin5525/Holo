//
//  TaskPaperMotionViews.swift
//  Holo
//
//  任务完成动效组件。
//  稳定界面使用 Holo 共同视觉骨架，纸页的收起、上浮和落定只保留在完成瞬间。
//

import SwiftUI

// MARK: - 今日任务状态头

/// 不依赖进度条的文字状态头，外观与 Holo 其他模块的标准卡片一致。
struct TaskPaperHeaderCard: View {
    let title: String
    let subtitle: String
    var countBadge: String?

    var body: some View {
        HStack(alignment: .center, spacing: HoloSpacing.md) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 38, height: 38)
                .background(Color.holoPrimary.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if let countBadge {
                Text(countBadge)
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimaryDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.holoPrimary.opacity(0.10), in: Capsule())
                    .fixedSize()
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 统一操作回执

/// 完成、延期等短时可撤回操作共用的 Holo 回执。
struct HoloUndoToast: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)

            Text(message)
                .holoText(.supporting)
                .foregroundColor(.holoToolText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onUndo) {
                Text(String(localized: "撤回"))
                    .font(.holoBody.weight(.semibold))
                    .foregroundColor(.holoToolAction)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("holo.undo")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .holoCard()
        .accessibilityElement(children: .contain)
    }
}
