//
//  ASRAudioChunkingPlanTests.swift
//  HoloTests
//
//  Qwen-ASR 音频分片策略测试
//

import XCTest
@testable import Holo

final class ASRAudioChunkingPlanTests: XCTestCase {

    func testPCM16kMonoUsesOneHundredMillisecondChunks() {
        let plan = ASRAudioChunkingPlan(sampleRate: 16_000, bytesPerSample: 2, chunkDuration: 0.1)

        XCTAssertEqual(plan.chunkSizeBytes, 3_200)
    }

    func testTenSecondPCMIsSplitIntoSmallRealtimeChunks() {
        let plan = ASRAudioChunkingPlan(sampleRate: 16_000, bytesPerSample: 2, chunkDuration: 0.1)
        let chunks = plan.ranges(forByteCount: 320_000)

        XCTAssertEqual(chunks.count, 100)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 3_200 })
        XCTAssertEqual(chunks.first, 0..<3_200)
        XCTAssertEqual(chunks.last, 316_800..<320_000)
    }
}
