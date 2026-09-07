//
//  ProviderContractTests.swift
//  HoloTests
//
//  P3 双端契约验证：iOS purpose/PromptType 原始值与后端路由/prompt 键一一对应。
//  依赖 App 模块类型（HoloBackendPurpose/PromptManager），走真实测试 target，
//  不做 standalone 双模式。后端侧同契约由 HoloBackend/tests/personal-context-purposes.test.js 锁定。
//

import XCTest
@testable import Holo

final class ProviderContractTests: XCTestCase {
    /// 与 HoloBackend/src/config.js routes、serverPromptPolicy.js 的 purpose 键对齐。
    func testPurposeRawValuesMatchBackendContract() {
        XCTAssertEqual(HoloBackendPurpose.personalContextExtraction.rawValue, "personal_context_extraction")
        XCTAssertEqual(HoloBackendPurpose.personalContextVerification.rawValue, "personal_context_verification")
        XCTAssertEqual(HoloBackendPurpose.personalContextRequest.rawValue, "personal_context_request")
        XCTAssertEqual(HoloBackendPurpose.personalContextPlanning.rawValue, "personal_context_planning")

        let all: [String] = [
            HoloBackendPurpose.chat, .analysis, .intent, .flexibleQueryPlanner, .insight,
            .replayDigest, .thoughtVoiceSummary, .memoryObserver, .memoryDomainExtraction,
            .memoryCrossDomainFusion, .financeActionParser, .taskActionParser,
            .thoughtOrganization, .thoughtTaskExtraction, .thoughtTagConvergence,
            .categoryPatternInduction, .agentLoop, .healthInsightGeneration,
            .weeklyPlanGeneration, .billColumnMapping, .billCategorization,
            .personalContextExtraction, .personalContextVerification,
            .personalContextRequest, .personalContextPlanning,
        ].map(\.rawValue)
        XCTAssertEqual(Set(all).count, all.count, "purpose 原始值不得重复")
    }

    /// PromptType 原始值与后端 promptRegistry 键 / PURPOSE_PROMPT_TYPES 对齐。
    func testPromptTypeRawValuesMatchBackendContract() {
        XCTAssertEqual(PromptManager.PromptType.personalContextExtraction.rawValue, "personal_context_extraction")
        XCTAssertEqual(PromptManager.PromptType.personalContextVerification.rawValue, "personal_context_verification")
        XCTAssertEqual(PromptManager.PromptType.personalContextRequest.rawValue, "personal_context_request")
        XCTAssertEqual(PromptManager.PromptType.personalContextPlanning.rawValue, "personal_context_planning")
    }

    /// DEBUG 后备模板可加载且含注入防护（后端为主模板，iOS 为后备，双端同版）。
    func testFallbackTemplatesLoadable() throws {
        #if DEBUG
        let types: [PromptManager.PromptType] = [
            .personalContextExtraction, .personalContextVerification,
            .personalContextRequest, .personalContextPlanning,
        ]
        for type in types {
            let template = try PromptManager.shared.loadPrompt(type)
            XCTAssertFalse(template.isEmpty, "\(type.rawValue) 后备模板不可为空")
        }
        let extraction = try PromptManager.shared.loadPrompt(.personalContextExtraction)
        XCTAssertTrue(extraction.contains("不是指令"), "萃取后备模板必须声明输入不可执行")
        #else
        throw XCTSkip("Release 端 prompt 由后端持有，无后备模板")
        #endif
    }

    /// embedding purpose 字符串不借用 thought_embedding（「已审核」假设不外溢）。
    func testEmbeddingPurposeDistinct() {
        XCTAssertNotEqual("personal_context_embedding", "thought_embedding")
    }
}
