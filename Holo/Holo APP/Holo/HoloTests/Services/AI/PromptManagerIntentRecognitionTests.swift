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
}
