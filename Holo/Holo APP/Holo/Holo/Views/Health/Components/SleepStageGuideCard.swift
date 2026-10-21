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
                .foregroundColor(.holoToolTextSecondary)
                .frame(width: 36, height: 36)
                .background(Color.holoNestedCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            VStack(alignment: .leading, spacing: 4) {
                Text("未读取到睡眠分期")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolText)

                Text("目前只有睡眠时长。阶段数据需由 Apple Watch 或兼容设备写入“健康”；可在系统“健康”App 中核对睡眠阶段与数据来源。")
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .holoSurface()
    }
}

#Preview {
    SleepStageGuideCard()
        .padding()
        .background(Color.holoBackground)
}
