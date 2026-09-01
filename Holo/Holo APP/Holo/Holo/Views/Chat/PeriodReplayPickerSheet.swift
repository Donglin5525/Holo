//
//  PeriodReplayPickerSheet.swift
//  Holo
//
//  周期回放选择 Sheet（从记忆长廊 AI 回放迁移到聊天）
//  用户选周期后回调，触发生成并在聊天消息流里以卡片显示
//
//  周期初数据不足时不再把「本周/本月」悄悄替换成上一周期的数据：
//  上一完整周期与进行中的当前周期各占一行，标签与数据范围一一对应，
//  用户想直接分析当前周期（哪怕只有一两天）随时可选。
//

import SwiftUI

struct PeriodReplayPickerSheet: View {
    /// 选定周期后的回调：(周期类型, 起始, 结束)
    let onSelect: (MemoryInsightPeriodType, Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    /// nil = 尚未点选，落到默认选中项（周视图的有效范围，与历史行为一致）
    @State private var selectedID: ReplayOption.ID?
    @State private var customStart: Date = Date().addingDays(-6).startOfDay
    @State private var customEnd: Date = Date().startOfDay

    private var options: [ReplayOption] {
        ReplayOption.buildOptions(now: Date())
    }

    private var effectiveSelectedID: ReplayOption.ID {
        selectedID ?? ReplayOption.ID.defaultSelection(now: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    headerSection
                    periodOptionsSection
                    if effectiveSelectedID == .custom {
                        customDatePicker
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("周期回放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("生成回放") {
                        guard let option = options.first(where: { $0.id == effectiveSelectedID }) else { return }
                        if option.periodType == .custom {
                            // 自定义周期：结束日期取当天结束（23:59:59）
                            let end = Calendar.current.date(
                                bySettingHour: 23, minute: 59, second: 59,
                                of: customEnd.startOfDay
                            ) ?? customEnd.startOfDay
                            onSelect(.custom, customStart.startOfDay, end)
                        } else if let range = option.range {
                            onSelect(option.periodType, range.start, range.end)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("选一个周期，Holo 会生成这期间的回放")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
    }

    private var periodOptionsSection: some View {
        VStack(spacing: HoloSpacing.sm) {
            ForEach(options) { option in
                periodRow(option)
            }
        }
    }

    private func periodRow(_ option: ReplayOption) -> some View {
        Button {
            selectedID = option.id
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: option.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoPrimary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(rowSubtitle(for: option))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if effectiveSelectedID == option.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.holoPrimary)
                        .font(.system(size: 20))
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.holoTextPlaceholder)
                        .font(.system(size: 20))
                }
            }
            .padding(HoloSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(
                        effectiveSelectedID == option.id ? Color.holoPrimary.opacity(0.4) : Color.holoBorder.opacity(0.5),
                        lineWidth: effectiveSelectedID == option.id ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var customDatePicker: some View {
        VStack(spacing: HoloSpacing.sm) {
            customDateRow(title: "开始", selection: $customStart)
            customDateRow(title: "结束", selection: $customEnd)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.5), lineWidth: 1)
        )
    }

    private func customDateRow(title: String, selection: Binding<Date>) -> some View {
        HStack {
            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Spacer()
            DatePicker(
                title,
                selection: selection,
                displayedComponents: .date
            )
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .onChange(of: selection.wrappedValue) { _, _ in
            // 保证开始 <= 结束
            if customStart.startOfDay > customEnd.startOfDay {
                customEnd = customStart.startOfDay
            }
        }
    }

    /// 自定义行选中后副标题跟随所选日期，其余行直接用构建时的固定副标题
    private func rowSubtitle(for option: ReplayOption) -> String {
        guard option.id == .custom, effectiveSelectedID == .custom else { return option.subtitle }
        return "\(customStart.formattedZhRangeShort()) - \(customEnd.formattedZhRangeShort())"
    }
}

// MARK: - 选项模型

/// 一行周期选项。标签必须描述真实数据范围（所见即所得）：
/// 智能回退触发时拆成「上一周期（完整）」与「当前周期（进行中）」两行。
private struct ReplayOption: Identifiable {
    enum ID: String {
        case prevWeekly, currentWeekly
        case prevMonthly, currentMonthly
        case prevQuarterly, currentQuarterly
        case custom

        /// 打开面板时的默认选中：周视图的有效范围（与历史行为一致，
        /// 周期初数据不足时默认落在上一完整周）。
        static func defaultSelection(now: Date) -> ID {
            let effective = MemoryInsightContextBuilder.effectivePeriodRange(
                periodType: .weekly, referenceDate: now
            )
            return effective.isFallback ? .prevWeekly : .currentWeekly
        }
    }

    let id: ID
    let periodType: MemoryInsightPeriodType
    let title: String
    let subtitle: String
    /// 固定起止（custom 行无固定范围，由日期选择器决定）
    let range: (start: Date, end: Date)?
    let icon: String

    static func buildOptions(now: Date) -> [ReplayOption] {
        let specs: [(
            type: MemoryInsightPeriodType, prev: ID, current: ID,
            prevTitle: String, currentTitle: String, icon: String
        )] = [
            (.weekly, .prevWeekly, .currentWeekly, "上周", "本周", "calendar"),
            (.monthly, .prevMonthly, .currentMonthly, "上月", "本月", "calendar.badge.clock"),
            (.quarterly, .prevQuarterly, .currentQuarterly, "上季度", "本季度", "calendar.circle"),
        ]

        var options: [ReplayOption] = []
        for spec in specs {
            let current = MemoryInsightContextBuilder.periodRange(
                periodType: spec.type, referenceDate: now, now: now
            )
            let effective = MemoryInsightContextBuilder.effectivePeriodRange(
                periodType: spec.type, referenceDate: now, now: now
            )
            if effective.isFallback {
                let dayCount = daySpan(from: current.start, to: current.end)
                options.append(ReplayOption(
                    id: spec.prev,
                    periodType: spec.type,
                    title: spec.prevTitle,
                    subtitle: subtitleText(effective.start, effective.end, badge: "完整"),
                    range: (effective.start, effective.end),
                    icon: spec.icon
                ))
                options.append(ReplayOption(
                    id: spec.current,
                    periodType: spec.type,
                    title: spec.currentTitle,
                    subtitle: subtitleText(current.start, current.end, badge: "进行中\(dayCount)天"),
                    range: (current.start, current.end),
                    icon: spec.icon
                ))
            } else {
                options.append(ReplayOption(
                    id: spec.current,
                    periodType: spec.type,
                    title: spec.currentTitle,
                    subtitle: subtitleText(current.start, current.end, badge: nil),
                    range: (current.start, current.end),
                    icon: spec.icon
                ))
            }
        }
        options.append(ReplayOption(
            id: .custom,
            periodType: .custom,
            title: "自定义周期",
            subtitle: "自定义起止日期",
            range: nil,
            icon: "slider.horizontal.3"
        ))
        return options
    }

    private static func subtitleText(_ start: Date, _ end: Date, badge: String?) -> String {
        let text = "\(start.formattedZhMonthDay()) - \(end.formattedZhMonthDay())"
        guard let badge else { return text }
        return "\(text) · \(badge)"
    }

    /// 起止天数（闭区间：8月31日–9月1日 = 2 天）
    private static func daySpan(from start: Date, to end: Date) -> Int {
        (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }
}

// MARK: - Date Formatting Helpers

private extension Date {
    func formattedZhRangeShort() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M.d"
        return formatter.string(from: self)
    }

    func formattedZhMonthDay() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: self)
    }
}
