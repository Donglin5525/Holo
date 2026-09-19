//
//  HealthDateNavigator.swift
//  Holo
//
//  健康模块按天切换导航条（外层看板与详情页共用）
//

import SwiftUI

// MARK: - HealthDateNavigator

struct HealthDateNavigator: View {
    @Binding var selectedDate: Date
    @State private var showCalendar = false

    var body: some View {
        ZStack {
            HStack {
                Spacer()

                if !Calendar.current.isDateInToday(selectedDate) {
                    todayButton
                }
            }

            HStack(spacing: HoloSpacing.sm) {
                navigationButton(systemName: "chevron.left", isDisabled: false) {
                    navigateDate(-1)
                }

                dateButton

                navigationButton(
                    systemName: "chevron.right",
                    isDisabled: Calendar.current.isDateInToday(selectedDate)
                ) {
                    navigateDate(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.holoCardBackground.opacity(0.55))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.holoBorder.opacity(0.7), lineWidth: 1)
            )
        }
        .sheet(isPresented: $showCalendar) {
            HealthDatePickerSheet(selectedDate: $selectedDate)
        }
    }

    /// 日期文案：点击弹出日历，支持跨月/跨年直接跳转历史日期
    private var dateButton: some View {
        Button {
            showCalendar = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary.opacity(0.7))

                Text(dateDisplayText)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(minWidth: 118)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigationButton(
        systemName: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isDisabled ? .holoTextSecondary.opacity(0.32) : .holoTextSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var todayButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedDate = Calendar.current.startOfDay(for: Date())
            }
        } label: {
            Text("今天")
                .font(.holoLabel)
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var dateDisplayText: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let dateStr = formatter.string(from: selectedDate)

        if calendar.isDateInToday(selectedDate) {
            return String(localized: "今天 · \(dateStr)")
        } else if calendar.isDateInYesterday(selectedDate) {
            return String(localized: "昨天 · \(dateStr)")
        } else {
            formatter.dateFormat = "EEEE"
            let weekday = formatter.string(from: selectedDate)
            return "\(dateStr) \(weekday)"
        }
    }

    private func navigateDate(_ direction: Int) {
        guard let newDate = Self.steppedDate(from: selectedDate, forward: direction > 0) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = newDate
        }
    }

    /// 按天步进的统一边界规则（箭头 / 日历 / 左右滑动切天共用）：不允许越过今天，越界返回 nil
    static func steppedDate(from date: Date, forward: Bool) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let newDate = calendar.date(byAdding: .day, value: forward ? 1 : -1, to: date),
              newDate <= today else { return nil }
        return calendar.startOfDay(for: newDate)
    }
}

// MARK: - HealthDatePickerSheet

/// 按天跳转日历弹层：点选任意历史日期立即生效并关闭，未来日期置灰不可选
private struct HealthDatePickerSheet: View {
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    /// 点选即提交：与箭头/滑动切天共用同一条 selectedDate 写入路径，触发统一的 onChange 重载
    private var pickerSelection: Binding<Date> {
        Binding(
            get: { selectedDate },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedDate = Calendar.current.startOfDay(for: newValue)
                }
                dismiss()
            }
        )
    }

    private var selectableRange: ClosedRange<Date> {
        let lowerBound = Calendar.current.date(byAdding: .year, value: -10, to: Date())
            ?? Date(timeIntervalSinceNow: -10 * 365 * 24 * 3600)
        return lowerBound...Date()
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "",
                selection: pickerSelection,
                in: selectableRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HoloSpacing.md)
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedDate = Calendar.current.startOfDay(for: Date())
                        }
                        dismiss()
                    } label: {
                        Text("今天")
                            .foregroundColor(.holoPrimary)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var date = Calendar.current.startOfDay(for: Date())
        var body: some View {
            HealthDateNavigator(selectedDate: $date)
                .padding()
        }
    }
    return PreviewWrapper()
}
