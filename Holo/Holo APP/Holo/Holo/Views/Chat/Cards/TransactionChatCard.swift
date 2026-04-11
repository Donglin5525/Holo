//
//  TransactionChatCard.swift
//  Holo
//
//  记账卡片视图（支出/收入）
//

import SwiftUI

struct TransactionChatCard: View {

    let data: TransactionCardData
    var onTap: (() -> Void)?

    var body: some View {
        ChatCardView(onTap: onTap) {
            // 头部：分类图标 + 标题
            CardHeaderView(
                icon: data.categoryIcon,
                title: data.displayTitle
            )

            // 分隔线
            CardDivider()

            // 金额
            Text(formattedAmount)
                .font(.holoHeading)
                .foregroundColor(data.isExpense ? .holoError : .holoSuccess)

            // 分类路径
            if let path = data.categoryPath {
                Text(path)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
            }

            // 底部：时间 + 操作入口
            CardFooterView(timeText: formattedDate)
        }
        .accessibilityLabel("记账卡片：\(data.displayTitle)，\(data.isExpense ? "支出" : "收入")\(data.amount)元")
    }

    // MARK: - Formatting

    /// 格式化金额（支出加负号，收入加正号）
    private var formattedAmount: String {
        if data.isExpense {
            return "-¥\(data.amount)"
        }
        return "+¥\(data.amount)"
    }

    /// 格式化日期显示
    private var formattedDate: String {
        if let dateStr = data.date, !dateStr.isEmpty {
            return dateStr
        }
        return "刚刚"
    }
}
