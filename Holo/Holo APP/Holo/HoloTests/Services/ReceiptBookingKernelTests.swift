//
//  ReceiptBookingKernelTests.swift
//  HoloTests
//
//  图片快捷指令自动记账 M1 内核测试（2026-09-14 完整方案 §28-M1/§29.1/§29.2）：
//  - 门禁纯逻辑：autoCommit / needsReview / reject 三态与全部边界
//  - 幂等键：规范化图片摘要稳定、条目键格式
//  - 原子写入：同图并发/串行各 N 次只产生一笔；save 成功后重跑返回既有交易
//  - Decimal 金额转换不受二进制浮点尾数污染
//

import XCTest
import CoreData
import UserNotifications
@testable import Holo

@MainActor
final class ReceiptBookingKernelTests: XCTestCase {

    /// 进程唯一测试容器（CoreDataTestSupport R4-1 政策）：落库三测不再依赖
    /// CoreDataStack.shared 真栈——真栈测试与独立容器测试在同进程混跑时，
    /// sharedModel 反复 load 会触发实体映射歧义，fetch 失败被 try? 吞成
    /// nil，误报「账户不存在」。
    private var repo: FinanceRepository!
    private var topLevelCategory: Holo.Category!
    private var subCategory: Holo.Category!

    override func setUp() async throws {
        try await super.setUp()
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["Transaction", "Category", "Account"])

        repo = FinanceRepository(context: context)
        // 普通交易分类必须是二级（validateTransactionCategory 的规则），手工种一对
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

    // MARK: - 门禁纯逻辑（§8 自动落账规则）

    private func makeInput(
        imageType: String = "receipt",
        currency: String? = "CNY",
        paymentStatus: String? = "completed",
        schemaVersion: Int = 2,
        guardsPresent: Bool = false,
        transactions: [ReceiptBookingPolicyTransaction] = [ReceiptBookingPolicyTransaction(
            amount: Decimal(string: "19.90")!,
            typeIsIncome: false,
            confidenceAmount: 0.99,
            confidenceDirection: 0.98,
            confidencePaymentStatus: 0.97
        )],
        fixedAccountUnavailable: Bool = false,
        projectChoiceUnavailable: Bool = false,
        projectAmbiguous: Bool = false,
        incomeWithAttachedProject: Bool = false,
        transactionDateOutsideProjectRange: Bool = false,
        hasHighCertaintyDuplicate: Bool = false,
        hasAmbiguousDuplicate: Bool = false,
        transactionHasExplicitDate: Bool = true,
        source: ReceiptBookingSource = .shortcutScreenshot
    ) -> ReceiptBookingPolicyInput {
        ReceiptBookingPolicyInput(
            imageType: imageType,
            currency: currency,
            paymentStatus: paymentStatus,
            schemaVersion: schemaVersion,
            guardsPresent: guardsPresent,
            transactions: transactions,
            fixedAccountUnavailable: fixedAccountUnavailable,
            projectChoiceUnavailable: projectChoiceUnavailable,
            projectAmbiguous: projectAmbiguous,
            incomeWithAttachedProject: incomeWithAttachedProject,
            transactionDateOutsideProjectRange: transactionDateOutsideProjectRange,
            hasHighCertaintyDuplicate: hasHighCertaintyDuplicate,
            hasAmbiguousDuplicate: hasAmbiguousDuplicate,
            transactionHasExplicitDate: transactionHasExplicitDate,
            source: source
        )
    }

