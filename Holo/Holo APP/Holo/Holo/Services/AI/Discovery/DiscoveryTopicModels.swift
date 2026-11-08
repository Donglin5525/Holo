import Foundation

// 「一个发现」v3 选题契约（2026-11-08 方案 §5.2）。
// 真源：HoloBackend/src/discovery/discoveryTopicController.js——本文件的解码形状
// 必须与服务端响应逐字段一致（跨端接口契约规范；契约测试对拍）。

/// 上送的观察形状摘要：无金额、无健康数值、无正文，只有统计形状。
nonisolated struct DiscoveryTopicCandidate: Codable, Equatable, Hashable, Sendable {
    let id: String
    let domain: String
    let kind: String
    let direction: String
    var label: String?
    var freshness: String?
    var topicKey: String?
    /// 该观察可提供的空位白名单（模型只能引用这些名字）。
    var slots: [String]

    enum CodingKeys: String, CodingKey {
        case id, domain, kind, direction, label, freshness, topicKey, slots
    }

    init(id: String, domain: String, kind: String, direction: String,
         label: String? = nil, freshness: String? = nil, topicKey: String? = nil,
         slots: [String]) {
        self.id = id; self.domain = domain; self.kind = kind; self.direction = direction
        self.label = label; self.freshness = freshness; self.topicKey = topicKey; self.slots = slots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        kind = try c.decode(String.self, forKey: .kind)
        direction = try c.decode(String.self, forKey: .direction)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        freshness = try c.decodeIfPresent(String.self, forKey: .freshness)
        topicKey = try c.decodeIfPresent(String.self, forKey: .topicKey)
        slots = try c.decodeIfPresent([String].self, forKey: .slots) ?? []
    }
}

nonisolated struct DiscoveryTopicRequestBody: Codable, Equatable, Sendable {
    var requestId: String
    var language: String
    var poolFingerprint: String?
    var recentTopics: [String]
    var candidates: [DiscoveryTopicCandidate]
}

/// 服务端选中的观察 + 带空位文案模板（数字由本机回填，模型全程看不到数值）。
nonisolated struct DiscoveryTopicSelection: Codable, Equatable, Sendable {
    let observationId: String
    let angle: String
    var reasonCode: String?
    let titleTemplate: String
    let bodyTemplate: String
}

nonisolated struct DiscoveryTopicResponse: Decodable, Sendable {
    let protocolVersion: Int
    let status: String
    let selection: DiscoveryTopicSelection?
    let noneReason: String?
    var degraded: Bool?
    var promptVersion: Int?
    var replayed: Bool?
    var requestId: String?
}
