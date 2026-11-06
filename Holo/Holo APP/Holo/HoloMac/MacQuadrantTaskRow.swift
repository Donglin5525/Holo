//
//  MacQuadrantTaskRow.swift
//  HoloMac
//
//  待确认池紧凑行卡：240×44 单行（完成圈 + 标题 + 截止三态文字），
//  拖拽源 + 点击选中；右键菜单由宿主（看板根）挂载。
//

import SwiftUI

struct MacQuadrantTaskRow: View {

    let task: TodoTask
    /// 完成撤回窗口内的投影态
    var isCompleting: Bool
    var isSelected: Bool
    let onToggleCompletion: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCompletion) {
                Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isCompleting ? .holoPrimary : .holoToolTextSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleting
                ? String(localized: "恢复\(task.title)")
                : String(localized: "完成\(task.title)"))

            Text(task.title)
                .font(.system(size: 13))
                .foregroundColor(isCompleting ? .holoTextSecondary : .holoTextPrimary)
                .strikethrough(isCompleting)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            dueText
        }
        .padding(.horizontal, 10)
        .frame(width: 236, height: 44)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolInset))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.holoPrimary : Color.holoBorder.opacity(0.5),
                    lineWidth: isSelected ? 1.5 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .onTapGesture { onSelect() }
        .onDrag {
            NSItemProvider(object: task.id.uuidString as NSString)
        } preview: {
            MacQuadrantDragPreview(title: task.title, sourceTint: .holoTextSecondary)
        }
    }

    // MARK: - 截止三态（逾期红 / 今天主色 / 其余次级；无截止不出场）

    @ViewBuilder
    private var dueText: some View {
        if task.isOverdue {
            Text(String(localized: "已逾期"))
                .font(.system(size: 11))
                .foregroundColor(.holoToolError)
        } else if task.isDueToday {
            Text(String(localized: "今天"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.holoPrimary)
        } else if let due = task.dueDate {
            Text(Self.monthDayFormatter.string(from: due))
                .font(.system(size: 11))
                .foregroundColor(.holoToolTextSecondary)
        }
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日")
        return formatter
    }()
}
