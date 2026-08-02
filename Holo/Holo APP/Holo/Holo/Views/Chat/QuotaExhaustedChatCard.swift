//
//  QuotaExhaustedChatCard.swift
//  Holo
//
//  额度耗尽提示卡片（对话内轻提示）。
//  与系统错误（红色 errorContent）区分：这是档位限制，不是出错。
//  引导入口为「了解 Holo Plus」，点击跳转会员中心，不弹窗。
//

import SwiftUI

struct QuotaExhaustedChatCard: View {
    /// 提示文案，来自 HoloQuotaError.userMessage
    let message: String
    /// 点击「了解 Holo Plus」回调，由上层导航到会员中心
    var onLearnPlus: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onLearnPlus?()
                } label: {
                    HStack(spacing: 3) {
                        Text("了解 Holo Plus")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.holoPrimary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.holoPrimary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.22), lineWidth: 1)
        }
    }
}
