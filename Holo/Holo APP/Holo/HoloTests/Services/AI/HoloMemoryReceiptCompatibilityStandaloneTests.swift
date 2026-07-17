import Foundation

@main
struct HoloMemoryReceiptCompatibilityStandaloneTests {
    static func main() throws {
        let legacyJSON = Data("""
        [{
          "id":"legacy-receipt",
          "kind":"write",
          "channel":"insight",
          "memoryIDs":["memory-1"],
          "message":"旧回执",
          "createdAt":"2026-07-15T12:00:00Z"
        }]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode([HoloMemoryReceipt].self, from: legacyJSON)
        guard legacy.count == 1,
              legacy[0].adoptionKind == nil,
              legacy[0].batchKey == nil,
              legacy[0].readAt == nil,
              legacy[0].handledAt == nil else {
            fatalError("旧回执缺少新字段时必须兼容解码")
        }

        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let current = HoloMemoryReceipt(
            id: "current-receipt",
            kind: .write,
            channel: .chat,
            memoryIDs: ["memory-2"],
            message: "新回执",
            createdAt: now,
            adoptionKind: .automaticallyAdopted,
            batchKey: "batch-1",
            readAt: now,
            handledAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try decoder.decode(
            HoloMemoryReceipt.self,
            from: encoder.encode(current)
        )
        guard roundTrip == current else {
            fatalError("新回执字段必须稳定往返")
        }

        print("HoloMemoryReceiptCompatibilityStandaloneTests passed: 2 assertions")
    }
}
