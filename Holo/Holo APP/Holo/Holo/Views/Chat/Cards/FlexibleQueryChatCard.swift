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
    var onViewAllTap: () -> Void

    var body: some View {
        ChatCardView {
            VStack(alignment: .leading, spacing: 16) {
                answerSummary

                if !data.previewRows.isEmpty {
                    previewSection
                }
            }
        }
    }

    private var answerSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 34, height: 34)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(data.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        Spacer(minLength: 8)

                        Text(data.resultCountText)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.holoPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.holoPrimary.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if !data.summaryText.isEmpty {
                        Text(data.summaryText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                    }
                }
            }

            if data.totalAmountText != nil || data.averageAmountText != nil {
                HStack(alignment: .bottom, spacing: 22) {
                    if let totalAmountText = data.totalAmountText {
                        resultMetric(label: "合计", value: totalAmountText, isPrimary: true)
                    }
                    if let averageAmountText = data.averageAmountText {
                        resultMetric(label: data.averageLabelText, value: averageAmountText, isPrimary: false)
                    }
                }
                .padding(.leading, 46)
            }
        }
    }

    private func resultMetric(label: String, value: String, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary)

            Text(value)
                .font(.system(size: isPrimary ? 28 : 20, weight: .bold))
                .foregroundColor(isPrimary ? .holoPrimary : .holoTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近明细")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)

                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(data.previewRows) { row in
                    Button {
                        onTransactionTap(row.transactionId)
                    } label: {
                        FlexibleQueryTransactionRowView(row: row)
                    }
                    .buttonStyle(.plain)
                }

                if data.remainingRowCount > 0 {
                    viewAllFooter
                }
            }
        }
    }

    private var viewAllFooter: some View {
        Button {
            onViewAllTap()
        } label: {
            HStack(spacing: 6) {
                Text(data.viewAllText)
                    .font(.system(size: 13, weight: .semibold))

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.holoPrimary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .background(Color.holoPrimary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FlexibleQueryTransactionRowView: View {

    let row: FlexibleQueryTransactionRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: row.isExpense ? "minus.circle.fill" : "plus.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor((row.isExpense ? Color.holoError : Color.holoSuccess).opacity(0.82))
                .frame(width: 24, height: 24)
                .background((row.isExpense ? Color.holoError : Color.holoSuccess).opacity(0.10))
                .clipShape(Circle())

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
            .frame(minWidth: 82, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}
