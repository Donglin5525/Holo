//
//  CustomDateSheet.swift
//  Holo
//
//  自定义日期范围选择弹窗
//

import SwiftUI

// MARK: - CustomDateSheet

/// 自定义日期范围选择弹窗
struct CustomDateSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var startDate: Date
    @Binding var endDate: Date
    var onConfirm: (Date, Date) -> Void

    @State private var tempStartDate: Date
    @State private var tempEndDate: Date
    @State private var editingDate: EditingDate = .start

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
            VStack(spacing: HoloSpacing.lg) {
                // 日期范围显示
                dateRangeDisplay

                // Tab 切换
                tabSelector

                // 日期选择器 - 分开两个
                datePickerSection

                Spacer()

                // 确认按钮
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

    // MARK: - 日期范围显示

    private var dateRangeDisplay: some View {
        HStack(spacing: HoloSpacing.md) {
            DateDisplayCard(
                title: "开始日期",
                date: tempStartDate,
                isSelected: editingDate == .start
            ) {
                editingDate = .start
            }

            Image(systemName: "arrow.right")
                .foregroundColor(.holoTextSecondary)

            DateDisplayCard(
                title: "结束日期",
                date: tempEndDate,
                isSelected: editingDate == .end
            ) {
                editingDate = .end
            }
        }
    }

    // MARK: - Tab 切换

    private var tabSelector: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    editingDate = .start
                }
            } label: {
                Text("开始日期")
                    .font(.holoCaption)
                    .foregroundColor(editingDate == .start ? .white : .holoTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(editingDate == .start ? Color.holoPrimary : Color.clear)
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    editingDate = .end
                }
            } label: {
                Text("结束日期")
                    .font(.holoCaption)
                    .foregroundColor(editingDate == .end ? .white : .holoTextPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(editingDate == .end ? Color.holoPrimary : Color.clear)
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(Capsule())
    }

    // MARK: - 日期选择器

    private var datePickerSection: some View {
        ZStack {
            // 开始日期选择器
            DatePicker(
                "",
                selection: $tempStartDate,
                in: startDateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .padding(HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .opacity(editingDate == .start ? 1 : 0)

            // 结束日期选择器
            DatePicker(
                "",
                selection: $tempEndDate,
                in: endDateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .padding(HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .opacity(editingDate == .end ? 1 : 0)
        }
    }

    /// 开始日期可选范围
    private var startDateRange: ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.current

        guard let minDate = calendar.date(byAdding: .year, value: -5, to: now),
              let maxDate = calendar.date(byAdding: .year, value: 1, to: now) else {
            return now...now
        }

        // 开始日期不能晚于结束日期
        return minDate...tempEndDate
    }

    /// 结束日期可选范围
    private var endDateRange: ClosedRange<Date> {
        let now = Date()
        let calendar = Calendar.current

        guard let minDate = calendar.date(byAdding: .year, value: -5, to: now),
              let maxDate = calendar.date(byAdding: .year, value: 1, to: now) else {
            return now...now
        }

        // 结束日期不能早于开始日期
        return tempStartDate...maxDate
    }

    // MARK: - 确认按钮

    private var confirmButton: some View {
        Button {
            let start = Calendar.current.startOfDay(for: tempStartDate)
            guard let end = Calendar.current.date(byAdding: .day, value: 1, to: tempEndDate) else { return }
            onConfirm(start, end)
            dismiss()
        } label: {
            Text("确认")
                .font(.holoBody)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.md)
                .background(Color.holoPrimary)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
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
