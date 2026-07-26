//
//  PeriodReplayPickerSheet.swift
//  Holo
//
//  周期回放选择 Sheet（从记忆长廊 AI 回放迁移到聊天）
//  用户选周期后回调，触发生成并在聊天消息流里以卡片显示
//

import SwiftUI

struct PeriodReplayPickerSheet: View {
    /// 选定周期后的回调：(周期类型, 起始, 结束)
    let onSelect: (MemoryInsightPeriodType, Date, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeriod: MemoryInsightPeriodType = .weekly
    @State private var customStart: Date = Date().addingDays(-6).startOfDay
    @State private var customEnd: Date = Date().startOfDay

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    headerSection
                    periodOptionsSection
                    if selectedPeriod == .custom {
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
                        let range = resolvedRange()
                        onSelect(selectedPeriod, range.start, range.end)
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
            periodRow(.weekly, title: "本周", subtitle: weeklySubtitle, icon: "calendar")
            periodRow(.monthly, title: "本月", subtitle: monthlySubtitle, icon: "calendar.badge.clock")
            periodRow(.quarterly, title: "本季度", subtitle: quarterlySubtitle, icon: "calendar.circle")
            periodRow(.custom, title: "自定义周期", subtitle: customSubtitle, icon: "slider.horizontal.3")
        }
    }

    private func periodRow(_ period: MemoryInsightPeriodType, title: String, subtitle: String, icon: String) -> some View {
        Button {
            selectedPeriod = period
        } label: {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 32, height: 32)
                    .background(Color.holoPrimary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if selectedPeriod == period {
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
                        selectedPeriod == period ? Color.holoPrimary.opacity(0.4) : Color.holoBorder.opacity(0.5),
                        lineWidth: selectedPeriod == period ? 1.5 : 1
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

    // MARK: - Period Resolution

    /// 解析周期的实际起止时间（复用 MemoryInsightContextBuilder 的范围逻辑）
    /// - Parameter period: 指定要解析的周期；缺省时使用当前选中的 `selectedPeriod`（用于"生成回放"按钮）。
    ///   注意：每个副标题必须显式传入自身周期，避免依赖全局选中态导致串显。
    private func resolvedRange(for period: MemoryInsightPeriodType? = nil) -> (start: Date, end: Date) {
        let resolved = period ?? selectedPeriod
        let now = Date()
        switch resolved {
        case .weekly:
            // 取上一完整自然周（与记忆长廊原逻辑一致）
            let r = MemoryInsightContextBuilder.effectivePeriodRange(periodType: .weekly, referenceDate: now)
            return (r.start, r.end)
        case .monthly:
            let r = MemoryInsightContextBuilder.effectivePeriodRange(periodType: .monthly, referenceDate: now)
            return (r.start, r.end)
        case .quarterly:
            let r = MemoryInsightContextBuilder.effectivePeriodRange(periodType: .quarterly, referenceDate: now)
            return (r.start, r.end)
        case .daily:
            let r = MemoryInsightContextBuilder.effectivePeriodRange(periodType: .daily, referenceDate: now)
            return (r.start, r.end)
        case .custom:
            // 自定义周期：结束日期取当天结束（23:59:59）
            let end = Calendar.current.date(
                bySettingHour: 23, minute: 59, second: 59,
                of: customEnd.startOfDay
            ) ?? customEnd.startOfDay
            return (customStart.startOfDay, end)
        }
    }

    // MARK: - Subtitles

    private var weeklySubtitle: String {
        // 显式传入 .weekly，避免依赖全局 selectedPeriod 导致首次打开时显示成其他周期的范围
        let range = resolvedRange(for: .weekly)
        return "\(range.start.formattedZhMonthDay()) - \(range.end.formattedZhMonthDay())"
    }

    private var monthlySubtitle: String {
        let range = resolvedRange(for: .monthly)
        return "\(range.start.formattedZhMonthDay()) - \(range.end.formattedZhMonthDay())"
    }

    private var quarterlySubtitle: String {
        let range = resolvedRange(for: .quarterly)
        return "\(range.start.formattedZhMonthDay()) - \(range.end.formattedZhMonthDay())"
    }

    private var customSubtitle: String {
        selectedPeriod == .custom
            ? "\(customStart.formattedZhRangeShort()) - \(customEnd.formattedZhRangeShort())"
            : "自定义起止日期"
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
