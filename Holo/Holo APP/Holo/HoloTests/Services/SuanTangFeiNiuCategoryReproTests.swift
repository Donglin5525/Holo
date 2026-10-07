//
//  SuanTangFeiNiuCategoryReproTests.swift
//  Holo
//
//  2026-09-25 东林实报「酸汤肥牛 234」落待分类复现测试。
//  extractedData 逐字段复刻生产 ai_call_logs id=6302 的意图识别回传：
//  {amount:234, note:酸汤肥牛, categoryCandidate:酸汤肥牛, semanticCategoryHint:餐饮}
//  走真实 IntentRouter.route() → handleRecordExpense → matchCategory 全链，
//  断言不落「待分类」，且按当前时段落进餐饮的对应餐次。
//

import XCTest
@testable import Holo

@MainActor
final class SuanTangFeiNiuCategoryReproTests: XCTestCase {

    func testSuanTangFeiNiuRoutesToDiningMealSlot() async throws {
        // 种子默认分类/账户（幂等；测试宿主库）
        FinanceRepository.shared.setup()

        // 复刻确认卡链路的完整数据：AI 原始回传 + 预览失败回写的 primaryCategory=待分类
        // （ConversationCoordinator.previewCategoryMatch 失败时返回 (待分类, nil) 并回写 renderData）
        let reproData: [String: String] = [
            "amount": "234",
            "note": "酸汤肥牛",
            "categoryCandidate": "酸汤肥牛",
            "semanticCategoryHint": "餐饮",
            "primaryCategory": FinancePendingCategory.currentName,
            "confirmationStatus": "pending",
            "pendingKind": "transaction"
        ]
        let parsed = ParsedResult(
            intent: .recordExpense,
            confidence: 0.95,
            extractedData: reproData,
            needsClarification: false,
            clarificationQuestion: nil,
            responseText: nil
        )

        let route = try await IntentRouter.shared.route(parsed)

        guard let txId = route.transactionId else {
            XCTFail("route 未返回交易ID：\(route.text)")
            return
        }
        let tx = try XCTUnwrap(FinanceRepository.shared.findTransaction(by: txId), "交易未落库")
        defer { Task { @MainActor in
            try? await FinanceRepository.shared.deleteTransaction(tx)
        } }

        let subName = route.matchedSubCategory ?? "nil"
        let parentName = route.matchedPrimaryCategory ?? "nil"
        let hour = Calendar.current.component(.hour, from: Date())
        let expectedMeal = CategoryCandidateResolver.mealSubCategoryForHour(hour)
        let pendingName = FinancePendingCategory.currentName

        print("[REPRO] sub=\(subName) parent=\(parentName) unmatched=\(route.categoryUnmatched) hour=\(hour) expected=\(expectedMeal)")

        XCTAssertNotEqual(subName, pendingName, "复现成功：semanticCategoryHint=餐饮 仍落「待分类」")
        XCTAssertEqual(parentName, "餐饮", "应挂到餐饮一级，实际 parent=\(parentName)")
        XCTAssertEqual(subName, expectedMeal, "餐次应按当前时段推断")
    }
}
