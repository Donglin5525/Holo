//
//  ReceiptReviewMerge.swift
//  Holo
//
//  复核确认页 · 多笔合并为一笔的规则内核（2026-11-14，原型即契约
//  docs/design-prototypes/receipt-review-merge-prototype.html）：
//  入口守卫（方向混排/转账不参与合并）、名称/备注/日期/账户默认值推导、
//  勾选联动（用户改过的字段冻结）、合并 ResolvedTransactionDraft 组装
//  （科目=用户改选>resolver 建议>待分类）。视图层只持有状态与触发联动，
//  规则全部收在本文件，供 ReceiptReviewMergeTests 直测。
//

import Foundation

enum ReceiptReviewMerge {

    /// 入口守卫失败原因（两者同时存在时方向混排优先说明，原型画板③）
    enum GuardHint: Equatable {
        case mixedDirection
        case containsTransfer

        var text: String {
            switch self {
            case .mixedDirection:
                return String(localized: "收入和支出混在一起，不能合成一笔")
            case .containsTransfer:
                return String(localized: "转账不能参与合并")
            }
        }
    }

    // MARK: - 入口守卫

    /// 勾选笔能否进入合并态：方向必须一致且不含转账/红包（转账不是消费，语义不同）。
    /// 空勾选不拦（合并态自身有 0 笔占位口径）。
    static func guardHint(_ included: [ReceiptReviewItemEditState]) -> GuardHint? {
        guard let first = included.first else { return nil }
        if included.contains(where: { $0.typeIsIncome != first.typeIsIncome }) {
            return .mixedDirection
        }
        if included.contains(where: { $0.item.transferKind != nil }) {
            return .containsTransfer
        }
        return nil
    }

    // MARK: - 默认值推导（原型说明栏 §3 字段表）

    /// 金额最大的一笔（并列取先出现的）：名称/科目/渠道/AI 候选都锚定它
    static func largestAmountItem(_ included: [ReceiptReviewItemEditState]) -> ReceiptReviewItemEditState? {
        var largest: ReceiptReviewItemEditState?
        for state in included {
            guard let current = largest else {
                largest = state
                continue
            }
            if amount(state) > amount(current) {
                largest = state
            }
        }
        return largest
    }

    /// 合并金额 = 勾选笔实时合计
    static func totalAmount(_ included: [ReceiptReviewItemEditState]) -> Decimal {
        included.reduce(Decimal(0)) { $0 + amount($1) }
    }

    /// 名称默认值 = 金额最大勾选笔的名称 + 「 等 N 笔」（N=1 不加后缀，原型画板②）
    static func defaultName(_ included: [ReceiptReviewItemEditState]) -> String {
        guard let largest = largestAmountItem(included) else { return "" }
        guard included.count > 1 else { return largest.note }
        return largest.note + " " + String(localized: "等\(included.count)笔")
    }

    /// 备注默认值 = 各勾选笔「<名称> ¥<金额>」按原顺序用「；」连接
    static func defaultRemark(_ included: [ReceiptReviewItemEditState]) -> String {
        included.map { state in
            let amountText = ReceiptBookingCoordinator.decimal(fromText: state.amountText)
                .map(ReceiptBookingCoordinator.formatAmount) ?? state.amountText
            return "\(state.note) ¥\(amountText)"
        }
        .joined(separator: "；")
    }

    /// 日期默认值 = 勾选笔最晚一笔（票面没日期的笔在 load 时已回落当天）
    static func latestDate(_ included: [ReceiptReviewItemEditState]) -> Date {
        included.map(\.date).max() ?? Date()
    }

    /// 账户默认值：各笔一致时用同一账户、不一致取第一笔的——两种口径都落在
    /// 第一笔的 selectedAccountID 上（一致时第一笔就是公共值），可直接取。
    static func defaultAccountID(_ included: [ReceiptReviewItemEditState]) -> UUID? {
        included.first?.selectedAccountID
    }

    private static func amount(_ state: ReceiptReviewItemEditState) -> Decimal {
        ReceiptBookingCoordinator.decimal(fromText: state.amountText) ?? 0
    }

    // MARK: - 勾选联动

    /// 勾选变化时同步默认值：用户没手动改过的字段跟随勾选重算，改过的冻结
    /// （原型 §2 勾选四联动：合计/名称/备注/按钮金额；账户/日期未改过同样跟随）
    static func sync(_ state: inout ReceiptReviewMergedEditState, with included: [ReceiptReviewItemEditState]) {
        if !state.nameDirty {
            state.nameText = defaultName(included)
        }
        if !state.remarkDirty {
            state.remarkText = defaultRemark(included)
        }
        if !state.accountDirty {
            state.selectedAccountID = defaultAccountID(included)
        }
        if !state.dateDirty {
            state.date = latestDate(included)
        }
    }

    // MARK: - 合并草案组装（confirm 合并分支与单测共用）

    /// included 由调用方保证非空且方向统一（入口守卫已拦）。
    /// 科目优先级：用户改选（所选已失效则落待分类）> resolver 建议（金额最大笔
    /// 候选链，由调用方异步解析后传入）> 待分类兜底——与逐笔确认同口径。
    @MainActor
    static func buildDraft(
        included: [ReceiptReviewItemEditState],
        name: String,
        remark: String,
        date: Date,
        selectedCategoryID: UUID?,
        suggestedCategory: HoloFinanceCategory?,
        accountID: UUID,
        projectID: UUID?,
        projectName: String?,
        sourceKey: String,
        paymentStatusOriginalText: String?,
        repo: FinanceRepository
    ) -> ResolvedTransactionDraft {
        let first = included[0]
        let largest = largestAmountItem(included) ?? first
        let typeIsIncome = first.typeIsIncome
        let type: TransactionType = typeIsIncome ? .income : .expense

        let category: HoloFinanceCategory?
        if let selectedCategoryID {
            category = repo.findCategory(by: selectedCategoryID)
        } else {
            category = suggestedCategory
        }
        let finalCategory = category ?? repo.ensurePendingCategory(type: type)
        let names = repo.resolveCategoryNames(from: finalCategory)

        return ResolvedTransactionDraft(
            itemKey: ReceiptBookingIdempotency.mergedItemKey,
            amount: totalAmount(included),
            typeIsIncome: typeIsIncome,
            date: date,
            dateInferredFromCapture: included.allSatisfy { $0.item.dateText == nil },
            // 名称即账本显示名：用户清空=明确不要名字（账本回退显示科目名）
            note: name.isEmpty ? nil : name,
            remark: remark.isEmpty ? nil : remark,
            categoryID: finalCategory.id,
            categoryPrimaryName: names.primary,
            categorySubName: names.sub,
            categoryIsPendingFallback: category == nil,
            accountID: accountID,
            accountName: repo.findAccount(by: accountID)?.name ?? "",
            usedDefaultAccount: repo.getDefaultAccountSync()?.id == accountID,
            financeProjectID: projectID,
            financeProjectName: projectName,
            // 合并金额没有单一票面原文可挂，整单原文证据保留支付状态与渠道
            amountOriginalText: nil,
            paymentStatusOriginalText: paymentStatusOriginalText,
            paymentChannelOriginalText: first.item.paymentChannel,
            confidenceAmount: nil,
            confidenceDirection: nil,
            confidencePaymentStatus: nil,
            confidenceDate: nil,
            imageDigest: sourceKey,
            sourceKey: sourceKey,
            schemaVersion: 2,
            aiCandidate: largest.item.categoryCandidate
        )
    }
}
