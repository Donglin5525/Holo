//
//  ReceiptReviewListView.swift
//  Holo
//
//  图片快捷指令自动记账 · 待复核列表（2026-09-14 完整方案 §25.2/§11）
//  只在存在待复核草案时有内容；详情页确认记账走公共 CommandService。
//

import SwiftUI

struct ReceiptReviewListView: View {
    /// 深链直达：呈现后自动推入指定草案详情（§25.3）
    var initialDraftID: UUID? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [ReceiptBookingResultStore.StoredDraft] = []
    @State private var path = NavigationPath()
    @State private var didRouteInitialDraft = false

    var body: some View {
        NavigationStack(path: $path) {
            listContent
        }
        .onAppear(perform: refresh)
    }

    private var listContent: some View {
        Group {
            if drafts.isEmpty {
                ContentUnavailableView(
                    "没有待复核的账",
                    systemImage: "checkmark.circle",
                    description: Text("识别可靠的账会自动入账，有疑问的账才会出现在这里。")
                )
            } else {
                List {
                Section {
                    ForEach(drafts) { draft in
                        NavigationLink(value: draft.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    // 2026-09-19 一图多笔：行摘要展示首笔金额 + 笔数徽标
                                    Text(draft.amountText.isEmpty ? "—" : "¥\(draft.amountText)")
                                        .font(.headline)
                                    Text(draft.typeIsIncome ? "收入" : "支出")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill((draft.typeIsIncome ? Color.green : Color.orange).opacity(0.15)))
                                        .foregroundStyle(draft.typeIsIncome ? .green : .orange)
                                    if draft.itemCount > 1 {
                                        Text("\(draft.itemCount) 笔")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                                            .foregroundStyle(Color.holoPrimary)
                                    }
                                }
                                if let merchant = draft.merchant, !merchant.isEmpty {
                                    Text(merchant).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(reviewReasonText(draft.reasons))
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("超过 7 天未处理的复核项会自动清理，不会入账。")
                }
                }
            }
        }
        .navigationTitle(Text("待复核"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(for: UUID.self) { draftID in
            if let draft = drafts.first(where: { $0.id == draftID }) {
                ReceiptReviewDetailView(draft: draft) {
                    refresh()
                }
            }
        }
        .onAppear {
            if !didRouteInitialDraft,
               let initialDraftID,
               drafts.contains(where: { $0.id == initialDraftID }) {
                didRouteInitialDraft = true
                path.append(initialDraftID)
            }
        }
    }

    private func refresh() {
        drafts = ReceiptBookingResultStore.shared.loadDrafts()
    }

    private func reviewReasonText(_ reasons: [String]) -> String {
        guard let first = reasons.first, let reason = ReceiptBookingReason(rawValue: first) else {
            return "需要确认"
        }
        switch reason {
        case .reviewMultipleTransactions: return "图里有多笔交易"
        case .reviewAmountLowConfidence, .reviewAmountConflict: return "金额不确定"
        case .reviewDirectionLowConfidence: return "收支方向不确定"
        case .reviewPaymentStatusLowConfidence: return "支付状态不确定"
        case .reviewDateMissingForHistoricalImage: return "图片里没有日期"
        case .reviewPossibleDuplicate: return "可能已经记过一笔"
        case .reviewAccountChoiceUnavailable: return "快捷指令里的账户已失效"
        case .reviewProjectChoiceUnavailable: return "快捷指令里的项目已结束"
        case .reviewProjectAmbiguous: return "匹配到多个项目"
        case .reviewDateOutsideProjectRange: return "日期不在项目周期内"
        case .reviewContractGuarded: return "识别结果有异常"
        case .reviewLegacyContract: return "识别信息不完整"
        default: return "需要确认"
        }
    }
}
