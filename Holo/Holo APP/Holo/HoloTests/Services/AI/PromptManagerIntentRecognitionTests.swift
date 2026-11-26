import Foundation
import XCTest
@testable import Holo

final class PromptManagerIntentRecognitionTests: XCTestCase {
    func testIntentRecognitionDefaultPromptRequiresTransactionDateForFinanceRecords() {
        let prompt = PromptManager.shared.loadDefaultTemplate(.intentRecognition)

        XCTAssertTrue(prompt.contains("transactionDate"))
        XCTAssertTrue(prompt.contains("昨天=交易日-1"))
        XCTAssertTrue(prompt.contains("记账日期写入 transactionDate"))
    }

    func testIntentRecognitionDefaultPromptStabilizesPersonalStateQueries() {
        let prompt = PromptManager.shared.loadDefaultTemplate(.intentRecognition)

        XCTAssertTrue(prompt.contains("HOLO_PERSONAL_STATE_ROUTING_V24"))
        XCTAssertTrue(prompt.contains("我最近状态怎么样/如何"))
        XCTAssertTrue(prompt.contains("不得追问领域"))
        XCTAssertTrue(prompt.contains("analysisDomain=\"cross_domain\""))
        XCTAssertTrue(prompt.contains("Holo 服务状态怎么样"))
    }

