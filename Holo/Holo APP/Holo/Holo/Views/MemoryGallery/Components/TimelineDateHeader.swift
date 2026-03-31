//
//  TimelineDateHeader.swift
//  Holo
//
//  时间线日期分隔头 — 圆点 + 日期 + 星期
//

import SwiftUI

struct TimelineDateHeader: View {
    let section: TimelineSection

    var body: some View {
        HStack(spacing: 10) {
            // 时间线圆点
            Circle()
                .fill(Color.holoPrimary)
                .frame(width: 12, height: 12)
                .shadow(color: Color.holoPrimary.opacity(0.35), radius: 4, x: 0, y: 0)

            // 日期文本
            Text(section.formattedDate)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Text(section.displayLabel)
                .font(.holoLabel)
                .foregroundColor(.holoPrimary)
        }
        .padding(.top, 20)
    }
}
