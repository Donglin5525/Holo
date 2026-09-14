//
//  TodayAgendaSection.swift
//  Holo
//
//  今天的安排：日程+任务统一时间序列（今日看板 Matter 化方案 §5.3/§9.1）
//
//  顺序：进行中日程 → 即将开始 → 逾期任务 → 今日任务 → 加入今日 → 近期待推进。
//  同一任务只出现一次；行尾 Matter 名称轻标签（不显示内部 ID）；完成有 3 秒撤回。
//

import SwiftUI

struct TodayAgendaSection: View {

    let items: [HoloTodayAgendaItem]
    let sectionState: HoloTodaySectionState?
    let maxVisible: Int
    let onItem: (HoloTodayAgendaItem) -> Void
    let onComplete: (HoloTodayAgendaItem) -> Void
    /// 正在撤回窗口内的任务 ID（完成反馈短暂保留后收起）。
    var pendingUndoTaskID: UUID?

    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(String(localized: "今天的安排"))

            switch sectionState {
            case .loading:
                Capsule().fill(Color.secondary.opacity(0.1)).frame(height: 64).accessibilityHidden(true)
            case .empty:
                Text(String(localized: "今天没有日程和到期任务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            default:
                if items.isEmpty {
                    Text(String(localized: "今天没有日程和到期任务。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let visible = showAll ? items : Array(items.prefix(maxVisible))
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < visible.count - 1 {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.lg)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

                    if items.count > maxVisible {
                        Button {
                            showAll.toggle()
                        } label: {
                            Text(showAll
                                 ? String(localized: "收起")
                                 : String(localized: "查看全部 \(items.count) 项"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.holoPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func row(_ item: HoloTodayAgendaItem) -> some View {
        Button {
            onItem(item)
        } label: {
            HStack(spacing: 10) {
                leadingAccessory(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(item.kind == .scheduleOngoing ? .semibold : .regular))
                        .foregroundStyle(item.isCompleted ? Color.secondary : Color.primary)
                        .strikethrough(item.isCompleted)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let time = timeText(item) {
                            Text(time)
                                .font(.caption2)
                                .foregroundStyle(item.kind == .taskOverdue ? Color.holoError : Color.secondary)
                        }
                        if let matter = item.matterTitle {
                            Text(matter)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.holoPrimary.opacity(0.1)))
                                .foregroundStyle(Color.holoPrimary)
                        }
                    }
                }
                Spacer(minLength: 0)
                trailingAccessory(item)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func leadingAccessory(_ item: HoloTodayAgendaItem) -> some View {
        switch item.kind {
        case .scheduleOngoing:
            Image(systemName: "record.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.holoSuccess)
        case .scheduleUpcoming:
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(Color.holoPrimary)
        case .taskOverdue:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Color.holoError)
        default:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 14, height: 14)
        }
    }

    /// 任务行完成勾选（日程只读不可勾；已完成显示勾）。
    @ViewBuilder
    private func trailingAccessory(_ item: HoloTodayAgendaItem) -> some View {
        if case .openTask(let taskID) = item.action {
            if item.isCompleted || pendingUndoTaskID == taskID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.holoSuccess)
            } else {
                Button {
                    onComplete(item)
                } label: {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.holoPrimary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("完成 \(item.title)"))
            }
        }
    }

    private func timeText(_ item: HoloTodayAgendaItem) -> String? {
        guard let date = item.timeAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        switch item.kind {
        case .scheduleOngoing, .scheduleUpcoming:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        case .taskOverdue:
            formatter.dateFormat = "M/d"
            return String(localized: "逾期 · \(formatter.string(from: date))")
        case .taskDueToday:
            return String(localized: "今天")
        case .taskPlannedToday:
            return nil
        case .taskRecent:
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}