    func testWeightAndExerciseKeepThreeActionsInFallbackPrompt() {
        let prompt = PromptManager.shared.loadDefaultTemplate(.intentRecognition)

        XCTAssertEqual(IntentDescriptorRegistry.requiredFields(for: .recordWeight), ["weight"])
        XCTAssertTrue(prompt.contains("[HOLO_INTENT_WEIGHT_RECORD_V36]"))
        XCTAssertTrue(prompt.contains(#"items 为 record_weight {weight:"72.5",unit:"kg"}"#))
        XCTAssertTrue(prompt.contains(#"check_in {habitName:"俯卧撑",habitValue:"15"}、check_in {habitName:"深蹲",habitValue:"20"}"#))
    }

    func testFallbackUsesSameQuantityEvidenceInstructionAsGateway() {
        let prompt = PromptManager.shared.loadDefaultTemplate(.intentRecognition)

        XCTAssertTrue(prompt.contains("[HOLO_INTENT_QUANTITY_V37]"))
        XCTAssertTrue(prompt.contains("quantityQuote"))
        XCTAssertTrue(prompt.contains("quantityScope"))
    }
}

/// 回包字面量来自 HoloBackend/tests/chat.test.js 的数量协商网关夹具。
/// 改请求或 extractedData 契约时需要同步后端、iOS 和这一组对拍。
final class IntentQuantityContractTests: XCTestCase {
    private let mainland = Locale(identifier: "zh_CN")

    func testNegotiatedAndLegacyJSONBothReadOriginalQuantity() throws {
        let decoder = JSONDecoder()
        let modern = #"""
        {"mode":"single_action","items":[{"id":"weight","intent":"record_weight","confidence":0.99,"extractedData":{"weight":"83","unit":"kg","quantityQuote":"八十三公斤","quantityScope":"体重八十三公斤"}}],"needsClarification":false}
        """#
        let legacy = #"""
        {"mode":"single_action","items":[{"id":"weight","intent":"record_weight","confidence":0.99,"extractedData":{"weight":"83","unit":"kg"}}],"needsClarification":false}
        """#
        XCTAssertEqual(AIQuantityInput.capabilityHeader, "X-Holo-Intent-Quantity")
        XCTAssertEqual(AIQuantityInput.capabilityVersion, "1")
        for payload in [modern, legacy] {
            let batch = try decoder.decode(AIParseBatch.self, from: Data(payload.utf8))
            let item = try XCTUnwrap(batch.first)
            let resolved = try AIQuantityInput.resolve(data: item.extractedData, valueKeys: ["weight"],
                originalInput: "体重八十三公斤", storageUnit: "KG", defaultUnit: "KG",
                names: ["体重"], locale: mainland).get()
            XCTAssertEqual(resolved.value, 83)
            XCTAssertEqual(resolved.unit, "KG")
        }
    }

    func testPhysicalUnitsAndChineseOrCompoundQuantities() throws {
        let cases: [(String, String, Double)] = [
            ("八十三千克", "公斤", 83), ("１６６斤", "KG", 83), ("83", "公斤", 83),
            ("八十三点五千克", "公斤", 83.5), ("一百零六克", "克", 106),
            ("500米", "公里", 0.5), ("1小时30分钟", "分钟", 90), ("一小时又三十分", "分钟", 90),
            ("1,500毫升", "升", 1.5), ("20页", "页", 20), ("五十个", "次", 50),
        ]
        for (quote, storage, expected) in cases {
            let scope = "今天记录" + quote
            let result = AIQuantityInput.resolve(data: ["quantityQuote": quote, "quantityScope": scope], valueKeys: [],
                originalInput: scope, storageUnit: storage, defaultUnit: storage, locale: mainland)
            XCTAssertEqual(try result.get().value, expected, accuracy: 0.000_000_001, quote)
        }
    }

    func testLegacyCanRecoverUnitsAndDurationWithoutTrustingModelConversion() throws {
        let distance = AIQuantityInput.resolve(data: ["habitValue": "500"], valueKeys: ["habitValue"],
            originalInput: "今天跑了500米", storageUnit: "km", defaultUnit: "km", locale: mainland)
        XCTAssertEqual(try distance.get().value, 0.5)
        let compound = AIQuantityInput.resolve(data: ["value": "90"], valueKeys: ["value"],
            originalInput: "今天练琴1小时30分钟", storageUnit: "分钟", defaultUnit: "分钟", locale: mainland)
        XCTAssertEqual(try compound.get().value, 90)
    }

    func testAmbiguousOrInventedQuantityIsRejected() {
        func read(_ original: String, _ quote: String, _ scope: String, unit: String) -> Result<AIQuantityInput.SavedValue, AIQuantityInput.Issue> {
            AIQuantityInput.resolve(data: ["quantityQuote": quote, "quantityScope": scope], valueKeys: [],
                originalInput: original, storageUnit: unit, defaultUnit: unit, locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(read("体重166斤", "166斤", "体重166斤", unit: "kg"), .failure(.incompatibleUnit))
        XCTAssertEqual(read("喝水500毫升", "500毫升", "喝水500毫升", unit: "杯"), .failure(.incompatibleUnit))
        XCTAssertEqual(read("跑步500米", "500", "跑步500米", unit: "km"), .failure(.unverified))
        XCTAssertEqual(read("体重830公斤", "83", "体重830公斤", unit: "kg"), .failure(.unverified))
        XCTAssertEqual(read("体重83公斤，目标是80公斤", "80公斤", "目标是80公斤", unit: "kg"), .failure(.unverified))
        XCTAssertEqual(read("做了20个深蹲，做了20个深蹲", "20个", "做了20个深蹲", unit: "个"), .failure(.unverified))
        XCTAssertEqual(read("体重83公斤", "183公斤", "体重83公斤", unit: "kg"), .failure(.unverified))
        XCTAssertEqual(read("评分30分", "30分", "评分30分", unit: "分钟"), .failure(.incompatibleUnit))
        XCTAssertEqual(read("体重一百六斤", "一百六斤", "体重一百六斤", unit: "kg"), .failure(.unverified))
        XCTAssertEqual(read("喝了三五杯", "三五杯", "喝了三五杯", unit: "杯"), .failure(.unverified))
        XCTAssertEqual(read("阅读20页，刷题15页", "15页", "阅读20页，刷题15页", unit: "页"), .failure(.unverified))
        XCTAssertEqual(read("喝水1/2杯", "2杯", "喝水1/2杯", unit: "杯"), .failure(.unverified))
        XCTAssertEqual(read("练琴03:30分钟", "30分钟", "练琴03:30分钟", unit: "分钟"), .failure(.unverified))
    }

    func testHistoricalUnitsDoNotDependOnTheViewingDeviceRegion() {
        XCTAssertEqual(HoloQuantityUnit.factor(from: "斤", to: "kg", locale: mainland), 0.5)
        XCTAssertNil(HoloQuantityUnit.storedFactor(from: "斤", to: "kg"))
        XCTAssertEqual(HoloQuantityUnit.storedFactor(from: "市斤", to: "kg"), 0.5)
        XCTAssertTrue(HoloQuantityUnit.sameStorageUnit("KG", "公斤"))
        XCTAssertFalse(HoloQuantityUnit.sameStorageUnit("斤", "市斤"))
    }
}
