//
//  HabitStatsMonthSwitcher.swift
//  Holo
//
//  统计页月份切换组件（左右箭头 + 点击选月）
//

import SwiftUI

struct HabitStatsMonthSwitcher: View {
    let month: Date
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onTap: () -> Void

    private var monthText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: month)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左箭头
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }

            Spacer()

            // 月份显示（点击弹出选择器）
            Button(action: onTap) {
                VStack(spacing: 2) {
                    Text(monthText)
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 右箭头
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(canGoNext ? .holoTextPrimary : .holoTextSecondary.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(!canGoNext)
        }
    }
}

#Preview {
    HabitStatsMonthSwitcher(
        month: Date(),
        canGoNext: false,
        onPrevious: {},
        onNext: {},
        onTap: {}
    )
    .padding()
    .background(Color.holoBackground)
}
