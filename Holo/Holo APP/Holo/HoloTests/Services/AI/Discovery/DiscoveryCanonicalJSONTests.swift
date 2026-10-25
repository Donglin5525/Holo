//
//  DiscoveryCanonicalJSONTests.swift
//  HoloTests
//
//  双端确定性序列化测试：JS 向量锁定 + 键序/转义/代理对/尾部垃圾。
//  待挂载 HoloTests target（由主会话统一挂载）。
//

// 待挂载 HoloTests target
import XCTest
@testable import Holo

final class DiscoveryCanonicalJSONTests: XCTestCase {

    /// JS 侧 canonicalSha256 生成的向量（含中文/emoji/嵌套/空数组），2026-10-23。
    /// 改任何一端序列化规则必须重新生成并双侧更新（DiscoveryCanonicalJSON.parityVectorSHA256）。
    private static let parityVectorJSON = #"{"bodyClaimIDs":["C01-body"],"candidateID":"C01","claims":[{"citations":[{"evidenceID":"E01","quote":"今天先出去走了十分钟"},{"evidenceID":"E02","quote":"今晚只翻了两页"}],"claimID":"C01-title","kind":"observation","metricIDs":["M01"],"text":"这两次重新开始，你都把第一步变轻了。🙂"},{"citations":[{"evidenceID":"E01","quote":"今天先出去走了十分钟"}],"claimID":"C01-body","kind":"fact","metricIDs":[],"text":"恢复运动时先走十分钟，重新阅读时先翻两页。"}],"comparisonPeriods":[],"counterSearch":[{"anchorRefs":[],"domains":["thought"],"keywords":["重新开始","没有继续"]}],"scopeKind":"two_episodes","sensitivity":"non_sensitive","subjectKey":"lighter-start","supportEvidenceIDs":["E01","E02"],"timeRange":{"end":"2026-10-17T00:00:00+08:00","start":"2026-10-08T00:00:00+08:00"},"titleClaimID":"C01-title","type":"two_episodes"}"#

    func test_跨端向量_hash与canonical串完全一致() throws {
        let value = try DiscoveryCanonicalJSON.parse(Data(Self.parityVectorJSON.utf8))
        XCTAssertEqual(
            DiscoveryCanonicalJSON.canonicalSha256(value),
            DiscoveryCanonicalJSON.parityVectorSHA256,
            "Swift canonical hash 与 JS 向量漂移——双端契约破坏"
        )
        XCTAssertEqual(DiscoveryCanonicalJSON.canonicalString(value), Self.parityVectorJSON)
    }

    func test_键序_UTF16码元升序与数组保序() throws {
        // UTF-16 序：ASCII 大写 < ASCII 小写 < 中文；数组保持原始顺序
        let json = #"{"b":1,"a":[3,1,2],"啊":0}"#
        let value = try DiscoveryCanonicalJSON.parse(Data(json.utf8))
        XCTAssertEqual(DiscoveryCanonicalJSON.canonicalString(value), #"{"a":[3,1,2],"b":1,"啊":0}"#)
    }

    func test_转义_短形式与控制字符与代理对() throws {
        let text = "a\nb\"c\\d\te\u{01}f😀"
        let value = DiscoveryJSONValue.string(text)
        let encoded = DiscoveryCanonicalJSON.canonicalString(value)
        // 解析回读必须无损（代理对/转义往返）
        let round = try DiscoveryCanonicalJSON.parse(Data(encoded.utf8))
        XCTAssertEqual(round, value)
        XCTAssertTrue(encoded.contains("\\n"))
        XCTAssertTrue(encoded.contains("\\\""))
        XCTAssertTrue(encoded.contains("\\\\"))
        XCTAssertTrue(encoded.contains("😀"), "emoji 原样输出不转义为 \\u 序列")
    }

    func test_数字_整数直接十进制与负零归一() throws {
        let value = DiscoveryJSONValue.object([
            ("int", .number(.int(-42))),
            ("zero", .number(.double(-0.0))),
        ])
        XCTAssertEqual(DiscoveryCanonicalJSON.canonicalString(value), #"{"int":-42,"zero":0}"#)
    }

    func test_解析_尾部垃圾拒绝() throws {
        XCTAssertThrowsError(try DiscoveryCanonicalJSON.parse(Data(#"{"a":1} {"b":2}"#.utf8)))
        XCTAssertThrowsError(try DiscoveryCanonicalJSON.parse(Data(#"{"a":1}trash"#.utf8)))
    }

    func test_解析_布尔与null与浮点() throws {
        let value = try DiscoveryCanonicalJSON.parse(Data(#"{"t":true,"f":false,"n":null,"d":1.5}"#.utf8))
        XCTAssertEqual(DiscoveryCanonicalJSON.canonicalString(value), #"{"d":1.5,"f":false,"n":null,"t":true}"#)
    }
}
