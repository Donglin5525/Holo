import XCTest
@testable import Holo

final class FlexibleQueryResultConsistencyTests: XCTestCase {

    func testBuildResultAggregatesAllMatchesAndKeepsCompleteIDSnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 1,
            hour: 12
        )))
        let transactions = (0..<250).map { index in
            FlexibleTransactionDTO(
                id: UUID(),
                amount: Decimal(index + 1),
                type: "expense",
                date: date,
                note: "麦当劳",
                remark: nil,
                tags: [],
                categoryName: "快餐",
                parentCategoryName: "餐饮",
                aiCandidate: nil,
                accountId: nil
            )
        }

        let result = FlexibleQueryExecutor.buildResult(
            plan: Self.makePlan(),
            rawResults: transactions
        )

        XCTAssertEqual(result.summary.totalMatched, 250)
        XCTAssertEqual(result.summary.totalAmount, Decimal(31_375))
        XCTAssertEqual(result.calculationResult?.amount, Decimal(string: "125.5"))
        XCTAssertEqual(result.matchedTransactions.count, 20)
        XCTAssertEqual(result.allMatchedTransactionIDs?.count, 250)
        XCTAssertEqual(Set(result.allMatchedTransactionIDs ?? []).count, 250)
        XCTAssertEqual(result.summary.queryDateRange, "2026-06-12 ~ 2026-07-11")
        XCTAssertEqual(result.summary.dateRange, "2026-07-01 ~ 2026-07-01")
    }

    func testLegacyPersistedResultWithoutSnapshotStillDecodes() throws {
        let result = FlexibleQueryExecutor.buildResult(
            plan: Self.makePlan(),
            rawResults: [Self.makeTransaction(amount: 48)]
        )
        let encoded = try JSONEncoder().encode(result)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "allMatchedTransactionIDs")
        var summary = try XCTUnwrap(object["summary"] as? [String: Any])
        summary.removeValue(forKey: "queryDateRange")
        object["summary"] = summary

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FlexibleQueryResult.self, from: legacyData)

        XCTAssertNil(decoded.allMatchedTransactionIDs)
        XCTAssertNil(decoded.summary.queryDateRange)
        XCTAssertEqual(decoded.matchedTransactions.map(\.id), result.matchedTransactions.map(\.id))

        let card = try XCTUnwrap(ChatCardData.fromFlexibleQueryResult(decoded))
        guard case .flexibleQuery(let data) = card else {
            return XCTFail("Expected flexible query card")
        }
        XCTAssertFalse(data.hasCompleteResultSnapshot)
        XCTAssertEqual(data.resultTransactionIDs, decoded.matchedTransactions.compactMap { UUID(uuidString: $0.id) })
        XCTAssertTrue(data.viewAllText.contains("本次保存"))
    }

    func testAnswerAndCardUseQueryRangeInsteadOfMatchedDataRange() throws {
        let result = FlexibleQueryExecutor.buildResult(
            plan: Self.makePlan(),
            rawResults: [Self.makeTransaction(amount: 48)]
        )

        let answer = FlexibleQueryAnswerBuilder().answer(result)
        XCTAssertTrue(answer.contains("时间范围：2026-06-12 ~ 2026-07-11"))
        XCTAssertFalse(answer.contains("时间范围：2026-07-01 ~ 2026-07-01"))

        let card = try XCTUnwrap(ChatCardData.fromFlexibleQueryResult(result))
        guard case .flexibleQuery(let data) = card else {
            return XCTFail("Expected flexible query card")
        }
        XCTAssertTrue(data.summaryText.contains("查询范围：2026-06-12 ~ 2026-07-11"))
        XCTAssertFalse(data.summaryText.contains("2026-07-01 ~ 2026-07-01"))
        XCTAssertEqual(data.resultTransactionIDs.count, 1)
        XCTAssertTrue(data.hasCompleteResultSnapshot)

        let route = try XCTUnwrap(FlexibleQueryFinanceSearchRoute(cardData: data))
        XCTAssertEqual(route.transactionIDs, data.resultTransactionIDs)
        XCTAssertEqual(route.keyword, "麦当劳")
    }

    func testEmptyAnswerStillStatesExecutedQueryRange() {
        let result = FlexibleQueryExecutor.buildResult(
            plan: Self.makePlan(),
            rawResults: []
        )

        let answer = FlexibleQueryAnswerBuilder().answer(result)

        XCTAssertTrue(answer.contains("在 2026-06-12 ~ 2026-07-11 内"))
        XCTAssertTrue(answer.contains("麦当劳"))
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
                keywords: ["麦当劳"],
                excludedKeywords: [],
                categoryNames: [],
                startDate: "2026-06-12",
                endDate: "2026-07-11",
                accountNames: [],
                includeNote: true,
                includeRemark: true,
                includeTags: true,
                includeCategory: true
            ),
            calculation: .averageAmount,
            averageUnit: .meal,
            sort: FlexibleQuerySort(field: .date, direction: .desc),
            limit: 20,
            explanationHints: []
        )
    }

    private static func makeTransaction(amount: Decimal) -> FlexibleTransactionDTO {
        FlexibleTransactionDTO(
            id: UUID(),
            amount: amount,
            type: "expense",
            date: Date(timeIntervalSince1970: 1_782_835_200),
            note: "麦当劳",
            remark: nil,
            tags: [],
            categoryName: "快餐",
            parentCategoryName: "餐饮",
            aiCandidate: nil,
            accountId: nil
        )
    }
}
