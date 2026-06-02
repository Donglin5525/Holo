//
//  FlexibleQueryChatCard.swift
//  Holo
//
//  灵活查询结果卡片
//

import SwiftUI

struct FlexibleQueryChatCard: View {

    let data: FlexibleQueryChatCardData
    var onTransactionTap: (UUID) -> Void

    var body: some View {
        ChatCardView {
            header

            VStack(spacing: 10) {
                ForEach(data.previewRows) { row in
                    Button {
                        onTransactionTap(row.transactionId)
                    } label: {
                        FlexibleQueryTransactionRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }

                if data.remainingRowCount > 0 {
                    remainingRowsFooter
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 30, height: 30)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(data.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)

                    if !data.summaryText.isEmpty {
                        Text(data.summaryText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(data.resultCountText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Capsule())
            }

            if let totalAmountText = data.totalAmountText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("合计")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)

                    Text(totalAmountText)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.holoPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer()
                }
            }
        }
    }

    private var remainingRowsFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
            Text("还有 \(data.remainingRowCount) 笔未展示，可继续追问查看更多明细")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundColor(.holoTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.holoCardBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct FlexibleQueryTransactionRowView: View {

    let row: FlexibleQueryTransactionRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill((row.isExpense ? Color.holoError : Color.holoSuccess).opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: row.isExpense ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(row.isExpense ? .holoError : .holoSuccess)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(row.date)
                    if let categoryPath = row.categoryPath, !categoryPath.isEmpty {
                        Text("·")
                        Text(categoryPath)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(row.signedAmountText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(row.isExpense ? .holoError : .holoSuccess)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.72))
            }
            .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground.opacity(0.68))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.holoBorder.opacity(0.42), lineWidth: 1)
        )
    }
}