    func testAutoCommitForCleanBillableScreenshot() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(), mode: .autoWhenSafe)
        XCTAssertEqual(decision, .autoCommit)
    }

    func testAlwaysReviewNeverAutoCommits() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(), mode: .alwaysReview)
        XCTAssertEqual(decision, .needsReview([]))
    }

    func testMultipleTransactionsRequireReview() {
        let two = [
            ReceiptBookingPolicyTransaction(amount: 8, typeIsIncome: false, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99),
            ReceiptBookingPolicyTransaction(amount: 25.5, typeIsIncome: false, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99),
        ]
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(transactions: two), mode: .autoWhenSafe)
        XCTAssertEqual(decision, .needsReview([.reviewMultipleTransactions]))
    }

    func testRejectsForFundFlowAndUnfinishedPayments() {
        XCTAssertEqual(
            ReceiptBookingPolicy.evaluate(input: makeInput(imageType: "transfer_screenshot", paymentStatus: "completed"), mode: .autoWhenSafe),
            .reject(.rejectTransfer)
        )
        XCTAssertEqual(
            ReceiptBookingPolicy.evaluate(input: makeInput(imageType: "wealth_screenshot"), mode: .autoWhenSafe),
            .reject(.rejectWealth)
        )
        XCTAssertEqual(
            ReceiptBookingPolicy.evaluate(input: makeInput(imageType: "pending_order"), mode: .autoWhenSafe),
            .reject(.rejectPending)
        )
        // 可记账图型但支付状态为未完成（服务端护栏被绕过的兜底）
        XCTAssertEqual(
            ReceiptBookingPolicy.evaluate(input: makeInput(paymentStatus: "failed"), mode: .autoWhenSafe),
            .reject(.rejectFailedPayment)
        )
        XCTAssertEqual(
            ReceiptBookingPolicy.evaluate(input: makeInput(paymentStatus: "pending"), mode: .autoWhenSafe),
            .reject(.rejectPending)
        )
    }

    func testRejectsForeignCurrencyEvenWithCleanTransaction() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(currency: "USD"), mode: .autoWhenSafe)
        XCTAssertEqual(decision, .reject(.rejectForeignCurrency))
    }

    func testBillableWithNoTransactionRejectsAsInvalidImage() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(transactions: []), mode: .autoWhenSafe)
        XCTAssertEqual(decision, .reject(.rejectInvalidImage))
    }

    func testLegacyContractAlwaysReviews() {
        // v1 响应：无 paymentStatus、无字段级置信度（§26.2：缺字段一律复核，不用整体 confidence 冒充）
        let legacyTx = ReceiptBookingPolicyTransaction(
            amount: 19.9, typeIsIncome: false,
            confidenceAmount: nil, confidenceDirection: nil, confidencePaymentStatus: nil
        )
        let legacy = makeInput(paymentStatus: nil, schemaVersion: 1, transactions: [legacyTx])
        let decision = ReceiptBookingPolicy.evaluate(input: legacy, mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else {
            return XCTFail("v1 契约必须转复核")
        }
        XCTAssertTrue(reasons.contains(.reviewLegacyContract))
        XCTAssertTrue(reasons.contains(.reviewAmountLowConfidence), "缺失置信度不得冒充达标")
        XCTAssertTrue(reasons.contains(.reviewDirectionLowConfidence))
    }

    func testMissingFieldConfidenceBlocksAutoCommit() {
        let tx = ReceiptBookingPolicyTransaction(amount: 19.9, typeIsIncome: false, confidenceAmount: nil, confidenceDirection: 0.99, confidencePaymentStatus: 0.99)
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(transactions: [tx]), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("缺金额置信度必须复核") }
        XCTAssertTrue(reasons.contains(.reviewAmountLowConfidence))
    }

    func testLowConfidenceFieldsRequireReview() {
        let tx = ReceiptBookingPolicyTransaction(amount: 19.9, typeIsIncome: false, confidenceAmount: 0.7, confidenceDirection: 0.99, confidencePaymentStatus: 0.99)
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(transactions: [tx]), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("低置信必须复核") }
        XCTAssertTrue(reasons.contains(.reviewAmountLowConfidence))
    }

    func testServerGuardForcesReview() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(guardsPresent: true), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("护栏改写必须复核") }
        XCTAssertTrue(reasons.contains(.reviewContractGuarded))
    }

    func testFixedAccountUnavailableNeverFallsBackToDefault() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(fixedAccountUnavailable: true), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("固定账户失效必须复核") }
        XCTAssertTrue(reasons.contains(.reviewAccountChoiceUnavailable))
    }

    func testIncomeWithAttachedProjectRequiresReview() {
        let tx = ReceiptBookingPolicyTransaction(amount: 39.9, typeIsIncome: true, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99)
        let decision = ReceiptBookingPolicy.evaluate(
            input: makeInput(paymentStatus: "refunded", transactions: [tx], incomeWithAttachedProject: true),
            mode: .autoWhenSafe
        )
        guard case .needsReview(let reasons) = decision else { return XCTFail("收入挂项目必须复核") }
        XCTAssertTrue(reasons.contains(.reviewProjectNotSupportedForIncome))
    }

    func testRefundWithEvidenceCanAutoCommit() {
        // 退款=refunded+income+高置信 → 允许自动写（评测 r09 实证口径）
        let tx = ReceiptBookingPolicyTransaction(amount: 39.9, typeIsIncome: true, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.98)
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(paymentStatus: "refunded", transactions: [tx]), mode: .autoWhenSafe)
        XCTAssertEqual(decision, .autoCommit)
    }

    func testRefundWrongDirectionRequiresReview() {
        let tx = ReceiptBookingPolicyTransaction(amount: 39.9, typeIsIncome: false, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99)
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(paymentStatus: "refunded", transactions: [tx]), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("退款方向不对必须复核") }
        XCTAssertTrue(reasons.contains(.reviewDirectionLowConfidence))
    }

    func testUnknownPaymentStatusRequiresReview() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(paymentStatus: "unknown"), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("unknown 必须复核") }
        XCTAssertTrue(reasons.contains(.reviewPaymentStatusLowConfidence))
    }

    func testHistoricalImageWithoutDateRequiresReview() {
        // 相册旧图/分享导入无票面日期 → 复核（不能默认今天，§24.2）
        for source in [ReceiptBookingSource.shareSheet, .chat] {
            let decision = ReceiptBookingPolicy.evaluate(
                input: makeInput(transactionHasExplicitDate: false, source: source),
                mode: .autoWhenSafe
            )
            guard case .needsReview(let reasons) = decision else { return XCTFail("\(source) 无日期必须复核") }
            XCTAssertTrue(reasons.contains(.reviewDateMissingForHistoricalImage))
        }
        // 截图/拍小票来源用捕获当天推断 → 可自动写
        for source in [ReceiptBookingSource.shortcutScreenshot, .shortcutCamera] {
            let decision = ReceiptBookingPolicy.evaluate(
                input: makeInput(transactionHasExplicitDate: false, source: source),
                mode: .autoWhenSafe
            )
            XCTAssertEqual(decision, .autoCommit, "\(source) 无票面日期可用捕获当天")
        }
    }

    func testPossibleDuplicateRequiresReview() {
        let decision = ReceiptBookingPolicy.evaluate(input: makeInput(hasAmbiguousDuplicate: true), mode: .autoWhenSafe)
        guard case .needsReview(let reasons) = decision else { return XCTFail("疑似重复必须复核") }
        XCTAssertTrue(reasons.contains(.reviewPossibleDuplicate))
    }

    // MARK: - 幂等键（§9.1）

    func testSourceKeyStableAndDistinct() {
        let a = Data("jpeg-bytes-a".utf8)
        let b = Data("jpeg-bytes-b".utf8)
        let keyA1 = ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: a)
        let keyA2 = ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: a)
        let keyB = ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: b)
        XCTAssertEqual(keyA1, keyA2, "同图摘要必须稳定")
        XCTAssertNotEqual(keyA1, keyB, "不同图必须不同键")
        XCTAssertTrue(keyA1.hasPrefix("vision:v2:"), "来源键必须带契约版本段")
    }

    func testItemKeyFormat() {
        XCTAssertEqual(ReceiptBookingIdempotency.itemKey(index: 0), "transaction:0")
    }

    // MARK: - 金额转换

    func testDecimalConversionAvoidsFloatNoise() {
        XCTAssertEqual(ReceiptBookingCoordinator.decimal(from: 19.9), Decimal(string: "19.90"))
        XCTAssertEqual(ReceiptBookingCoordinator.decimal(from: 98.6), Decimal(string: "98.60"))
        XCTAssertEqual(ReceiptBookingCoordinator.decimal(from: 0.1), Decimal(string: "0.10"))
    }

    // MARK: - 原子写入与幂等（§29.2，独立内存栈，setUp 每用例清库）

    private var createdTransactionIDs: [UUID] = []
    private var createdAccount: Account?

    override func tearDown() async throws {
        // setUp 每用例清库兜底，这里只复位用例状态
        createdTransactionIDs = []
        createdAccount = nil
        repo = nil
        try await super.tearDown()
    }

    /// 组一个可入账的最小草案；账户为栈内即建对象，分类用 setUp 种好的一对
    private func makeDraft(sourceKey: String) throws -> ResolvedTransactionDraft {
        let account = repo.addAccount(name: "测试原子写\(UUID().uuidString.prefix(6))", type: .cash)
        createdAccount = account
        return ResolvedTransactionDraft(
            itemKey: ReceiptBookingIdempotency.itemKey(index: 0),
            amount: Decimal(string: "19.90")!,
            typeIsIncome: false,
            date: Date(),
            dateInferredFromCapture: false,
            note: "瑞幸咖啡",
            remark: nil,
            categoryID: subCategory.id,
            categoryPrimaryName: topLevelCategory.name,
            categorySubName: subCategory.name,
            categoryIsPendingFallback: false,
            accountID: account.id,
            accountName: account.name,
            usedDefaultAccount: false,
            financeProjectID: nil,
            financeProjectName: nil,
            amountOriginalText: "¥19.90",
            paymentStatusOriginalText: "支付成功",
            paymentChannelOriginalText: "微信支付",
            confidenceAmount: 0.99,
            confidenceDirection: 0.99,
            confidencePaymentStatus: 0.98,
            confidenceDate: 0.94,
            imageDigest: sourceKey,
            sourceKey: sourceKey,
            schemaVersion: 2,
            aiCandidate: "瑞幸咖啡"
        )
    }

    func testAtomicCommitCreatesTransactionWithAllFields() async throws {
        let draft = try makeDraft(sourceKey: ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: Data("atomic-test".utf8)))
        let result = try FinanceTransactionCommandService.shared.commit(draft: draft, postNotification: false, repository: repo)
        createdTransactionIDs.append(result.transactionID)

        XCTAssertTrue(result.created)
        let tx = try XCTUnwrap(repo.findTransaction(by: result.transactionID))
        XCTAssertEqual(tx.amount.decimalValue, Decimal(string: "19.90"))
        XCTAssertEqual(tx.type, "expense")
        XCTAssertEqual(tx.aiSourceMessageId, draft.sourceKey, "来源键必须与交易同次保存")
        XCTAssertEqual(tx.aiSourceItemId, "transaction:0")
        XCTAssertTrue(tx.isAICreated)
        XCTAssertEqual(tx.account?.id, draft.accountID, "账户必须首次落库即正确（不能先默认再搬运）")
        XCTAssertEqual(tx.note, "瑞幸咖啡")
    }

    func testRepeatCommitReturnsExistingTransaction() async throws {
        let draft = try makeDraft(sourceKey: ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: Data("repeat-test".utf8)))
        let service = FinanceTransactionCommandService.shared

        let first = try service.commit(draft: draft, postNotification: false, repository: repo)
        createdTransactionIDs.append(first.transactionID)
        // 模拟「save 成功、回执存储失败、再次运行」（§28-M1 门禁）
        let second = try service.commit(draft: draft, postNotification: false, repository: repo)

        XCTAssertFalse(second.created, "重跑必须命中来源键返回既有交易")
        XCTAssertEqual(first.transactionID, second.transactionID, "两次运行必须是同一笔")

        let request = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "aiSourceMessageId == %@", draft.sourceKey)
        let rows = try repo.context.fetch(request)
        XCTAssertEqual(rows.count, 1, "同图重跑只允许一笔交易")
    }

    // MARK: - 结果文字映射（§22.1）

    func testIntentResultTextMapping() {
        let booked = ReceiptBookingOutcome.booked(ReceiptBookingReceipt(
            transactionID: UUID(), summaryText: "已记 ¥19.90 · 瑞幸咖啡",
            usedDefaultAccount: false, categoryNeedsConfirmation: false,
            dateInferredFromCapture: false, sourceKey: "k", itemKey: "transaction:0",
            undoToken: UUID(), createdAt: Date()
        ))
        XCTAssertTrue(RecognizeAndBookReceiptIntent.text(for: booked).contains("已记"))

        let transfer = RecognizeAndBookReceiptIntent.text(for: .rejected(.rejectTransfer))
        XCTAssertTrue(transfer.contains("转账"), "转账拦截必须说明资金流转")

        let failure = RecognizeAndBookReceiptIntent.text(for: .failed(ReceiptBookingFailure(
            reason: .failureNetwork, retryable: true, userMessage: "")))
        XCTAssertTrue(failure.contains("网络"), "网络失败必须说明可重试")

        let review = RecognizeAndBookReceiptIntent.text(for: .needsReview(ReceiptReviewSnapshot(
            draftID: UUID(), reasons: [.reviewMultipleTransactions],
            items: [ReceiptReviewItemSnapshot(
                itemKey: "transaction:0", amountText: "19.90", typeIsIncome: false,
                dateText: nil, note: nil, paymentChannel: nil, amountOriginalText: nil,
                categoryCandidate: nil, normalizedCategoryCandidate: nil,
                semanticCategoryHint: nil, reviewNotes: []
            )],
            merchant: nil, paymentStatusOriginalText: nil,
            sourceKey: "k", createdAt: Date())))
        XCTAssertTrue(review.contains("未入账"), "复核文案不得说「成功」")
    }

    func testRecognizedTimeTextFormatting() {
        // 识别时间必显（2026-09-23）：今天/昨天相对表述，更早给绝对日期，旧草案一眼可辨
        let calendar = Calendar.current
        let now = Date()
        let morning = calendar.date(bySettingHour: 9, minute: 27, second: 0, of: now)!

        XCTAssertTrue(
            ReceiptRecognizedTimeText.text(for: morning, now: now).contains("今天"),
            "当天的草案用「今天 HH:mm」"
        )
        let yesterday = calendar.date(byAdding: .day, value: -1, to: morning)!
        XCTAssertTrue(
            ReceiptRecognizedTimeText.text(for: yesterday, now: now).contains("昨天"),
            "昨天的草案用「昨天 HH:mm」"
        )
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
        let older = ReceiptRecognizedTimeText.text(for: lastMonth, now: now)
        XCTAssertFalse(older.contains("今天"), "更早的草案给绝对日期")
        XCTAssertFalse(older.isEmpty)
    }

    func testMultipleTransactionSnapshotTextMentionsCount() {
        // 2026-09-19 一图多笔：快捷指令回执必须说清笔数与合计，不再只提第一笔
        let items = (0..<2).map { index in
            ReceiptReviewItemSnapshot(
                itemKey: "transaction:\(index)", amountText: index == 0 ? "71.77" : "183.00",
                typeIsIncome: false, dateText: nil, note: nil, paymentChannel: nil,
                amountOriginalText: nil, categoryCandidate: nil,
                normalizedCategoryCandidate: nil, semanticCategoryHint: nil, reviewNotes: []
            )
        }
        let outcome = ReceiptBookingOutcome.needsReview(ReceiptReviewSnapshot(
            draftID: UUID(), reasons: [.reviewMultipleTransactions], items: items,
            merchant: "蒙自源", paymentStatusOriginalText: nil,
            sourceKey: "k", createdAt: Date()))
        let text = RecognizeAndBookReceiptIntent.text(for: outcome)
        XCTAssertTrue(text.contains("2"), "多笔回执必须说清笔数")
        XCTAssertTrue(text.contains("254.77"), "同向多笔回执必须给合计")
    }

    // MARK: - 结果存储往返（§25.1）

    func testResultStoreDraftRoundtrip() async {
        let store = ReceiptBookingResultStore.shared
        let draftID = UUID()
        let snapshot = ReceiptReviewSnapshot(
            draftID: draftID, reasons: [.reviewAmountLowConfidence],
            items: [ReceiptReviewItemSnapshot(
                itemKey: "transaction:0", amountText: "19.90", typeIsIncome: false,
                dateText: "2026-09-15", note: nil, paymentChannel: "微信支付",
                amountOriginalText: "¥19.90", categoryCandidate: "瑞幸咖啡",
                normalizedCategoryCandidate: "咖啡", semanticCategoryHint: "餐饮",
                reviewNotes: [.reviewAmountLowConfidence]
            )],
            merchant: "瑞幸咖啡", paymentStatusOriginalText: "支付成功",
            sourceKey: "vision:v2:test", createdAt: Date()
        )
        await store.saveReviewDraft(
            snapshot: snapshot,
            choices: (accountRaw: "account:auto", projectRaw: "project:none", modeRaw: "autoWhenSafe"),
            sourceKey: "vision:v2:test",
            itemKey: "transaction:0",
            evidenceJPEG: Data("evidence".utf8)
        )

        let drafts = store.loadDrafts()
        let loaded = drafts.first(where: { $0.id == draftID })
        XCTAssertNotNil(loaded, "草案必须能读回")
        XCTAssertEqual(loaded?.amountText, "19.90", "顶层摘要字段冗余首笔（列表行用）")
        XCTAssertEqual(loaded?.effectiveItems.count, 1)
        XCTAssertEqual(loaded?.effectiveItems.first?.categoryCandidate, "瑞幸咖啡")
        XCTAssertEqual(loaded?.sourceKey, "vision:v2:test")

        // 清理测试草案
        ReceiptBookingResultStore.shared.purgeExpired(now: Date().addingTimeInterval(8 * 24 * 3600))
        let after = store.loadDrafts().first(where: { $0.id == draftID })
        XCTAssertNil(after, "过期清理必须移除草案")
    }

    // MARK: - 一图多笔（2026-09-19）

    func testMultiTransactionRejectChecksRunBeforeCountSplit() {
        // 多笔的外币图必须走拒绝而不是转复核（拒绝语义与笔数无关）
        let two = [
            ReceiptBookingPolicyTransaction(amount: 8, typeIsIncome: false, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99),
            ReceiptBookingPolicyTransaction(amount: 25.5, typeIsIncome: false, confidenceAmount: 0.99, confidenceDirection: 0.99, confidencePaymentStatus: 0.99),
        ]
        let decision = ReceiptBookingPolicy.evaluate(
            input: makeInput(imageType: "receipt", currency: "USD", transactions: two), mode: .autoWhenSafe
        )
        XCTAssertEqual(decision, .reject(.rejectForeignCurrency))
    }

    func testLegacyDraftJSONBackwardCompatibility() throws {
        // 旧格式 JSON（顶层单笔、无 items 键，createdAt 为默认 timeIntervalSinceReferenceDate）
        let draftID = UUID()
        let legacy = """
        {"id":"\(draftID.uuidString)","createdAt":7200.0,"reasons":[],"amountText":"19.90",
        "typeIsIncome":false,"merchant":null,"dateText":null,"note":null,"paymentChannel":null,
        "amountOriginalText":null,"paymentStatusOriginalText":null,"categoryCandidate":null,
        "normalizedCategoryCandidate":null,"semanticCategoryHint":null,"imageType":"",
        "sourceKey":"vision:v2:legacy","itemKey":"transaction:0","accountChoiceRaw":"account:auto",
        "projectChoiceRaw":"project:none","modeRaw":"alwaysReview"}
        """
        let draft = try JSONDecoder().decode(ReceiptBookingResultStore.StoredDraft.self, from: Data(legacy.utf8))
        XCTAssertEqual(draft.id, draftID)
        XCTAssertEqual(draft.effectiveItems.count, 1, "旧格式必须合成单条有效条目")
        XCTAssertEqual(draft.effectiveItems.first?.itemKey, "transaction:0")
        XCTAssertEqual(draft.effectiveItems.first?.amountText, "19.90")
    }

    func testUniformTotalOnlyForSameDirection() {
        func item(index: Int, amount: String, income: Bool) -> ReceiptReviewItemSnapshot {
            ReceiptReviewItemSnapshot(
                itemKey: "transaction:\(index)", amountText: amount, typeIsIncome: income,
                dateText: nil, note: nil, paymentChannel: nil, amountOriginalText: nil,
                categoryCandidate: nil, normalizedCategoryCandidate: nil,
                semanticCategoryHint: nil, reviewNotes: []
            )
        }
        let sameDirection = ReceiptReviewSnapshot(
            draftID: UUID(), reasons: [], items: [
                item(index: 0, amount: "71.77", income: false),
                item(index: 1, amount: "183.00", income: false),
            ],
            merchant: nil, paymentStatusOriginalText: nil, sourceKey: "k", createdAt: Date())
        XCTAssertEqual(sameDirection.uniformTotalAmountText, "254.77", "同向合计")

        let mixed = ReceiptReviewSnapshot(
            draftID: UUID(), reasons: [], items: [
                item(index: 0, amount: "71.77", income: false),
                item(index: 1, amount: "10.00", income: true),
            ],
            merchant: nil, paymentStatusOriginalText: nil, sourceKey: "k", createdAt: Date())
        XCTAssertNil(mixed.uniformTotalAmountText, "混合方向不给合计（口径歧义）")
    }

    func testConcurrentCommitsProduceSingleTransaction() async throws {
        let draft = try makeDraft(sourceKey: ReceiptBookingIdempotency.sourceKey(forNormalizedJPEG: Data("concurrent-test".utf8)))
        let service = FinanceTransactionCommandService.shared
        let injectedRepo: FinanceRepository = repo

        // 十路并发提交（MainActor 串行执行但每次都走完整幂等查询路径）
        let results = try await withThrowingTaskGroup(of: FinanceTransactionCommandService.CommitResult.self) { group in
            for _ in 0..<10 {
                group.addTask { @MainActor in
                    try service.commit(draft: draft, postNotification: false, repository: injectedRepo)
                }
            }
            var collected: [FinanceTransactionCommandService.CommitResult] = []
            for try await result in group {
                collected.append(result)
                if result.created {
                    self.createdTransactionIDs.append(result.transactionID)
                }
            }
            collected.sort { $0.transactionID.uuidString < $1.transactionID.uuidString }
            return collected
        }

        XCTAssertEqual(results.count, 10)
        let created = results.filter(\.created)
        XCTAssertEqual(created.count, 1, "十路并发只允许一笔真正创建")
        XCTAssertEqual(Set(results.map(\.transactionID)).count, 1, "所有调用方拿到同一笔交易")
    }

    // MARK: - 待复核提醒通知（押后 5 分钟 + 稳定标识可撤回，东林 2026-09-16 拍板）

    private func makeSnapshot(draftID: UUID = UUID()) -> ReceiptReviewSnapshot {
        ReceiptReviewSnapshot(
            draftID: draftID, reasons: [.reviewAmountLowConfidence],
            items: [ReceiptReviewItemSnapshot(
                itemKey: "transaction:0", amountText: "19.90", typeIsIncome: false,
                dateText: nil, note: nil, paymentChannel: "微信支付",
                amountOriginalText: "¥19.90", categoryCandidate: nil,
                normalizedCategoryCandidate: nil, semanticCategoryHint: nil, reviewNotes: []
            )],
            merchant: "瑞幸咖啡", paymentStatusOriginalText: "支付成功",
            sourceKey: "vision:v2:test", createdAt: Date()
        )
    }

    func testDeferredReviewReminderUsesStableIdentifierAndFiveMinuteDelay() {
        let draftID = UUID()
        let request = ReceiptBookingNotificationService.makeRequest(
            for: .needsReview(makeSnapshot(draftID: draftID)),
            deferredReviewReminder: true
        )
        XCTAssertNotNil(request, "待复核必须产通知")
        XCTAssertEqual(request?.identifier, "receipt-booking-review-\(draftID.uuidString)", "押后提醒标识必须绑定 draftID 供撤回")
        let trigger = request?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval, 5 * 60, "押后时长=5 分钟")
        XCTAssertEqual(trigger?.repeats, false, "只提醒一次")
        XCTAssertEqual(request?.content.userInfo["draftID"] as? String, draftID.uuidString, "点击通知仍按 draftID 深链")
    }

    func testImmediateReviewReminderFiresWithoutDelay() {
        // 不打开 App 的模式（autoWhenSafe）：通知是唯一反馈渠道，必须立即投递
        let draftID = UUID()
        let request = ReceiptBookingNotificationService.makeRequest(
            for: .needsReview(makeSnapshot(draftID: draftID)),
            deferredReviewReminder: false
        )
        XCTAssertNotNil(request)
        XCTAssertNil(request?.trigger, "非押后场景必须立即投递")
        XCTAssertNotEqual(
            request?.identifier,
            "receipt-booking-review-\(draftID.uuidString)",
            "立即投递的结果通知用一次性标识，不占用可撤回标识"
        )
    }

    func testBookedOutcomeNeverDefers() {
        // 结果类通知（已记/重复/失败）即使传了 deferred 也一律立即：它们不是提醒，是即时反馈
        let booked = ReceiptBookingOutcome.booked(ReceiptBookingReceipt(
            transactionID: UUID(), summaryText: "已记 ¥19.90 · 瑞幸咖啡",
            usedDefaultAccount: false, categoryNeedsConfirmation: false,
            dateInferredFromCapture: false, sourceKey: "k", itemKey: "transaction:0",
            undoToken: UUID(), createdAt: Date()
        ))
        let request = ReceiptBookingNotificationService.makeRequest(for: booked, deferredReviewReminder: true)
        XCTAssertNil(request?.trigger, "已记账通知不得押后")
    }

    func testRejectedOutcomeNotifiesWithReason() {
        // 2026-09-23 拒识反馈必达（东林拍板）：后台/自动化运行时快捷指令的结果文字
        // 用户看不到，拒识静默会让用户以为记上了或以为功能坏了——拒绝类一律通知
        // 说清原因；仅用户主动取消保持静默。
        let request = ReceiptBookingNotificationService.makeRequest(
            for: .rejected(.rejectTransfer), deferredReviewReminder: false
        )
        XCTAssertNotNil(request, "拒识必须发通知，不允许静默")
        XCTAssertEqual(request?.content.title, String(localized: "这笔没有入账"))
        XCTAssertEqual(request?.content.body, ReceiptBookingReason.rejectTransfer.rejectionUserText)
        XCTAssertEqual(
            request?.content.body,
            RecognizeAndBookReceiptIntent.text(for: .rejected(.rejectTransfer)),
            "通知与快捷指令结果文字必须同一份口径"
        )
        XCTAssertNil(
            ReceiptBookingNotificationService.makeRequest(
                for: .failed(ReceiptBookingFailure(reason: .failureCancelled, retryable: false, userMessage: "")),
                deferredReviewReminder: false
            ),
            "用户取消不发失败通知"
        )
    }

    func testRejectionUserTextCoversAllRejectReasons() {
        for reason in ReceiptBookingReason.allCases where reason.isReject {
            let text = reason.rejectionUserText
            XCTAssertFalse(text.isEmpty, "\(reason.rawValue) 必须有用户文案")
            XCTAssertFalse(text.contains("reject."), "用户文案不得泄漏机器码")
        }
    }

    func testReviewReminderIdentifierMatchesCancelKey() {
        let draftID = UUID()
        XCTAssertEqual(
            ReceiptBookingNotificationService.reviewReminderIdentifier(for: draftID),
            "receipt-booking-review-\(draftID.uuidString)"
        )
        // 撤回入口可直接调用不崩（removePending/removeDelivered 为空列表时无副作用）
        ReceiptBookingNotificationService.cancelReviewReminders(for: draftID)
    }
}
