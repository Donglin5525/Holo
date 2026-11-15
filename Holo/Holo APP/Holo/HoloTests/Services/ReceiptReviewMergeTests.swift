//
//  ReceiptReviewMergeTests.swift
//  HoloTests
//
//  截图记账 · 多笔合并为一笔内核测试（2026-11-14，原型即契约
//  docs/design-prototypes/receipt-review-merge-prototype.html）：
//  - 入口守卫：方向混排/含转账不可合并（两者同在时方向混排优先）
//  - 默认值推导：名称=金额最大笔+等N笔、备注明细连接、日期取最晚、账户口径
//  - 勾选联动：名称/备注手动改过后冻结，不再自动改写
//  - 合并草案组装：金额合计/幂等键/推断日期标记/科目落空进待分类
//  - 合并落库：恰一条 Transaction（remark/金额/名称正确），重跑不重复入账
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class ReceiptReviewMergeTests: XCTestCase {

    /// 进程唯一测试容器（同 ReceiptBookingKernelTests R4-1 政策）：
    /// 落库测试不依赖 CoreDataStack.shared 真栈，避免实体映射歧义被 try? 吞掉
    private var repo: FinanceRepository!
    private var topLevelCategory: Holo.Category!
    private var subCategory: Holo.Category!

    override func setUp() async throws {
        try await super.setUp()
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Transaction", "Category", "Account"])
        repo = FinanceRepository(context: context)
        let parent = Holo.Category.create(
            in: context, name: "餐饮", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue
        )
        topLevelCategory = parent
        subCategory = Holo.Category.create(
            in: context, name: "午餐", icon: "fork.knife", color: "#FF9500",
            type: TransactionType.expense.rawValue, parentId: parent.id
        )
        try context.save()
    }

    override func tearDown() async throws {
        repo = nil
        try await super.tearDown()
    }

    // MARK: - 状态构造（微信支付服务号 3 笔推送场景，照原型画板①）

    private func makeState(
        index: Int,
        amount: String,
        income: Bool = false,
        note: String,
        dateText: String? = nil,
        daysAgo: Int = 0,
        categoryCandidate: String? = nil,
        transferKind: String? = nil,
        accountID: UUID? = nil
    ) -> ReceiptReviewItemEditState {
        var state = ReceiptReviewItemEditState(
            id: "transaction:\(index)",
            title: "第 \(index + 1) 笔",
            item: ReceiptBookingResultStore.StoredDraftItem(
                itemKey: "transaction:\(index)",
                amountText: amount,
                typeIsIncome: income,
                dateText: dateText,
                note: note,
                paymentChannel: index == 0 ? "微信支付" : nil,
                amountOriginalText: "¥\(amount)",
                categoryCandidate: categoryCandidate,
                normalizedCategoryCandidate: nil,
                semanticCategoryHint: nil,
                reviewNotes: [],
                transferKind: transferKind
            ),
            amountText: amount,
            typeIsIncome: income
        )
        state.note = note
        state.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        state.selectedAccountID = accountID
        return state
    }

    /// 原型场景：美团 ¥23.80、美团 ¥19.80、五代同糖 ¥29.00（最大笔=五代同糖）
    private func makePrototypeStates(accountID: UUID? = nil) -> [ReceiptReviewItemEditState] {
        [
            makeState(index: 0, amount: "23.80", note: "美团平台商户", daysAgo: 1, accountID: accountID),
            makeState(index: 1, amount: "19.80", note: "美团平台商户", daysAgo: 2, accountID: accountID),
            makeState(index: 2, amount: "29.00", note: "五代同糖", daysAgo: 0, categoryCandidate: "甜品", accountID: accountID),
        ]
    }

    // MARK: - 入口守卫

    func testMergeGuardBlocksMixedDirectionAndTransfers() {
        let expense = makeState(index: 0, amount: "23.80", note: "美团平台商户")
        let anotherExpense = makeState(index: 1, amount: "19.80", note: "美团平台商户")
        let income = makeState(index: 2, amount: "8.00", income: true, note: "微信红包")
        let transfer = makeState(index: 3, amount: "200.00", note: "王小明", transferKind: "transfer")
        let redPacket = makeState(index: 4, amount: "8.88", income: true, note: "微信红包", transferKind: "red_packet")

        XCTAssertNil(ReceiptReviewMerge.guardHint([expense, anotherExpense]), "同向支出可合并")
        XCTAssertEqual(ReceiptReviewMerge.guardHint([income, redPacket]), .containsTransfer, "红包同向也不参与合并")
        XCTAssertEqual(ReceiptReviewMerge.guardHint([expense, income]), .mixedDirection)
        XCTAssertEqual(ReceiptReviewMerge.guardHint([expense, transfer]), .containsTransfer, "转账不是消费，不参与合并")
        XCTAssertEqual(
            ReceiptReviewMerge.guardHint([expense, income, transfer]),
            .mixedDirection,
            "两者同时存在时方向混排优先说明"
        )
        XCTAssertNil(ReceiptReviewMerge.guardHint([]), "空勾选不拦（合并态自身有 0 笔占位口径）")
    }

    // MARK: - 默认值推导（原型说明栏 §3 字段表）

    func testDefaultValueDerivation() {
        let states = makePrototypeStates()

        XCTAssertEqual(ReceiptReviewMerge.totalAmount(states), Decimal(string: "72.60"), "金额=勾选笔实时合计")
        XCTAssertEqual(ReceiptReviewMerge.defaultName(states), "五代同糖 等3笔", "名称=金额最大笔商家+等N笔")
        XCTAssertEqual(
            ReceiptReviewMerge.defaultRemark(states),
            "美团平台商户 ¥23.80；美团平台商户 ¥19.80；五代同糖 ¥29.00",
            "备注=各勾选笔「商家 ¥金额」按原顺序用「；」连接"
        )
        XCTAssertEqual(ReceiptReviewMerge.latestDate(states), states[2].date, "日期取最晚一笔")
        XCTAssertEqual(
            ReceiptReviewMerge.defaultName([states[0]]),
            "美团平台商户",
            "N=1 不加等N笔后缀"
        )

        // 账户：各笔一致用同一账户；不一致取第一笔的——两种口径都落在第一笔
        let accountID = UUID()
        let mixed = makePrototypeStates(accountID: accountID)
        XCTAssertEqual(ReceiptReviewMerge.defaultAccountID(mixed), accountID)
    }

    // MARK: - 勾选联动：dirty 冻结

    func testMergedStateSyncFreezesDirtyFields() {
        let states = makePrototypeStates()

        // 未改过：勾选变化自动重算
        var merged = ReceiptReviewMergedEditState()
        ReceiptReviewMerge.sync(&merged, with: states)
        XCTAssertEqual(merged.nameText, "五代同糖 等3笔")
        XCTAssertEqual(merged.remarkText, "美团平台商户 ¥23.80；美团平台商户 ¥19.80；五代同糖 ¥29.00")
        XCTAssertEqual(merged.selectedAccountID, states.first?.selectedAccountID)

        ReceiptReviewMerge.sync(&merged, with: [states[0], states[1]])
        XCTAssertEqual(merged.nameText, "美团平台商户 等2笔", "未手改时勾掉最大笔自动改写名称")

        // 手动改过：冻结，不再被联动覆盖
        merged.nameText = "周末聚餐"
        merged.nameDirty = true
        merged.remarkText = "手写备注"
        merged.remarkDirty = true
        ReceiptReviewMerge.sync(&merged, with: states)
        XCTAssertEqual(merged.nameText, "周末聚餐", "手动改过名称不再自动改写")
        XCTAssertEqual(merged.remarkText, "手写备注", "手动改过备注不再自动覆盖")
    }

    // MARK: - 合并草案组装

    func testBuildDraftFieldsAndPendingCategoryFallback() throws {
        let account = try repo.addAccount(name: "农业银行信用卡", type: .cash)
        let states = makePrototypeStates(accountID: account.id)
        let remark = ReceiptReviewMerge.defaultRemark(states)

        let draft = ReceiptReviewMerge.buildDraft(
            included: states,
            name: "五代同糖 等3笔",
            remark: remark,
            date: ReceiptReviewMerge.latestDate(states),
            selectedCategoryID: nil,
            suggestedCategory: nil,
            accountID: account.id,
            projectID: nil,
            projectName: nil,
            sourceKey: "vision:v2:merge-test",
            paymentStatusOriginalText: "支付成功",
            repo: repo
        )

        XCTAssertEqual(draft.itemKey, ReceiptBookingIdempotency.mergedItemKey)
        XCTAssertEqual(draft.amount, Decimal(string: "72.60"))
        XCTAssertEqual(draft.typeIsIncome, false)
        XCTAssertEqual(draft.note, "五代同糖 等3笔")
        XCTAssertEqual(draft.remark, remark, "合并明细文本落 remark（明细页展示）")
        XCTAssertEqual(draft.date, states[2].date, "日期取勾选笔最晚一笔")
        XCTAssertTrue(draft.dateInferredFromCapture, "所有勾选笔票面无日期时标记按捕获推断")
        XCTAssertEqual(draft.accountID, account.id)
        XCTAssertEqual(draft.paymentChannelOriginalText, "微信支付", "渠道=第一勾选笔渠道")
        XCTAssertNil(draft.amountOriginalText, "合并金额没有单一票面原文")
        XCTAssertEqual(draft.aiCandidate, "甜品", "AI 候选=金额最大笔 categoryCandidate")

        // 科目链落空（无改选、无建议）→ 待分类兜底
        XCTAssertTrue(draft.categoryIsPendingFallback)
        XCTAssertEqual(draft.categoryID, repo.ensurePendingCategory(type: .expense).id)

        // 任一勾选笔有票面日期 → 不算捕获推断
        let withFaceDate = [states[0]] + [makeState(index: 1, amount: "19.80", note: "美团平台商户", dateText: "2026-11-13")]
        let dated = ReceiptReviewMerge.buildDraft(
            included: withFaceDate,
            name: "美团平台商户 等2笔",
            remark: "",
            date: ReceiptReviewMerge.latestDate(withFaceDate),
            selectedCategoryID: nil,
            suggestedCategory: nil,
            accountID: account.id,
            projectID: nil,
            projectName: nil,
            sourceKey: "vision:v2:merge-test-2",
            paymentStatusOriginalText: nil,
            repo: repo
        )
        XCTAssertFalse(dated.dateInferredFromCapture)
        XCTAssertNil(dated.remark, "备注清空落 nil")

        // 用户改选有效科目 → 不落待分类
        let selected = ReceiptReviewMerge.buildDraft(
            included: states,
            name: "五代同糖 等3笔",
            remark: remark,
            date: states[2].date,
            selectedCategoryID: subCategory.id,
            suggestedCategory: nil,
            accountID: account.id,
            projectID: nil,
            projectName: nil,
            sourceKey: "vision:v2:merge-test-3",
            paymentStatusOriginalText: nil,
            repo: repo
        )
        XCTAssertFalse(selected.categoryIsPendingFallback)
        XCTAssertEqual(selected.categorySubName, subCategory.name)
    }

    // MARK: - 合并落库（恰一条 + 幂等）

    func testMergedCommitCreatesExactlyOneTransactionAndIsIdempotent() throws {
        let account = try repo.addAccount(name: "农业银行信用卡", type: .cash)
        let states = makePrototypeStates(accountID: account.id)
        let draft = ReceiptReviewMerge.buildDraft(
            included: states,
            name: "五代同糖 等3笔",
            remark: ReceiptReviewMerge.defaultRemark(states),
            date: ReceiptReviewMerge.latestDate(states),
            selectedCategoryID: subCategory.id,
            suggestedCategory: nil,
            accountID: account.id,
            projectID: nil,
            projectName: nil,
            sourceKey: ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: Data("merge-commit-test".utf8)),
            paymentStatusOriginalText: "支付成功",
            repo: repo
        )

        let service = FinanceTransactionCommandService.shared
        let first = try service.commit(draft: draft, postNotification: false, repository: repo)
        XCTAssertTrue(first.created)

        // 模拟确认后重跑（回执丢失/连点）：命中幂等键返回既有交易，不重复入账
        let second = try service.commit(draft: draft, postNotification: false, repository: repo)
        XCTAssertFalse(second.created)
        XCTAssertEqual(first.transactionID, second.transactionID)

        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "aiSourceMessageId == %@", draft.sourceKey)
        let rows = try repo.context.fetch(request)
        XCTAssertEqual(rows.count, 1, "合并确认整单只允许一条交易")

        let tx = try XCTUnwrap(rows.first)
        XCTAssertEqual(tx.amount.decimalValue, Decimal(string: "72.60"))
        XCTAssertEqual(tx.note, "五代同糖 等3笔")
        XCTAssertEqual(tx.remark, "美团平台商户 ¥23.80；美团平台商户 ¥19.80；五代同糖 ¥29.00")
        XCTAssertEqual(tx.aiSourceItemId, ReceiptBookingIdempotency.mergedItemKey)
        XCTAssertEqual(tx.type, "expense")
        XCTAssertEqual(tx.account?.id, account.id)
        XCTAssertEqual(tx.category?.id, subCategory.id)
    }
}
