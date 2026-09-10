//
//  SleepStageGuideCard.swift
//  Holo
//
//  无 Apple Watch 用户的睡眠阶段引导卡（二期）：
//  从「整卡隐藏」改为保留卡片 + 一句引导，让用户知道功能存在及前提，
//  并明确时长/作息分析不受影响。
//

import SwiftUI

// MARK: - SleepStageGuideCard

struct SleepStageGuideCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.md) {
            Image(systemName: "applewatch")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 36, height: 36)
                .background(Color.holoNestedCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            VStack(alignment: .leading, spacing: 4) {
                Text("想看睡眠阶段（深睡 / REM）？")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextPrimary)

                Text("佩戴 Apple Watch 入睡即可自动记录阶段结构与整晚时间轴。在此之前，时长趋势与作息规律分析不受影响。")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }
}

#Preview {
    SleepStageGuideCard()
        .padding()
        .background(Color.holoBackground)
}
