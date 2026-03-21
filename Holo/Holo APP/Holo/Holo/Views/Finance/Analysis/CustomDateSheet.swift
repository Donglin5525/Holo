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

    var body: some View {
        NavigationView {
            VStack(spacing: HoloSpacing.xl) {
                // 日期范围显示
                dateRangeDisplay

                // 日期选择器
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 日期范围显示

    private var dateRangeDisplay: some View {
        HStack(spacing: HoloSpacing.md) {
            DateDisplayCard(title: "开始日期", date: tempStartDate)
            Image(systemName: "arrow.right")
                .foregroundColor(.holoTextSecondary)
            DateDisplayCard(title: "结束日期", date: tempEndDate)
        }
    }

    // MARK: - 日期选择器

    private var datePickerSection: some View {
        VStack(spacing: HoloSpacing.lg) {
            DatePicker(
                "开始日期",
                selection: $tempStartDate,
                in: ...tempEndDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))

            DatePicker(
                "结束日期",
                selection: $tempEndDate,
                in: tempStartDate...,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
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

    var body: some View {
        VStack(spacing: HoloSpacing.xs) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            let df = DateFormatter()
            Text(df.monthDayYear(from: date))
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }
}

// MARK: - DateFormatter Extension

private extension DateFormatter {
    func monthDayYear(from date: Date) -> String {
        locale = Locale(identifier: "zh_CN")
        dateFormat = "yyyy年M月d日"
        return string(from: date)
    }
}

// MARK: - Preview

#Preview {
    CustomDateSheet(
        startDate: .constant(Date().addingDays(-7)),
        endDate: .constant(Date())
    ) { _, _ in }
}
