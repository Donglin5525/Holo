import Foundation

// 「一个发现」v4 洞察契约（2026-11-20 方案总纲 §5，P1 冻结）。
//
// 双端共同依赖的数据形状：
// - InsightInputPacket：端侧组装的去标识化输入包（画像条目 + 七域特征 + 用户意图），
//   作为 user message JSON 上送（与 portrait_synthesis 同模式，后端 prompt 里称 data）。
// - InsightDraft：后端闸门放行后的最终洞察（headline/insight 无数字，evidence 模板
//   带 {slot} 空位，真实数值由端侧 SlotValueTable 回填——模型自始至终看不到数值）。
//
// 契约纪律（docs/standards/跨端接口契约规范.md）：
// - 响应形状真源 = 后端 src/discovery/insightGate.js（模型原始输出经闸门修复/重写后
//   以本形状发出）；iOS 本文件是其强类型翻译，字段与枚举逐一对齐，不做无差别宽容。
// - 改任一端必须同步另一端与 DiscoveryInsightContractTests 字面量。

// MARK: - 输入包（§5.1）

nonisolated struct InsightInputPacket: Codable, Equatable, Sendable {
    /// 数量上限（总纲 §5.1；后端 insightGate 同值校验，超限由端侧按「新近+置信度」截断）。
    static let portraitLimit = 12
    static let featureLimit = 30
    static let userIntentLimit = 10

    let schemaVersion: Int
    let kind: String
    let requestId: String
    let window: Window
    let portrait: [PortraitItem]
    let features: [FeatureItem]
    let userIntents: [UserIntentItem]
    let recentTopics: [String]
    let rejectedAngles: [String]

    nonisolated struct Window: Codable, Equatable, Sendable {
        let days: Int
    }

    nonisolated struct PortraitItem: Codable, Equatable, Sendable {
        let id: String
        /// PortraitDimension rawValue：crossDomainInsight|recentState|longTermPattern|preference|identity
        let dimension: String
        /// confirmed|inferred
        let confidence: String
        let statement: String
        let evidenceSummary: String
        let sourceDomains: [String]
    }

    nonisolated struct FeatureItem: Codable, Equatable, Sendable {
        let id: String
        /// finance|health|habit|thought|task|goal|profile
        let domain: String
        /// 去标识化的特征描述，不含数字
        let description: String
        /// up|down|stable|divergent
        let direction: String
        let slots: [Slot]
    }

    nonisolated struct Slot: Codable, Equatable, Sendable {
        /// 槽位名（evidence template 里 {name} 引用）
        let name: String
        /// 单位类型（weeks/percent/hours…，仅提示模型槽位语义）
        let unit: String
    }

    nonisolated struct UserIntentItem: Codable, Equatable, Sendable {
        let id: String
        /// goal|habit|thought
        let source: String
        /// 去标识化后的意图短句
        let text: String
    }

    func encodeJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 洞察草案（§5.2）

nonisolated struct InsightDraft: Equatable, Sendable {
    let schemaVersion: Int
    let selected: Selected?
    /// 后端取值：none_worthwhile / insufficient_data / gate_rejected / disabled / quota_exhausted
    /// （前两个来自模型，后三个由后端闸门/开关/预算墙合成；selected 与 noneReason 互斥）。
    let noneReason: String?

    nonisolated struct Selected: Equatable, Sendable {
        let angleKey: String
        /// ≤18 字，无数字
        let headline: String
        /// ≤90 字，判断 + 推测性解释，无数字
        let insight: String
        /// 1～3 条；refId 必须是输入中存在的 feature/portrait id，{slot} 属于该 feature slots
        let evidence: [EvidenceLine]
        /// ≤30 字的提问或可选小动作，可为空串
        let prompt: String
        /// 命中的加分维度（D1~D4，至少两项才放行）
        let criteria: [String]
        let sourceDomains: [String]
    }

    nonisolated struct EvidenceLine: Equatable, Sendable {
        let refId: String
        /// ≤40 字，可含 {slot} 空位
        let template: String
    }
}

extension InsightDraft: Decodable {
    nonisolated enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, selected, noneReason
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        // kind 字段仅作标识，不参与消费（宽进：闸门偶发漏写不炸解码）。
        _ = try c.decodeIfPresent(String.self, forKey: .kind)
        selected = try c.decodeIfPresent(Selected.self, forKey: .selected)
        noneReason = try c.decodeIfPresent(String.self, forKey: .noneReason)
        guard selected != nil || noneReason != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "insightDraft: selected 与 noneReason 二者必有其一"
            ))
        }
    }

    nonisolated init(selected: Selected?, noneReason: String?) {
        self.schemaVersion = 1
        self.selected = selected
        self.noneReason = noneReason
    }
}

extension InsightDraft.Selected: Decodable {}
extension InsightDraft.EvidenceLine: Decodable {}

nonisolated enum InsightDraftParser {
    enum ParseError: Error, Equatable {
        case emptyResponse
        case invalidJSON
    }

    /// 兼容模型/闸门偶发 ```json 围栏，提取最外层 JSON 对象并解码（与 PortraitDeltaParser 同法）。
    static func parse(from raw: String) throws -> InsightDraft {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.emptyResponse }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else {
            throw ParseError.invalidJSON
        }
        guard let data = String(trimmed[start...end]).data(using: .utf8),
              let draft = try? JSONDecoder().decode(InsightDraft.self, from: data) else {
            throw ParseError.invalidJSON
        }
        return draft
    }
}

// MARK: - 数字纪律（双端共享口径）

/// 判断句数字禁令：headline / insight / prompt 中不得出现任何数字——阿拉伯数字、
/// 全角数字、中文数字都算（总纲 §2 硬规则；与后端 insightGate 同一字符集+复合模式，
/// 测试样例双端共用）。
/// 字符集不含「之/几/分」三个裸字（v3 字符集的坑：「之前/几乎/部分」被整句误杀，
/// 2026-11-20 实测「入睡时间比之前更晚」误报定谳）；分数表达用复合模式「几分之」，
/// 另补「半」数量词（半个月/半杯）。
nonisolated enum InsightNumberDiscipline {
    static let numeralCharacters = "0123456789０１２３４５６７８９零一二两三四五六七八九十百千万亿半"
    static let numeralPhrases = ["几分之"]

    nonisolated static func containsNumerals(in text: String) -> Bool {
        let banned = CharacterSet(charactersIn: numeralCharacters)
        if text.unicodeScalars.contains(where: { banned.contains($0) }) { return true }
        return numeralPhrases.contains { text.contains($0) }
    }

    /// 提取 ASCII 数字串（回填后「证据里的数字必须全部来自 slot 值」比对用，
    /// 口径与 v3 DiscoveryTopicService.extractNumbers 一致：只认 ASCII 数字）。
    nonisolated static func asciiNumberRuns(in text: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        for ch in text {
            if ch.isASCII && ch.isNumber {
                current.append(ch)
            } else {
                if !current.isEmpty { out.insert(current) }
                current = ""
            }
        }
        if !current.isEmpty { out.insert(current) }
        return out
    }
}

// MARK: - 端侧槽位真值表（不上传，§I2）

/// `[featureId: [slotName: 格式化后的值]]`——真实数值只留本机，
/// 供 DiscoveryInsightCardBuilder 回填 evidence 模板。
nonisolated struct SlotValueTable: Equatable, Sendable {
    var values: [String: [String: String]] = [:]

    nonisolated init() {}

    nonisolated init(values: [String: [String: String]]) {
        self.values = values
    }

    nonisolated func slotValues(for featureId: String) -> [String: String] {
        values[featureId] ?? [:]
    }
}
