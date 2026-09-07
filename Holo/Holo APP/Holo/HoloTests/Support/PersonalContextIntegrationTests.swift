//
//  PersonalContextIntegrationTests.swift
//  HoloTests
//
//  通用个人情境（PersonalContext）专用 XCTest 桥接 wrapper。
//
//  桥接生成器 scripts/generate-standalone-xctest-bridge.rb 已从 git 历史（07e4190b3）恢复。
//  本轮不整体重生成 StandaloneExecutableBridgeTests：现存 17 个裸 @main 历史套件未挂测试
//  target，直接吸收会让桥接文件引用未接线符号而编译失败；该收口属于 QA 第 10 轮范围。
//  按实施方案 15.4，本轮新增套件用此专用 wrapper 桥接，不手改自动生成产物。
//

import XCTest
@testable import Holo

final class PersonalContextIntegrationTests: XCTestCase {
    func test_001_HoloPersonalContextControlsStandaloneTests() throws {
        // 来源：Services/AI/PersonalContext/HoloPersonalContextControlsStandaloneTests.swift
        try HoloPersonalContextControlsStandaloneTests.main()
    }
    func test_002_PersonalContextCodableStandaloneTests() throws {
        // 来源：Services/AI/PersonalContext/PersonalContextCodableStandaloneTests.swift
        try PersonalContextCodableStandaloneTests.main()
    }
    func test_003_PersonalContextIdentityStandaloneTests() throws {
        // 来源：Services/AI/PersonalContext/PersonalContextIdentityStandaloneTests.swift
        try PersonalContextIdentityStandaloneTests.main()
    }
    func test_004_ContextAccessStandaloneTests() throws {
        // 来源：Services/AI/PersonalContext/ContextAccessStandaloneTests.swift
        try ContextAccessStandaloneTests.main()
    }
    func test_005_ContextExtractionStandaloneTests() async throws {
        // 来源：Services/AI/PersonalContext/ContextExtractionStandaloneTests.swift
        try await ContextExtractionStandaloneTests.main()
    }
    func test_006_ContextExtractorOrchestratorStandaloneTests() async throws {
        // 来源：Services/AI/PersonalContext/ContextExtractorOrchestratorStandaloneTests.swift
        try await ContextExtractorOrchestratorStandaloneTests.main()
    }
    func test_007_ContextRetrievalStandaloneTests() async throws {
        // 来源：Services/AI/PersonalContext/ContextRetrievalStandaloneTests.swift
        try await ContextRetrievalStandaloneTests.main()
    }
    func test_008_ContextPlanStandaloneTests() async throws {
        // 来源：Services/AI/PersonalContext/ContextPlanStandaloneTests.swift
        try await ContextPlanStandaloneTests.main()
    }
}
