//
//  DiscoveryContractTests.swift
//  HoloTests
//
//  「一个发现」跨端契约回归（2026-10-28 事故设立）：
//  事故 = EnableResponse.grant 被声明为 String，而后端返回嵌套对象，
//  开启请求服务端已成功入库、客户端却解码失败误报「无法开启」；
//  全部单测因 mock 直接构造 Swift 结构体、绕过 JSON 解码而全绿（假绿）。
//
//  本文件用**后端真实响应形状的 JSON 字面量**逐端点对拍 iOS 解码模型。
//  字面量唯一真源 = HoloBackend/src/discovery/discoveryController.js 与
//  discoveryControlStore.js 的 context.json(...) 返回体；capabilities 为
//  2026-10-28 生产实测原文。改任何一端，必须同步改另一端与本文件——
//  禁止为了让测试变绿而单方面修改这里的字面量去迁就 iOS 模型。
//

import XCTest
@testable import Holo

final class DiscoveryContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - capabilities（生产实测原文，policyVersion 为字符串 "v1"）

    func testCapabilitiesDecodesProductionPayload() throws {
        // 2026-10-28 GET https://api.holoapp.cn/v1/discovery/capabilities 原文
        let payload = """
        {"protocolVersion":1,"enabled":true,"policyVersion":"v1","allowedDomains":["thought","task","habit"],"budget":{"runsPerDay":1,"candidateMaxTokens":3072,"verifyMaxTokens":4096,"inputBudgetTokens":16384}}
        """
        let r = try decode(DiscoveryClient.CapabilitiesResponse.self, payload)
        XCTAssertEqual(r.protocolVersion, 1)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.policyVersion, 1, "字符串 v1 必须被兼容为数字 1")
        XCTAssertEqual(r.allowedDomains, ["thought", "task", "habit"])
        XCTAssertEqual(r.budget.runsPerDay, 1)
        XCTAssertEqual(r.budget.candidateMaxTokens, 3072)
        XCTAssertEqual(r.budget.inputBudgetTokens, 16384)
    }

    // MARK: - control（controller GET /v1/discovery/control）

    func testControlDecodesBackendShape() throws {
        let payload = """
        {"enabled":true,"revision":2,"ownerDeviceId":"F50B4915-3411-472A-9C13-E1D5E85FEDB4","scopeRevision":1,"allowedDomains":["habit","task","thought"],"consentDocVersion":"discovery-consent-v1"}
        """
        let r = try decode(DiscoveryClient.ControlResponse.self, payload)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.revision, 2)
        XCTAssertEqual(r.ownerDeviceId, "F50B4915-3411-472A-9C13-E1D5E85FEDB4")
        XCTAssertEqual(r.allowedDomains, ["habit", "task", "thought"])
        XCTAssertEqual(r.consentDocVersion, "discovery-consent-v1")
    }

    // MARK: - enable（2026-10-28 事故现场：grant 为嵌套对象，绝不可再当 String）

    func testEnableDecodesGrantObject() throws {
        // discoveryControlStore.js enable() 构造的 grant：五字段对象
        let payload = """
        {"enabled":true,"revision":2,"scopeRevision":1,"allowedDomains":["habit","task","thought"],"ownerDeviceId":"F50B4915-3411-472A-9C13-E1D5E85FEDB4","grant":{"deviceId":"F50B4915-3411-472A-9C13-E1D5E85FEDB4","revision":2,"scopeRevision":1,"dayKey":"2026-10-28","leaseExpiresAt":1793118588994},"replayed":false}
        """
        let r = try decode(DiscoveryClient.EnableResponse.self, payload)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.revision, 2)
        let grant = try XCTUnwrap(r.grant, "grant 为对象时必须解码成功——2026-10-28 事故回归")
        XCTAssertEqual(grant.deviceId, "F50B4915-3411-472A-9C13-E1D5E85FEDB4")
        XCTAssertEqual(grant.revision, 2)
        XCTAssertEqual(grant.scopeRevision, 1)
        XCTAssertEqual(grant.dayKey, "2026-10-28")
        XCTAssertEqual(grant.leaseExpiresAt, 1_793_118_588_994)
        XCTAssertFalse(r.replayed!)
    }

    func testEnableDecodesReplayVariant() throws {
        // 幂等重放（discoveryControlStore.js replayOrThrow 命中）：grant 取首次登记结果
        let payload = """
        {"enabled":true,"revision":2,"scopeRevision":1,"allowedDomains":["thought"],"ownerDeviceId":"dev-1","grant":{"deviceId":"dev-1","revision":1,"scopeRevision":1,"dayKey":"2026-10-27","leaseExpiresAt":1793032000000},"replayed":true}
        """
        let r = try decode(DiscoveryClient.EnableResponse.self, payload)
        XCTAssertEqual(r.grant?.dayKey, "2026-10-27")
        XCTAssertTrue(r.replayed!)
    }

    // MARK: - disable / scope（控制面其余两写端点）

    func testDisableDecodesBackendShape() throws {
        let payload = """
        {"enabled":false,"revision":3,"scopeRevision":1,"replayed":false}
        """
        let r = try decode(DiscoveryClient.DisableResponse.self, payload)
        XCTAssertFalse(r.enabled)
        XCTAssertEqual(r.revision, 3)
        XCTAssertEqual(r.scopeRevision, 1)
    }

    func testScopeDecodesBackendShape() throws {
        let payload = """
        {"enabled":true,"revision":3,"scopeRevision":2,"allowedDomains":["thought"],"replayed":false}
        """
        let r = try decode(DiscoveryClient.ScopeResponse.self, payload)
        XCTAssertEqual(r.scopeRevision, 2)
        XCTAssertEqual(r.allowedDomains, ["thought"])
    }

    // MARK: - runs（controller POST /v1/discovery/runs）

    func testCreateRunDecodesBackendShape() throws {
        let payload = """
        {"runID":"run-8f30","runToken":"rtok","status":"reserved","controlRevision":2,"scopeRevision":1,"dayKey":"2026-10-28","leaseExpiresAt":1793118588994,"leaseSeconds":600,"stageBudget":{"candidates":1,"verify":1},"replayed":false}
        """
        let r = try decode(DiscoveryClient.CreateRunResponse.self, payload)
        XCTAssertEqual(r.runID, "run-8f30")
        XCTAssertEqual(r.status, "reserved")
        XCTAssertEqual(r.dayKey, "2026-10-28")
        XCTAssertEqual(r.leaseSeconds, 600)
        XCTAssertEqual(r.stageBudget.candidates, 1)
        XCTAssertEqual(r.stageBudget.verify, 1)
    }

    // MARK: - 阶段端点（candidates/verify 共用 StageResponse；candidates 多 candidatesHash）

    func testStageResponseDecodesBackendShape() throws {
        let payload = """
        {"runID":"run-8f30","stage":"candidates","envelope":{"candidates":[]},"promptType":"discovery_candidate_v1","promptVersion":2,"model":{"provider":"deepseek","model":"deepseek-chat"},"usage":{"promptTokens":100,"completionTokens":50,"totalTokens":150},"replayed":false,"candidatesHash":"a1b2c3"}
        """
        let r = try decode(DiscoveryClient.StageResponse.self, payload)
        XCTAssertEqual(r.runID, "run-8f30")
        XCTAssertEqual(r.stage, "candidates")
        XCTAssertEqual(r.promptVersion, 2)
        XCTAssertEqual(r.model?.provider, "deepseek")
        XCTAssertEqual(r.usage?.totalTokens, 150)
        XCTAssertEqual(r.candidatesHash, "a1b2c3")
    }

    // MARK: - cancel（controller POST /v1/discovery/runs/:id/cancel）

    func testCancelDecodesBackendShape() throws {
        let payload = """
        {"runID":"run-8f30","status":"cancelled","alreadyClosed":false}
        """
        let r = try decode(DiscoveryClient.CancelResponse.self, payload)
        XCTAssertEqual(r.runID, "run-8f30")
        XCTAssertEqual(r.status, "cancelled")
        XCTAssertFalse(r.alreadyClosed)
    }

    // MARK: - 双端共用夹具对拍（2026-11-01 独立诊断报告问题1）
    // 夹具真源 = HoloBackend/tests/fixtures/discovery-contract-candidates.json（后端测试读同一份）。
    // 规则：server=pass 的用例，其 deliveredEnvelope（服务端修复层实际交付形状）必须能通过
    // Swift 严格解码+校验（decodeValidatedCandidateEnvelope）——防「后端 200、客户端
    // schema_invalid 锁当天」的契约缝隙（claimCoverageIncomplete / invalidDateTime 实锤起源）。

    func testContractFixtureServerDeliveredIsConsumableByClient() throws {
        // #filePath 上溯到仓库根（Discovery 目录 → … → HOLO），读双端共用夹具
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = here // HoloTests/Services/AI/Discovery
            .deletingLastPathComponent()  // …/AI
            .deletingLastPathComponent()  // …/Services
            .deletingLastPathComponent()  // HoloTests
            .deletingLastPathComponent()  // Holo（target 目录）
            .deletingLastPathComponent()  // Holo APP
            .deletingLastPathComponent()  // Holo（工程根目录）
            .deletingLastPathComponent()  // HOLO（仓库根）
        let fixtureURL = repoRoot
            .appendingPathComponent("HoloBackend/tests/fixtures/discovery-contract-candidates.json")
        let data = try XCTUnwrap(try? Data(contentsOf: fixtureURL), "夹具文件缺失：\(fixtureURL.path)")

        // 直接用 JSONSerialization（夹具是动态 JSON，不用强类型解码）
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(json["cases"] as? [[String: Any]])
        var consumed = 0
        for item in cases {
            guard (item["server"] as? String) == "pass",
                  let delivered = item["deliveredEnvelope"] else { continue }
            let envelopeData = try JSONSerialization.data(withJSONObject: delivered)
            do {
                _ = try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: envelopeData)
                consumed += 1
            } catch {
                XCTFail("服务端交付形状被 Swift 严格校验拒绝（契约缝隙）：\(item["name"] ?? "?") → \(error)")
            }
        }
        XCTAssertGreaterThan(consumed, 0, "夹具至少应有一条 server=pass 的交付用例")
    }

}
