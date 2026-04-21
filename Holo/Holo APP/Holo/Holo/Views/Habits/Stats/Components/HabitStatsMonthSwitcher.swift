//
//  HabitStatsMonthSwitcher.swift
//  Holo
//
//  统计页月份切换组件
//

import SwiftUI

struct HabitStatsMonthSwitcher: View {
    let month: Date
    let onTap: () -> Void

    private var monthText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: month)
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前自然月")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text(monthText)
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                }
                Spacer()
                Text("切换月份")
                    .font(.holoLabel)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HabitStatsMonthSwitcher(month: Date()) {}
        .padding()
        .background(Color.holoBackground)
}
