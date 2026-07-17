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

                Text(dateDisplayText)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minWidth: 118)

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
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current

        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: selectedDate)

        if calendar.isDateInToday(selectedDate) {
            return "今天 · \(dateStr)"
        } else if calendar.isDateInYesterday(selectedDate) {
            return "昨天 · \(dateStr)"
        } else {
            formatter.dateFormat = "EEEE"
            let weekday = formatter.string(from: selectedDate)
            return "\(dateStr) \(weekday)"
        }
    }

    private func navigateDate(_ direction: Int) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let newDate = calendar.date(byAdding: .day, value: direction, to: selectedDate),
              newDate <= today else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedDate = calendar.startOfDay(for: newDate)
        }
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
