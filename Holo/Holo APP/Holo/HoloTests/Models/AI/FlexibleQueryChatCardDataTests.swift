import XCTest
@testable import Holo

final class FlexibleQueryChatCardDataTests: XCTestCase {

    func testFlexibleDataQueryIntentLabelUsesChineseQueryCard() {
        XCTAssertEqual(AIIntent.flexibleDataQuery.chatDisplayLabel, "查询卡片")
    }

    func testFlexibleQueryResultBuildsClickableTransactionRows() throws {
        let transactionId = UUID()
        let result = FlexibleQueryResult(
            plan: Self.makePlan(),
            status: .success,
            summary: FlexibleQuerySummary(
                totalMatched: 1,
                totalAmount: Decimal(18.5),
                dateRange: "2026-01-01 ~ 2026-06-02",
                topCategory: "日用"
            ),
            matchedTransactions: [
                FlexibleTransactionEvidence(
                    id: transactionId.uuidString,
                    date: "2026-05-20",
                    amount: Decimal(18.5),
                    type: "expense",
                    note: "买盐花",
                    remark: nil,
                    tags: [],
                    primaryCategory: "日用",
                    subCategory: "生活用品",
                    matchedFields: ["note"],
                    matchReason: "关键词匹配"
                )
            ],
            calculationResult: nil,
            emptyReason: nil,
            followUpSuggestion: nil
        )

        let card = try XCTUnwrap(ChatCardData.fromFlexibleQueryResult(result))
        guard case .flexibleQuery(let data) = card else {
            return XCTFail("Expected flexible query card")
        }

        XCTAssertEqual(data.badgeText, "查询卡片")
        XCTAssertEqual(data.rows.count, 1)
        XCTAssertEqual(data.rows[0].transactionId, transactionId)
        XCTAssertEqual(data.rows[0].title, "买盐花")
    }

    func testFlexibleQueryCardPreviewsFirstThreeRowsAndBuildsViewAllAction() throws {
        let evidences = (0..<9).map { index in
            FlexibleTransactionEvidence(
                id: UUID().uuidString,
                date: "2026-05-\(String(format: "%02d", index + 1))",
                amount: Decimal(index + 1),
                type: "expense",
                note: "烟花 \(index + 1)",
                remark: nil,
                tags: [],
                primaryCategory: "日用",
                subCategory: "烟花",
                matchedFields: ["note"],
                matchReason: "关键词匹配"
            )
        }
        let result = FlexibleQueryResult(
            plan: Self.makePlan(),
            status: .success,
            summary: FlexibleQuerySummary(
                totalMatched: evidences.count,
                totalAmount: Decimal(45),
                dateRange: "2026-05-01 ~ 2026-05-09",
                topCategory: "日用"
            ),
            matchedTransactions: evidences,
            calculationResult: nil,
            emptyReason: nil,
            followUpSuggestion: nil
        )

        let card = try XCTUnwrap(ChatCardData.fromFlexibleQueryResult(result))
        guard case .flexibleQuery(let data) = card else {
            return XCTFail("Expected flexible query card")
        }

        XCTAssertEqual(data.previewRows.count, 3)
        XCTAssertEqual(data.remainingRowCount, 6)
        XCTAssertEqual(data.resultCountText, "9 笔")
        XCTAssertEqual(data.viewAllText, "查看全部 9 笔")
        XCTAssertEqual(data.searchKeyword, "盐花")
    }

    private static func makePlan() -> FlexibleQueryPlan {
        FlexibleQueryPlan(
            domain: .finance,
            operation: .sumAmount,
            filters: FinanceQueryFilters(
                type: .expense,
                amountGreaterThan: nil,
                amountGreaterThanOrEqual: nil,
                amountLessThan: nil,
                amountLessThanOrEqual: nil,
                amountEqual: nil,
                keywords: ["盐花"],
                excludedKeywords: [],
                categoryNames: [],
                startDate: "2026-01-01",
                endDate: "2026-06-02",
                accountNames: [],
                includeNote: true,
                includeRemark: true,
                includeTags: true,
                includeCategory: true
            ),
            calculation: nil,
            sort: nil,
            limit: nil,
            explanationHints: []
        )
    }
}
