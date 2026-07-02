import XCTest
@testable import Holo

final class PromptManagerIntentRecognitionTests: XCTestCase {
    func testIntentRecognitionDefaultPromptRequiresTransactionDateForFinanceRecords() {
        let prompt = PromptManager.shared.loadDefaultTemplate(.intentRecognition)

        XCTAssertTrue(prompt.contains("transactionDate"))
        XCTAssertTrue(prompt.contains("昨天=交易日-1"))
        XCTAssertTrue(prompt.contains("记账日期写入 transactionDate"))
    }
}
