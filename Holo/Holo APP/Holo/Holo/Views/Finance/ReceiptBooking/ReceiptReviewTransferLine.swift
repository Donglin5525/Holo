//
//  ReceiptReviewTransferLine.swift
//  Holo
//
//  图片记账确认页 · 转账/红包方向行（2026-11-06 截图记账开放转账与红包识别方案 §5.3）
//  方向认反会让账面差出两倍金额，所以把「转出/发出/收到 · 转账/红包 · 对方」放在笔卡最上方，
//  方向跟随卡内收支切换实时变化；待收款时下方加一行提示（东林拍板：照常记，被退回记得删）。
//  叶子 struct（View 限重红线：新界面块独立文件，不内联进宿主）。
//

import SwiftUI

struct ReceiptReviewTransferLine: View {
    let isRedPacket: Bool
    /// 跟随确认页卡内当前选中的收支方向（不是识别时的原始方向）
    let isIncome: Bool
    let counterparty: String?
    let awaitingReceipt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 与复核列表行同一套收支胶囊配色（收入绿/支出橙，0.15 底）
                Text(directionText)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.15)))
                    .foregroundStyle(tint)
                Text(kindText)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.holoTextPrimary)
                if let counterparty, !counterparty.isEmpty {
                    Text(counterparty)
                        .font(.subheadline)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if awaitingReceipt {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text(HoloVisionTransferInfo.awaitingReceiptHint(isIncome: isIncome))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("receiptReview.transferLine")
    }

    private var tint: Color { isIncome ? .green : .orange }

    private var directionText: String {
        if isIncome { return String(localized: "收到") }
        return isRedPacket ? String(localized: "发出") : String(localized: "转出")
    }

    private var kindText: String {
        isRedPacket ? String(localized: "红包") : String(localized: "转账")
    }
}
