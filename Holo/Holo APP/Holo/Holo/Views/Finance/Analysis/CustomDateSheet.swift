//
//  CustomDateSheet.swift
//  Holo
//
// 自定义日期范围选择弹窗（点两次自动完成：选开始 → 自动进入选结束 → 自动应用）
//

import SwiftUI

// MARK: - CustomDateSheet

/// 自定义日期范围选择弹窗
///
/// 交互流程（点两次完成筛选）：
/// 1. 进入默认在「开始」阶段，点击日历选开始日期
/// 2. 选完后自动切换到「结束」阶段
/// 3. 点击日历选结束日期 → 自动应用并关闭
///
/// 日历用自制的 `DateRangeCalendar`（范围内铺浅品牌色 + 首尾端点圆形高亮），
/// 原生 DatePicker(.graphical) 不支持范围高亮。
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

    // MARK: - 编辑日期类型

    enum EditingDate {
        case start
        case end
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .center, spacing: HoloSpacing.lg) {
                // 阶段提示
                phaseHint

                // 开始/结束卡片（点击可回到对应阶段重选）
                dateRangeDisplay

                // 范围月历（范围内铺浅品牌色，首尾端点圆形高亮）
                datePickerSection

                Spacer()

                // 兜底完成按钮（主流程靠自动推进，按钮作为备选）
                confirmButton
            }
            .padding(HoloSpacing.lg)
            .background(Color.holoBackground)
            .navigationTitle("选择日期范围")
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
             ? "① 点击日历选择开始日期"
             : "② 点击日历选择结束日期")
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
    }

    // MARK: - 日期范围显示

    private var dateRangeDisplay: some View {
        HStack(spacing: HoloSpacing.md) {
            DateDisplayCard(
                title: "开始",
                date: tempStartDate,
                isSelected: editingDate == .start
            ) {
                guard !hasApplied else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    editingDate = .start
                }
            }

            Image(systemName: "arrow.right")
                .foregroundColor(.holoTextSecondary)

            DateDisplayCard(
                title: "结束",
                date: tempEndDate,
                isSelected: editingDate == .end
            ) {
                guard !hasApplied else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
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
            withAnimation(.easeInOut(duration: 0.2)) {
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
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日"
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
