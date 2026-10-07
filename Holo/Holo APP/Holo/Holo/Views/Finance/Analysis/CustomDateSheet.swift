//
//  CustomDateSheet.swift
//  Holo
//
// 自定义起止日期日历（统计分析页时间筛选条里的「自定义」入口）。
// 点两次自动完成：选开始 → 自动进入选结束 → 自动应用。
// 日历头部 «/» 支持按年快跳，跨年不用逐月翻。
//

import SwiftUI

struct CustomDateSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var startDate: Date
    @Binding var endDate: Date
    var onConfirm: (Date, Date) -> Void

    @State private var tempStartDate: Date
    @State private var tempEndDate: Date
    @State private var editingDate: EditingDate = .start
    /// 防止 dismiss 过程中重复触发应用
    @State private var hasApplied: Bool = false

    init(
        startDate: Binding<Date>,
        endDate: Binding<Date>,
        onConfirm: @escaping (Date, Date) -> Void
    ) {
        self._startDate = startDate
        self._endDate = endDate
        self.onConfirm = onConfirm
        _tempStartDate = State(initialValue: startDate.wrappedValue)
        _tempEndDate = State(initialValue: endDate.wrappedValue)
    }

    enum EditingDate {
        case start
        case end
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .center, spacing: HoloSpacing.lg) {
                    phaseHint
                    dateRangeDisplay
                    datePickerSection
                    confirmButton
                }
                .padding(HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle("自定义起止日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 阶段提示

    private var phaseHint: some View {
        Text(editingDate == .start
             ? String(localized: "① 点击日历选择开始日期")
             : String(localized: "② 点击日历选择结束日期"))
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 日期范围显示

    private var dateRangeDisplay: some View {
        HStack(spacing: HoloSpacing.md) {
            DateDisplayCard(
                title: String(localized: "开始"),
                date: tempStartDate,
                isSelected: editingDate == .start
            ) {
                guard !hasApplied else { return }
                withAnimation(HoloAnimation.standard) {
                    editingDate = .start
                }
            }

            Image(systemName: "arrow.right")
                .foregroundColor(.holoTextSecondary)

            DateDisplayCard(
                title: String(localized: "结束"),
                date: tempEndDate,
                isSelected: editingDate == .end
            ) {
                guard !hasApplied else { return }
                withAnimation(HoloAnimation.standard) {
                    editingDate = .end
                }
            }
        }
    }

    // MARK: - 日期选择器（范围月历）

    private var datePickerSection: some View {
        DateRangeCalendar(
            start: tempStartDate,
            end: tempEndDate
        ) { day in
            handleSelect(day)
        }
    }

    // MARK: - 完成按钮（兜底）

    private var confirmButton: some View {
        Button {
            applyAndDismiss()
        } label: {
            Text("完成")
                .font(.holoBody)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 选择处理

    /// 点击日历某一天：开始阶段 → 记录并自动进入结束阶段；结束阶段 → 记录并自动应用
    private func handleSelect(_ day: Date) {
        guard !hasApplied else { return }
        if editingDate == .start {
            tempStartDate = day
            withAnimation(HoloAnimation.standard) {
                editingDate = .end
            }
        } else {
            tempEndDate = day
            applyAndDismiss()
        }
    }

    // MARK: - 应用

    /// 应用所选范围并关闭：保证 start ≤ end，转成开区间 [start, end+1day)
    private func applyAndDismiss() {
        guard !hasApplied else { return }
        hasApplied = true

        var s = tempStartDate
        var e = tempEndDate
        if e < s { swap(&s, &e) }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: s)
        guard let endDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: e)) else {
            hasApplied = false
            return
        }

        onConfirm(startDay, endDay)
        dismiss()
    }
}

// MARK: - Date Display Card

/// 日期显示卡片
struct DateDisplayCard: View {
    let title: String
    let date: Date
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Text(formatDate(date))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.md)
        .background(isSelected ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(isSelected ? Color.holoPrimary : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onTap?()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("yMMMd")
        return df.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    CustomDateSheet(
        startDate: .constant(Date().addingDays(-7)),
        endDate: .constant(Date())
    ) { _, _ in }
}
