# 04 · iOS 实施

## 通用约定（每个任务都适用）

**路径简写**

| 简写 | 实际路径（相对仓库根 `/Users/tangyuxuan/Desktop/Claude/HOLO`） |
|---|---|
| `APP/` | `Holo/Holo APP/Holo/Holo/` |
| `TESTS/` | `Holo/Holo APP/Holo/HoloTests/` |
| `BUILD/` | `Holo/Holo APP/Holo/BuildScripts/` |

**构建与测试**（同一时间只能有一个 xcodebuild）

```bash
cd "/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/BuildScripts"
./holo_build.py build
# 测试：先取一个可用模拟器 UDID
xcrun simctl list devices available | grep -m1 "iPhone"
./holo_build.py test --dest "platform=iOS Simulator,id=<UDID>" --only HoloTests/DiscoveryInsightBuilderTests
```

- `build` 不编译测试 target，**改了测试必须跑 `test`**。
- 测试 `--only` 的类名：`DiscoveryInsightBuilderTests`、`DiscoveryInsightContractTests`。
- 模拟器无头运行（skill `holo-sim-headless`），不要打开模拟器窗口。

**编码红线**：见 00-README「全局红线」。另外：
- 新文件放在指定目录即可，主 target 是文件系统同步型，会自动编进去；**不要新建测试文件**。
- Swift 新类型如果被非 MainActor 的纯逻辑用到，照现有文件写 `nonisolated`。
- 代码注释用中文，标注来源「2026-11-21 Plus 分层 Ixx」。
- 文案逐字照抄 `01-产品方案与文案真源.md`，代码里在文案旁注释编号，如 `// C21`。

**提交**：每个任务一个 commit，只 `git add` 本任务列出的文件。格式：`feat(iOS): 中文描述`。

---

## I0 · 开工检查（每个 iOS 任务开始前都做）

```bash
cd /Users/tangyuxuan/Desktop/Claude/HOLO
git status --short -- "Holo/Holo APP/Holo/Holo/Services/AI/Discovery" "Holo/Holo APP/Holo/Holo/Views/Chat/DiscoveryReviewSheet.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/DiscoveryInsightCardView.swift" "Holo/Holo APP/Holo/Holo/Views/MemoryCenter" "Holo/Holo APP/Holo/Holo/Views/Subscription" "Holo/Holo APP/Holo/Holo/Services/Subscription" "Holo/Holo APP/Holo/HoloTests/Services/AI/Discovery"
```

- 只允许出现**本方案前序任务已经提交过之后又被你自己改的文件**（正常情况下应该为空）。
- 出现别的未提交改动 → **停止**，把输出贴进 `07-实施记录.md`，回复东林「目标文件有其他会话未提交的改动，需要先处理」。
- 再跑一次 `./holo_build.py build`，确认开工前是绿的；不绿就停止并报告，不要修别人的编译错误。

---

## I1 · 契约：`quota` 与 `focusFeatureIds`

**依赖**：后端 B1/B2 的字段定义（不需要后端已部署）。
**文件**：`APP/Services/AI/Discovery/V4/DiscoveryInsightContract.swift`、`TESTS/Services/AI/Discovery/DiscoveryInsightContractTests.swift`

### 步骤

1. `InsightInputPacket` 在 `rejectedAngles` 之后加：

```swift
    /// Plus 点名看（2026-11-21 Plus 分层 I1）：1~2 个本包已有的 feature id；nil 时编码省略该键。
    /// 后端 validateInsightPacket 校验存在性，非 Plus 请求由后端丢弃。
    var focusFeatureIds: [String]? = nil
```

   用 `var` + 默认值，现有 `InsightInputPacket(...)` 调用点不用改。合成的 `Encodable` 对可选值用 `encodeIfPresent`，nil 时 JSON 里不会出现这个键。

2. `InsightDraft` 加额度信息：

```swift
    /// 额度信息（2026-11-21 Plus 分层 I1）：后端只在撞墙与送达时附带，其余为 nil。
    let quota: QuotaInfo?

    nonisolated struct QuotaInfo: Codable, Equatable, Sendable {
        let used: Int
        /// 0 = 不限
        let limit: Int
        /// "free" | "plus"（后端判定）
        let tier: String
        /// 下一个名额释放时刻（毫秒时间戳）；未达上限或不限时为 nil
        let resetAt: Int64?

        var resetDate: Date? {
            resetAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        }
    }
```

3. `CodingKeys` 加 `quota`；`init(from:)` 里加 `quota = try c.decodeIfPresent(QuotaInfo.self, forKey: .quota)`。
4. 便利初始化改为 `nonisolated init(selected: Selected?, noneReason: String?, quota: QuotaInfo? = nil)`，并赋值 `self.quota = quota`。
5. 文件头注释的「后端取值」那段补一句：`quota：撞墙与送达时附带（2026-11-21）`。

### 测试（追加到 `DiscoveryInsightContractTests`）

```swift
    // MARK: - 2026-11-21 Plus 分层 I1

    func testDraftDecodesQuotaWhenPresent() throws {
        let raw = #"{"schemaVersion":1,"kind":"insightDraft","selected":null,"noneReason":"quota_exhausted","quota":{"used":1,"limit":1,"tier":"free","resetAt":1764224000000}}"#
        let draft = try InsightDraftParser.parse(from: raw)
        XCTAssertEqual(draft.quota?.used, 1)
        XCTAssertEqual(draft.quota?.tier, "free")
        XCTAssertEqual(draft.quota?.resetDate, Date(timeIntervalSince1970: 1_764_224_000))
    }

    func testDraftQuotaAbsentAndNullReset() throws {
        let noQuota = try InsightDraftParser.parse(from: #"{"schemaVersion":1,"selected":null,"noneReason":"none_worthwhile"}"#)
        XCTAssertNil(noQuota.quota)
        let plus = try InsightDraftParser.parse(from: #"{"schemaVersion":1,"selected":null,"noneReason":"quota_exhausted","quota":{"used":2,"limit":5,"tier":"plus","resetAt":null}}"#)
        XCTAssertNil(plus.quota?.resetDate)
    }

    func testPacketOmitsFocusWhenNilAndEncodesWhenSet() throws {
        var packet = InsightInputPacket(
            schemaVersion: 1, kind: "insightInput", requestId: "r1",
            window: .init(days: 28), portrait: [], features: [], userIntents: [],
            recentTopics: [], rejectedAngles: []
        )
        XCTAssertFalse(packet.encodeJSON()?.contains("focusFeatureIds") ?? true)
        packet.focusFeatureIds = ["f_anomaly_0"]
        XCTAssertTrue(packet.encodeJSON()?.contains(#""focusFeatureIds":["f_anomaly_0"]"#) ?? false)
    }
```

如果测试类里已有构造 `InsightInputPacket` 的辅助函数，可以复用，但不要修改它。

### 验收

`./holo_build.py test --only HoloTests/DiscoveryInsightContractTests` 全绿，新增 3 例执行到。

### 提交

`feat(iOS): 一个发现契约新增额度信息与点名字段`

---

## I2 · 候选构建器：本机短句（不上传）

**文件**：`APP/Services/AI/Discovery/V4/DiscoveryInsightCandidateBuilder.swift`、`TESTS/Services/AI/Discovery/DiscoveryInsightBuilderTests.swift`

### 步骤

1. `Output` 加字段：

```swift
        /// featureId → 用户看得懂的短句（2026-11-21 Plus 分层 I2）。只在本机用于预告问题，
        /// 绝不放进 packet 上传；可以含用户自己的习惯名/消费概念名，但不含数字。
        var teaserPhrases: [String: String] = [:]
```

2. `build(...)` 里声明 `var phrases: [String: String] = [:]`，把 `appendAnomalies / appendHabitTrends / appendFinanceConcepts / appendHealthBaselines` 四个函数的签名各加一个参数 `phrases: inout [String: String]`，调用处传 `&phrases`。**`appendMinerProposals` 不加**（挖掘器不生成短句）。

3. 在每个函数里，`features.append(...)` 之后写短句。**短句逐字按 01 §5 的短句表**：

   - `appendAnomalies`：在 switch 的每个 case 里设一个局部 `var phrase: String?`：
     - `"sleep_short"` → `"最近你睡得比较少"`
     - `"sleep_later", "sleep_late"` → `"最近你睡得越来越晚"`
     - `"activity_drop"` → `"最近你走路、运动少了"`
     - `"numeric_habit_up", "numeric_habit_down"` → `"\(wrappedName(habitName(from: anomaly.summary)))最近记的数值在\(isUp ? "变多" : "变少")"`
     - `default` → `nil`
     在 `features.append` 之后：`if let phrase { setPhrase(phrase, for: id, into: &phrases) }`
   - `appendHabitTrends`：`"\(wrappedName(trend.name))最近打卡比之前\(isUp ? "多了" : "少了")"`
   - `appendFinanceConcepts`：先算 `let base = "你经常买\(wrappedName(concept.concept))"`；若 `concept.dominantBand` 非空，`let withBand = base + "，多在\(band)"`，`withBand` 不含数字就用它，否则用 `base`。
   - `appendHealthBaselines`：睡眠 `isShort ? "最近你睡得比之前短了" : "最近你睡得比之前长了"`；步数 `isUp ? "最近你每天走的路比之前多了" : "最近你每天走的路比之前少了"`。

4. 新增私有工具函数（放在「工具」MARK 下）：

```swift
    /// 短句入表：含数字的直接丢弃（数字纪律与判断句同口径）。
    private static func setPhrase(_ phrase: String, for id: String, into phrases: inout [String: String]) {
        guard !InsightNumberDiscipline.containsNumerals(in: phrase) else { return }
        phrases[id] = phrase
    }
```

5. features 截断（`featureLimit`）之后，只保留还在 features 里的短句：

```swift
        let keptIds = Set(features.map(\.id))
        let keptPhrases = phrases.filter { keptIds.contains($0.key) }
```

   `return Output(packet: packet, slots: slots, teaserPhrases: keptPhrases)`。

6. **不要**改 `description` 的任何文字（那是发给模型的，改了会影响线上效果）。

### 测试（追加到 `DiscoveryInsightBuilderTests`，复用 `makePortraitStore()` / `makeFeaturePacket()`）

```swift
    // MARK: - 2026-11-21 Plus 分层 I2：本机短句

    func testTeaserPhrasesFollowCopyTable() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(), featurePacket: makeFeaturePacket(),
            proposals: [makeMinerProposal()], recentTopics: [], rejectedAngles: []
        ))
        let p = output.teaserPhrases
        XCTAssertEqual(p["f_anomaly_0"], "最近你睡得越来越晚")
        XCTAssertEqual(p["f_anomaly_1"], "「咖啡」最近记的数值在变多")
        XCTAssertEqual(p["f_checkin_0"], "「冥想」最近打卡比之前少了")
        XCTAssertEqual(p["f_concept_0"], "你经常买「猫粮」，多在深夜")
        XCTAssertEqual(p["f_sleep_duration"], "最近你睡得比之前短了")
        XCTAssertEqual(p["f_steps_change"], "最近你每天走的路比之前少了")
        // 挖掘器提案不生成短句
        XCTAssertTrue(p.keys.allSatisfy { !$0.hasPrefix("f_miner_") })
        // 短句不含数字、不进上传包
        XCTAssertTrue(p.values.allSatisfy { !InsightNumberDiscipline.containsNumerals(in: $0) })
        XCTAssertFalse(output.packet.encodeJSON()?.contains("最近你睡得越来越晚") ?? true)
    }
```

**写测试前先核对 id**：在测试里临时打印不允许（禁 print），所以先读 `makeFeaturePacket()`：`anomalies` 顺序是 `sleep_later`、`numeric_habit_up`；`checkins` 里 `读书` 是 flat 会被跳过，`冥想` 是第 0 个（`f_checkin_0`，因为 id 用的是原数组下标——**核对 `appendHabitTrends` 用的是 `enumerated()` 下标还是过滤后下标**，按实际代码改断言里的 id）。

### 验收

`./holo_build.py test --only HoloTests/DiscoveryInsightBuilderTests` 全绿（含既有用例）。

### 提交

`feat(iOS): 一个发现候选构建器生成本机预告短句`

---

## I3 · 预告问题拼装器 `DiscoveryTeaserBuilder`

**文件**：新建 `APP/Services/AI/Discovery/V4/DiscoveryTeaserBuilder.swift`；测试追加到 `TESTS/Services/AI/Discovery/DiscoveryInsightBuilderTests.swift`

### 代码（完整给出，照抄后按需微调格式）

```swift
import Foundation

// 「一个发现」预告问题拼装（2026-11-21 Plus 分层 I3，纯逻辑、可单测）。
//
// 规则真源：docs/_common/plans/2026-11-21-记忆发现打通与Plus分层/01 §5。
// - 原料：本次 packet.features + 本机短句（CandidateBuilder.Output.teaserPhrases）；
// - 不同领域两两配对成「A，同一段时间B。这两件事有关系吗？」，落单的写「A，Holo 想帮你看看是为什么。」；
// - 最多 3 条；排除今天发现卡已经引用的特征；含数字的整条丢弃。
// 这些问题只陈述记录里的事实，不下结论，不调模型。

nonisolated struct DiscoveryTeaserClue: Codable, Equatable, Sendable, Identifiable {
    /// 稳定标识：短句拼接（同一组事实同一个 id，跨天重组包也不变）
    let id: String
    /// 组成本问题的短句（点名时据此反查当前 feature id）
    let phrases: [String]
    /// 对应领域（finance/health/habit…），用于行首图标
    let domains: [String]
    /// 展示文本
    let text: String
}

nonisolated enum DiscoveryTeaserBuilder {
    static let maxClues = 3

    static func build(
        packet: InsightInputPacket,
        phrases: [String: String],
        excludingFeatureIds: Set<String> = []
    ) -> [DiscoveryTeaserClue] {
        var pool: [(phrase: String, domain: String)] = packet.features.compactMap { feature in
            guard !excludingFeatureIds.contains(feature.id), let phrase = phrases[feature.id] else { return nil }
            return (phrase, feature.domain)
        }
        var clues: [DiscoveryTeaserClue] = []
        while !pool.isEmpty && clues.count < maxClues {
            let first = pool.removeFirst()
            let clue: DiscoveryTeaserClue
            if let index = pool.firstIndex(where: { $0.domain != first.domain }) {
                let second = pool.remove(at: index)
                clue = DiscoveryTeaserClue(
                    id: "\(first.phrase)|\(second.phrase)",
                    phrases: [first.phrase, second.phrase],
                    domains: [first.domain, second.domain],
                    text: "\(first.phrase)，同一段时间\(dropFirstRecent(second.phrase))。这两件事有关系吗？"
                )
            } else {
                clue = DiscoveryTeaserClue(
                    id: first.phrase,
                    phrases: [first.phrase],
                    domains: [first.domain],
                    text: "\(first.phrase)，Holo 想帮你看看是为什么。"
                )
            }
            guard !InsightNumberDiscipline.containsNumerals(in: clue.text) else { continue }
            clues.append(clue)
        }
        return clues
    }

    /// 第二句去掉第一个「最近」，避免「最近…，同一段时间最近…」。
    static func dropFirstRecent(_ phrase: String) -> String {
        guard let range = phrase.range(of: "最近") else { return phrase }
        var result = phrase
        result.removeSubrange(range)
        return result
    }
}
```

### 测试（追加到 `DiscoveryInsightBuilderTests`）

```swift
    // MARK: - 2026-11-21 Plus 分层 I3：预告问题

    private func feature(_ id: String, _ domain: String) -> InsightInputPacket.FeatureItem {
        InsightInputPacket.FeatureItem(id: id, domain: domain, description: "d", direction: "up", slots: [])
    }

    private func teaserPacket(_ features: [InsightInputPacket.FeatureItem]) -> InsightInputPacket {
        InsightInputPacket(schemaVersion: 1, kind: "insightInput", requestId: "r", window: .init(days: 28),
                           portrait: [], features: features, userIntents: [], recentTopics: [], rejectedAngles: [])
    }

    func testTeaserPairsAcrossDomainsAndDropsSecondRecent() {
        let packet = teaserPacket([feature("a", "health"), feature("b", "habit")])
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: [
            "a": "最近你睡得越来越晚", "b": "「冥想」最近打卡比之前少了",
        ])
        XCTAssertEqual(clues.count, 1)
        XCTAssertEqual(clues[0].text, "最近你睡得越来越晚，同一段时间「冥想」打卡比之前少了。这两件事有关系吗？")
        XCTAssertEqual(clues[0].phrases, ["最近你睡得越来越晚", "「冥想」最近打卡比之前少了"])
    }

    func testTeaserSameDomainStaysSingleAndRespectsLimitAndExclusion() {
        let packet = teaserPacket([
            feature("a", "health"), feature("b", "health"), feature("c", "health"),
            feature("d", "health"), feature("e", "health"),
        ])
        let phrases = ["a": "最近你睡得比较少", "b": "最近你睡得越来越晚", "c": "最近你走路、运动少了",
                       "d": "最近你睡得比之前短了", "e": "最近你每天走的路比之前少了"]
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: phrases, excludingFeatureIds: ["a"])
        XCTAssertEqual(clues.count, 3)
        XCTAssertEqual(clues[0].text, "最近你睡得越来越晚，Holo 想帮你看看是为什么。")
    }

    func testTeaserSkipsFeaturesWithoutPhrase() {
        let packet = teaserPacket([feature("f_miner_0", "finance"), feature("a", "health")])
        let clues = DiscoveryTeaserBuilder.build(packet: packet, phrases: ["a": "最近你睡得比较少"])
        XCTAssertEqual(clues.map(\.text), ["最近你睡得比较少，Holo 想帮你看看是为什么。"])
    }

    func testTeaserFromRealBuilderOutput() throws {
        let output = try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(), featurePacket: makeFeaturePacket(),
            proposals: [], recentTopics: [], rejectedAngles: []
        ))
        let clues = DiscoveryTeaserBuilder.build(packet: output.packet, phrases: output.teaserPhrases)
        XCTAssertFalse(clues.isEmpty)
        XCTAssertLessThanOrEqual(clues.count, 3)
        XCTAssertTrue(clues.allSatisfy { !InsightNumberDiscipline.containsNumerals(in: $0.text) })
    }
```

### 验收 / 提交

测试全绿。`feat(iOS): 一个发现预告问题拼装器`

---

## I4a · 本机存储：撞墙截止时刻 / 额度快照 / 预告 / 点名次数 / 点名卡

**文件**：`APP/Services/AI/Discovery/DiscoveryTopicStore.swift`、`APP/Views/Chat/DiscoveryReviewSheet.swift`（只改一行调用）、`TESTS/Services/AI/Discovery/DiscoveryInsightBuilderTests.swift`

### 步骤

1. **删除**按日撞墙：`insightQuotaWallDayKey` 常量、`isInsightQuotaWalledToday(now:calendar:)`、`markInsightQuotaWalled(now:calendar:)`。

2. **新增** MARK 段（放在「v4 洞察线」MARK 之后）：

```swift
    // MARK: - Plus 分层（2026-11-21 I4a）：撞墙截止时刻 / 额度快照 / 预告 / 点名

    private let insightQuotaWallUntilKey = "holo.discovery.insight.quotaWallUntil.v1"
    private let insightQuotaSnapshotKey = "holo.discovery.insight.quotaSnapshot.v1"
    private let insightTeasersKey = "holo.discovery.insight.teasers.v1"
    private let insightFocusPicksKey = "holo.discovery.insight.focusPicks.v1"
    /// Plus 每天最多点名次数（自动 1 + 点名 2 = 后端 perDay 3）
    static let focusPicksPerDay = 2
    /// 预告有效天数
    static let teaserValidDays = 3

    /// 撞墙截止时刻：后端 7 天滚动窗口释放名额的时刻；按日标记会导致恢复日当天被锁死（02 审查 E1）。
    var quotaWallUntil: Date? {
        let value = defaults.double(forKey: insightQuotaWallUntilKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    func isInsightQuotaWalled(now: Date = Date()) -> Bool {
        guard let until = quotaWallUntil else { return false }
        return until > now
    }

    /// until 为 nil（后端没给恢复时刻）时墙到今天结束。
    func markInsightQuotaWalled(until: Date?, now: Date = Date(), calendar: Calendar = .current) {
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(86_400)
        defaults.set((until ?? endOfToday).timeIntervalSince1970, forKey: insightQuotaWallUntilKey)
    }

    /// 开通 Plus 后调用：清撞墙标记与当日尝试标记，让评审页立刻重新请求（02 审查 E2）。
    func clearInsightQuotaWall() {
        defaults.removeObject(forKey: insightQuotaWallUntilKey)
        defaults.removeObject(forKey: insightAttemptDayKey)
    }

    // 额度快照

    struct QuotaSnapshot: Codable, Equatable, Sendable {
        var used: Int
        var limit: Int
        var tier: String
        var resetAt: Date?
        var savedAt: Date

        /// limit 为 0（不限）时返回 nil
        var remaining: Int? { limit > 0 ? max(limit - used, 0) : nil }
        var isPlus: Bool { tier == "plus" }
    }

    func saveQuotaSnapshot(_ info: InsightDraft.QuotaInfo, now: Date = Date()) {
        let snapshot = QuotaSnapshot(used: info.used, limit: info.limit, tier: info.tier,
                                     resetAt: info.resetDate, savedAt: now)
        defaults.set((try? JSONEncoder().encode(snapshot)) ?? Data(), forKey: insightQuotaSnapshotKey)
    }

    /// 7 天内的快照才有效。
    func quotaSnapshot(now: Date = Date()) -> QuotaSnapshot? {
        guard let data = defaults.data(forKey: insightQuotaSnapshotKey),
              let snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data),
              now.timeIntervalSince(snapshot.savedAt) < 7 * 86_400 else { return nil }
        return snapshot
    }

    // 预告

    private struct TeaserBox: Codable {
        var savedAt: Date
        var clues: [DiscoveryTeaserClue]
    }

    func saveTeasers(_ clues: [DiscoveryTeaserClue], now: Date = Date()) {
        let box = TeaserBox(savedAt: now, clues: clues)
        defaults.set((try? JSONEncoder().encode(box)) ?? Data(), forKey: insightTeasersKey)
    }

    func clearTeasers() {
        defaults.removeObject(forKey: insightTeasersKey)
    }

    func teasers(now: Date = Date()) -> [DiscoveryTeaserClue] {
        guard let data = defaults.data(forKey: insightTeasersKey),
              let box = try? JSONDecoder().decode(TeaserBox.self, from: data),
              now.timeIntervalSince(box.savedAt) < TimeInterval(Self.teaserValidDays) * 86_400 else { return [] }
        return box.clues
    }

    func removeTeaser(id: String, now: Date = Date()) {
        guard let data = defaults.data(forKey: insightTeasersKey),
              var box = try? JSONDecoder().decode(TeaserBox.self, from: data) else { return }
        box.clues.removeAll { $0.id == id }
        defaults.set((try? JSONEncoder().encode(box)) ?? Data(), forKey: insightTeasersKey)
    }

    // 点名次数（"dayStamp|count"）

    func focusPicksToday(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let raw = defaults.string(forKey: insightFocusPicksKey),
              let bar = raw.firstIndex(of: "|"),
              let day = Double(raw[raw.startIndex..<bar]),
              let count = Int(raw[raw.index(after: bar)...]),
              day == dayStamp(now, calendar: calendar) else { return 0 }
        return count
    }

    func markFocusPick(now: Date = Date(), calendar: Calendar = .current) {
        let next = focusPicksToday(now: now, calendar: calendar) + 1
        defaults.set("\(dayStamp(now, calendar: calendar))|\(next)", forKey: insightFocusPicksKey)
    }
```

3. `canRequestInsight` 里 `!isInsightQuotaWalledToday(now: now, calendar: calendar)` 改为 `!isInsightQuotaWalled(now: now)`。

4. `QueuedCard` 在 `sourceDomains` 之后加：

```swift
        /// Plus 点名看出来的卡（2026-11-21 I4a）：不受「今天已消费一张」限制（02 审查 E4）。
        var isFocusedPick: Bool?
```

5. `todayCard` 改为：

```swift
    func todayCard(now: Date = Date(), calendar: Calendar = .current) -> QueuedCard? {
        let consumed = consumedToday(now: now, calendar: calendar)
        let rejected = rejectedTopics
        return readQueue().first { card in
            card.isV4 && !rejected.contains(card.topicKey) && card.windowEnd >= now
                && (!consumed || card.isFocusedPick == true)
        }
    }
```

   注释同步改为「今天最多自动消费一张；Plus 点名卡不受此限」。

6. `DiscoveryReviewSheet.swift` 第 167 行附近：`DiscoveryTopicStore.shared.isInsightQuotaWalledToday()` 改为 `DiscoveryTopicStore.shared.isInsightQuotaWalled()`（本任务只改这一处，其余 UI 在 I8 做）。

7. `DiscoveryInsightService.swift` 第 117 行附近 `store.markInsightQuotaWalled(now: now)` 临时改为 `store.markInsightQuotaWalled(until: nil, now: now)` 保证编译（I5 会改成正式逻辑）。这一步会让本任务动到 4 个文件，属于编译所需的最小改动，允许。

### 测试

1. 既有测试里用到 `isInsightQuotaWalledToday` / `markInsightQuotaWalled(now:)` 的那个用例（约第 330 行，「墙标记当日有效、次日重探」）：改写为新语义，测试名改为 `testQuotaWallLastsUntilResetAt`：

```swift
    func testQuotaWallLastsUntilResetAt() {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 1_764_000_000)
        XCTAssertFalse(store.isInsightQuotaWalled(now: now))
        let reset = now.addingTimeInterval(3 * 3600)
        store.markInsightQuotaWalled(until: reset, now: now)
        XCTAssertTrue(store.isInsightQuotaWalled(now: now.addingTimeInterval(3600)))
        XCTAssertFalse(store.isInsightQuotaWalled(now: reset.addingTimeInterval(1)))
        XCTAssertTrue(store.canRequestInsight(now: reset.addingTimeInterval(1)))
    }
```

   注意：`canRequestInsight` 还看当日尝试标记等，这个新 store 是干净的，所以墙过期后应为 true。

2. 新增：

```swift
    func testClearQuotaWallAlsoClearsAttemptMark() {
        let store = makeStore()
        let now = Date()
        store.markInsightV2Attempted(now: now)
        store.markInsightQuotaWalled(until: now.addingTimeInterval(86_400), now: now)
        XCTAssertFalse(store.canRequestInsight(now: now))
        store.clearInsightQuotaWall()
        XCTAssertTrue(store.canRequestInsight(now: now))
    }

    func testQuotaSnapshotRoundTripAndExpiry() {
        let store = makeStore()
        let now = Date()
        store.saveQuotaSnapshot(.init(used: 2, limit: 5, tier: "plus", resetAt: nil), now: now)
        XCTAssertEqual(store.quotaSnapshot(now: now)?.remaining, 3)
        XCTAssertNil(store.quotaSnapshot(now: now.addingTimeInterval(8 * 86_400)))
    }

    func testTeasersSaveRemoveAndExpire() {
        let store = makeStore()
        let now = Date()
        let clue = DiscoveryTeaserClue(id: "x", phrases: ["x"], domains: ["health"], text: "x，Holo 想帮你看看是为什么。")
        store.saveTeasers([clue], now: now)
        XCTAssertEqual(store.teasers(now: now).count, 1)
        XCTAssertTrue(store.teasers(now: now.addingTimeInterval(4 * 86_400)).isEmpty)
        store.removeTeaser(id: "x", now: now)
        XCTAssertTrue(store.teasers(now: now).isEmpty)
    }

    func testFocusPicksCountPerDay() {
        let store = makeStore()
        let now = Date()
        XCTAssertEqual(store.focusPicksToday(now: now), 0)
        store.markFocusPick(now: now)
        store.markFocusPick(now: now)
        XCTAssertEqual(store.focusPicksToday(now: now), 2)
        XCTAssertEqual(store.focusPicksToday(now: now.addingTimeInterval(2 * 86_400)), 0)
    }

    func testFocusedPickCardShowsEvenAfterTodayConsumed() throws {
        let store = makeStore()
        let now = Date()
        var first = try DiscoveryInsightCardBuilder.build(selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now)
        first.topicKey = "auto"
        store.enqueue(first)
        XCTAssertTrue(store.consumeToday(first, now: now))
        var picked = first
        picked.topicKey = "picked"
        picked.isFocusedPick = true
        store.enqueue(picked)
        XCTAssertEqual(store.todayCard(now: now)?.topicKey, "picked")
    }
```

   `InsightDraft.QuotaInfo` 的合成成员初始化器需要 `resetAt:` 参数，类型是 `Int64?`，传 `nil` 即可。

### 验收 / 提交

`./holo_build.py build` + `./holo_build.py test --only HoloTests/DiscoveryInsightBuilderTests` 全绿。
`feat(iOS): 一个发现本机存储——撞墙截止时刻、额度快照、预告与点名`

---

## I4b · 往期发现存档 + 文案工具

**文件**：新建 `APP/Services/AI/Discovery/V4/DiscoveryInsightArchive.swift`、新建 `APP/Services/AI/Discovery/V4/DiscoveryPlusCopy.swift`、`TESTS/Services/AI/Discovery/DiscoveryInsightBuilderTests.swift`

### `DiscoveryInsightArchive.swift`

```swift
import Foundation

// 往期发现存档（2026-11-21 Plus 分层 I4b）：用户点过「对，记住」或「先放一放」的 v4 卡留在这里；
// 「不太准确」的不进存档。免费与 Plus 一样可看（01 D5）。
// 存储与 DiscoveryTopicStore 同口径：UserDefaults、单设备、不上 CloudKit。
nonisolated final class DiscoveryInsightArchive {
    static let shared = DiscoveryInsightArchive()
    static let limit = 100

    enum Outcome: String, Codable, Sendable {
        case confirmed
        case deferred
    }

    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var body: String
        var sourceDomains: [String]
        var evidenceLines: [String]
        var consumedAt: Date
        var outcome: Outcome
    }

    private let defaults: UserDefaults
    private let key = "holo.discovery.insight.archive.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 新的在前。
    var entries: [Entry] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list.sorted { $0.consumedAt > $1.consumedAt }
    }

    var latest: Entry? { entries.first }

    func append(card: DiscoveryTopicStore.QueuedCard, outcome: Outcome, now: Date = Date()) {
        guard card.isV4 else { return }
        var list = entries.filter { $0.id != card.topicKey }
        list.insert(Entry(
            id: card.topicKey,
            title: card.title,
            body: card.insight ?? card.body,
            sourceDomains: card.sourceDomains ?? [],
            evidenceLines: card.evidenceLines ?? [],
            consumedAt: now,
            outcome: outcome
        ), at: 0)
        if list.count > Self.limit { list = Array(list.prefix(Self.limit)) }
        defaults.set((try? JSONEncoder().encode(list)) ?? Data(), forKey: key)
    }
}
```

**写之前核对**：`QueuedCard` 里 v4 卡的正文到底存在 `body` 还是 `insight`——读 `DiscoveryInsightCardBuilder.build` 看它怎么赋值，`body:` 那一行按实际改（`DiscoveryInsightCardView` 显示的是 `card.title` + `card.body`，存档应与卡片显示一致，**优先用 `card.body`**；如果 `body` 就是 insight 正文，直接写 `body: card.body`）。

### `DiscoveryPlusCopy.swift`

```swift
import Foundation

// 「一个发现」Plus 分层文案工具（2026-11-21 I4b）。文案真源：01-产品方案与文案真源.md。
enum DiscoveryPlusCopy {
    /// 与后端 HOLO_DISCOVERY_INSIGHT_PLUS_WEEKLY 默认值同步；免费用户拿不到 Plus 上限时用于文案。
    static let plusWeeklyLimit = 5
    /// 与后端 HOLO_DISCOVERY_INSIGHT_FREE_WEEKLY 默认值同步。
    static let freeWeeklyLimit = 1

    /// {resetText}：今天 HH:mm 之后 / 明天 / M 月 d 日（EEE） / 下周。
    static func resetText(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "下周" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: date)) 之后"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天"
        }
        formatter.dateFormat = "M 月 d 日（EEE）"
        return formatter.string(from: date)
    }

    /// 往期发现分组标题：本周 →「这周」，其余「M 月 d 日 – M 月 d 日」（周一为一周开始）。
    static func weekTitle(for date: Date, now: Date = Date(), calendar baseCalendar: Calendar = .current) -> String {
        var calendar = baseCalendar
        calendar.firstWeekday = 2
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return "" }
        if calendar.isDate(now, equalTo: date, toGranularity: .weekOfYear) { return "这周" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M 月 d 日"
        let end = week.end.addingTimeInterval(-1)
        return "\(formatter.string(from: week.start)) – \(formatter.string(from: end))"
    }
}
```

### 测试（追加到 `DiscoveryInsightBuilderTests`）

```swift
    // MARK: - 2026-11-21 Plus 分层 I4b

    private var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        shanghai.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date()
    }

    func testResetTextVariants() {
        let now = date(2026, 11, 21, 9)
        XCTAssertEqual(DiscoveryPlusCopy.resetText(nil, now: now, calendar: shanghai), "下周")
        XCTAssertEqual(DiscoveryPlusCopy.resetText(date(2026, 11, 21, 14, 30), now: now, calendar: shanghai), "今天 14:30 之后")
        XCTAssertEqual(DiscoveryPlusCopy.resetText(date(2026, 11, 22, 8), now: now, calendar: shanghai), "明天")
        XCTAssertEqual(DiscoveryPlusCopy.resetText(date(2026, 11, 27, 8), now: now, calendar: shanghai), "11 月 27 日（周五）")
    }

    func testWeekTitle() {
        let now = date(2026, 11, 21)
        XCTAssertEqual(DiscoveryPlusCopy.weekTitle(for: date(2026, 11, 19), now: now, calendar: shanghai), "这周")
        XCTAssertEqual(DiscoveryPlusCopy.weekTitle(for: date(2026, 11, 12), now: now, calendar: shanghai), "11 月 9 日 – 11 月 15 日")
    }

    func testArchiveAppendDedupAndSkipsNonV4() throws {
        let suite = "archive-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let archive = DiscoveryInsightArchive(defaults: defaults)
        let now = Date()
        let card = try DiscoveryInsightCardBuilder.build(selected: makeDraftSelected(), slots: makeSlots(), portraitIds: [], now: now)
        archive.append(card: card, outcome: .confirmed, now: now)
        archive.append(card: card, outcome: .deferred, now: now.addingTimeInterval(10))
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.latest?.outcome, .deferred)
        let v3 = DiscoveryTopicStore.QueuedCard(observationId: "o", topicKey: "k3", title: "t", body: "b",
                                                isModelCopy: false, selectedAt: now, windowEnd: now)
        archive.append(card: v3, outcome: .confirmed, now: now)
        XCTAssertEqual(archive.entries.count, 1)
    }
```

**核对星期**：2026-11-27 是星期几要以代码实际输出为准——先用 `swift -e 'import Foundation; var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Shanghai")!; let d=c.date(from:DateComponents(year:2026,month:11,day:27))!; let f=DateFormatter(); f.locale=Locale(identifier:"zh_CN"); f.dateFormat="EEE"; print(f.string(from:d))'` 在终端确认（这是终端命令，不是 App 代码，允许用 `!` 和 print），按输出改断言。2026-11-09~11-15 那周的周一也同样确认。

### 验收 / 提交

测试全绿。`feat(iOS): 一个发现往期存档与 Plus 文案工具`

---

## I5 · 服务层：撞墙/送达/无结论处理 + Plus 点名

**文件**：`APP/Services/AI/Discovery/V4/DiscoveryInsightService.swift`、`APP/Services/AI/Discovery/V4/DiscoveryInsightFeedbackBridge.swift`、`TESTS/Services/AI/Discovery/DiscoveryInsightBuilderTests.swift`

### 步骤

**1. 抽出材料组装**（`generate` 里重复用到）：

```swift
    /// 材料组装：画像仓 + 七域特征包 + 挖掘器提案 → 候选包（2026-11-21 I5 抽出，自动生成与点名共用）。
    private static func buildMaterials(
        proposals: [HoloKnowledgeRevision],
        store: DiscoveryTopicStore,
        now: Date
    ) async -> DiscoveryInsightCandidateBuilder.Output? {
        let portraitStore = HoloPortraitSynthesisRuntime.loadStore()
        guard let featurePacket = await HoloLifeFeatureDataSource.buildPacket(now: now) else { return nil }
        return DiscoveryInsightCandidateBuilder.build(
            portraitStore: portraitStore,
            featurePacket: featurePacket,
            proposals: proposals,
            recentTopics: store.recentAngleKeys(now: now),
            rejectedAngles: store.rejectedAngleKeys,
            now: now
        )
    }
```

   `generate` 改用它；原来「特征包为空」「数据不足」两个分支合并成一个 `return noCardToday(reason: "材料不足")`。

**2. 改 `applyDraft`**：

```swift
    static func applyDraft(
        _ draft: InsightDraft,
        built: DiscoveryInsightCandidateBuilder.Output,
        store: DiscoveryTopicStore,
        now: Date,
        isFocusedPick: Bool = false,
        isPlusLocally: Bool = HoloEntitlementState.shared.isPlusActive
    ) -> Bool {
        if let selected = draft.selected {
            // …原有终检、domainByRefId、CardBuilder 逻辑不变…
            // 在 `let card = try DiscoveryInsightCardBuilder.build(...)` 之后：
            //   var queued = card
            //   if isFocusedPick { queued.isFocusedPick = true }
            //   store.enqueue(queued)
            // 在 enqueue 之后、return true 之前加：
            //   store.saveTeasers(DiscoveryTeaserBuilder.build(
            //       packet: built.packet, phrases: built.teaserPhrases,
            //       excludingFeatureIds: Set(selected.evidence.map(\.refId))), now: now)
            //   if let quota = draft.quota { store.saveQuotaSnapshot(quota, now: now) }
            //   原来的 store.markInsightV2Attempted(now: now) 保留，但点名卡（isFocusedPick）不调用它
        }

        switch draft.noneReason {
        case "quota_exhausted":
            // 撞墙不写当日尝试标记（02 审查 E2）；墙截止到恢复时刻（E1）；会员同步延迟只墙 10 分钟（E6）。
            if let quota = draft.quota { store.saveQuotaSnapshot(quota, now: now) }
            store.saveTeasers(DiscoveryTeaserBuilder.build(packet: built.packet, phrases: built.teaserPhrases), now: now)
            let syncing = draft.quota?.tier == "free" && isPlusLocally
            store.markInsightQuotaWalled(until: syncing ? now.addingTimeInterval(600) : draft.quota?.resetDate, now: now)
            return noCardToday(reason: syncing ? "会员状态同步中" : "每周额度已用完")
        case "none_worthwhile", "insufficient_data":
            if !isFocusedPick {
                store.markInsightV2Attempted(now: now)
                store.markInsightV2NoneWorthwhile(now: now)
                // 模型看过、确实没话说：清空预告，不再写「还注意到几件事」（01 §5 第 6 条）
                store.clearTeasers()
            }
            return noCardToday(reason: draft.noneReason ?? "none_worthwhile")
        case "disabled":
            store.markInsightV2Attempted(now: now)
            DiscoveryFeatureFlags.markDisabledByServer()
            return noCardToday(reason: "后端开关关")
        default:
            if !isFocusedPick { store.markInsightV2Attempted(now: now) }
            return noCardToday(reason: "gate_rejected")
        }
    }
```

   注意：原代码在 switch 之前有一行无条件的 `store.markInsightV2Attempted(now: now)`，**删掉它**，改为上面各分支内调用。`selected` 分支原来的「终检失败 / 证据组装失败 → markInvalidInsightResponse」保持不变。

   `isPlusLocally` 默认参数引用 `HoloEntitlementState.shared`（`@MainActor`），`DiscoveryInsightService` 本身是 `@MainActor`，可以这样写；测试里显式传 `isPlusLocally:`。

**3. 新增 Plus 点名入口**：

```swift
    // MARK: - Plus 点名看（2026-11-21 I5）

    enum FocusOutcome: Equatable {
        case delivered
        case nothingWorthSaying
        case changed
        case limitReached
        case failed
    }

    private static var focusTask: Task<FocusOutcome, Never>?

    static func requestFocused(
        clue: DiscoveryTeaserClue,
        proposals: [HoloKnowledgeRevision],
        now: Date = Date()
    ) async -> FocusOutcome {
        if let focusTask { return await focusTask.value }
        let task = Task { await performFocused(clue: clue, proposals: proposals, store: .shared, client: RealInsightClient(), now: now) }
        focusTask = task
        defer { focusTask = nil }
        return await task.value
    }

    static func performFocused(
        clue: DiscoveryTeaserClue,
        proposals: [HoloKnowledgeRevision],
        store: DiscoveryTopicStore,
        client: InsightClient,
        now: Date
    ) async -> FocusOutcome {
        guard HoloAIDataProcessingConsent.shared.isGranted else { return .failed }
        guard !store.isInsightQuotaWalled(now: now),
              store.focusPicksToday(now: now) < DiscoveryTopicStore.focusPicksPerDay else { return .limitReached }
        guard var built = await buildMaterials(proposals: proposals, store: store, now: now) else { return .changed }
        // 特征 id 按下标生成，重新组包后可能变化：用短句反查当前 id（02 审查 E5）。
        let ids = clue.phrases.compactMap { phrase in
            built.teaserPhrases.first(where: { $0.value == phrase })?.key
        }
        guard !ids.isEmpty, ids.count == clue.phrases.count else {
            store.removeTeaser(id: clue.id, now: now)
            return .changed
        }
        built.packet.focusFeatureIds = ids
        store.markFocusPick(now: now)
        do {
            let draft = try await requestInsight(packet: built.packet, client: client)
            let delivered = applyDraft(draft, built: built, store: store, now: now, isFocusedPick: true)
            store.removeTeaser(id: clue.id, now: now)
            if delivered { return .delivered }
            return draft.noneReason == "quota_exhausted" ? .limitReached : .nothingWorthSaying
        } catch APIError.rateLimited(_) {
            return .limitReached
        } catch {
            logger.error("点名看失败: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }
```

   - 本工程默认 MainActor 隔离（所以纯逻辑类型都写了 `nonisolated`），测试类默认也在 MainActor 上，测试方法上的 `@MainActor` 可留可删。
   - `requestInsight(packet:client:)` 原来是 `private`，签名已有 `client` 参数，保持 private 即可（同一类型内可调）。
   - `InsightClient` 协议原来是嵌套在 enum 里的 internal 协议，测试可以实现它。
   - `applyDraft` 送达时会把 `removeTeaser` 之前保存的新预告覆盖掉，这是预期行为（新预告已排除本次引用的特征）。

**4. 往期存档挂钩**（`DiscoveryInsightFeedbackBridge.swift`）：
   - `confirm(...)` 里，在 `topicStore.consumeToday(card, now: now)` 之后加 `DiscoveryInsightArchive.shared.append(card: card, outcome: .confirmed, now: now)`。
   - `deferCard(...)` 里，在 `guard topicStore.consumeToday(card, now: now) else { return .unavailable }` 之后加 `DiscoveryInsightArchive.shared.append(card: card, outcome: .deferred, now: now)`。
   - `reject(...)` 不加。

### 测试（追加到 `DiscoveryInsightBuilderTests`；这些用到 `@MainActor` 的服务，测试方法标 `@MainActor`）

```swift
    // MARK: - 2026-11-21 Plus 分层 I5

    private func makeBuilt() throws -> DiscoveryInsightCandidateBuilder.Output {
        try XCTUnwrap(DiscoveryInsightCandidateBuilder.build(
            portraitStore: makePortraitStore(), featurePacket: makeFeaturePacket(),
            proposals: [], recentTopics: [], rejectedAngles: []
        ))
    }

    @MainActor
    func testQuotaExhaustedWallsUntilResetAndSavesTeasersWithoutAttemptMark() throws {
        let store = makeStore()
        let now = Date()
        let resetMs = Int64((now.timeIntervalSince1970 + 3 * 86_400) * 1000)
        let draft = InsightDraft(selected: nil, noneReason: "quota_exhausted",
                                 quota: .init(used: 1, limit: 1, tier: "free", resetAt: resetMs))
        XCTAssertFalse(DiscoveryInsightService.applyDraft(draft, built: try makeBuilt(), store: store, now: now, isPlusLocally: false))
        XCTAssertTrue(store.isInsightQuotaWalled(now: now.addingTimeInterval(2 * 86_400)))
        XCTAssertFalse(store.isInsightQuotaWalled(now: now.addingTimeInterval(3 * 86_400 + 5)))
        XCTAssertFalse(store.insightV2AttemptedToday(now: now))
        XCTAssertFalse(store.teasers(now: now).isEmpty)
        XCTAssertEqual(store.quotaSnapshot(now: now)?.used, 1)
    }

    @MainActor
    func testQuotaExhaustedWhilePlusLocallyOnlyWallsTenMinutes() throws {
        let store = makeStore()
        let now = Date()
        let draft = InsightDraft(selected: nil, noneReason: "quota_exhausted",
                                 quota: .init(used: 1, limit: 1, tier: "free", resetAt: nil))
        _ = DiscoveryInsightService.applyDraft(draft, built: try makeBuilt(), store: store, now: now, isPlusLocally: true)
        XCTAssertTrue(store.isInsightQuotaWalled(now: now.addingTimeInterval(300)))
        XCTAssertFalse(store.isInsightQuotaWalled(now: now.addingTimeInterval(700)))
    }

    @MainActor
    func testNoneWorthwhileClearsTeasers() throws {
        let store = makeStore()
        let now = Date()
        store.saveTeasers([DiscoveryTeaserClue(id: "x", phrases: ["x"], domains: ["health"], text: "x")], now: now)
        _ = DiscoveryInsightService.applyDraft(InsightDraft(selected: nil, noneReason: "none_worthwhile"),
                                               built: try makeBuilt(), store: store, now: now, isPlusLocally: false)
        XCTAssertTrue(store.teasers(now: now).isEmpty)
        XCTAssertTrue(store.insightV2NoneWorthwhileToday(now: now))
    }
```

   点名流程 `performFocused` 依赖 `HoloLifeFeatureDataSource` 读真实数据，**不写单测**，在 05 的模拟器走查里验证。

### 验收 / 提交

build + `DiscoveryInsightBuilderTests` 全绿。
`feat(iOS): 一个发现服务层接入额度、预告与 Plus 点名`

---

## I6 · 发现卡文案 + 撞墙卡重写

**文件**：`APP/Views/Chat/DiscoveryInsightCardView.swift`（只改这一个文件）

### 步骤

1. `DiscoveryInsightCardView`：
   - `CardBadge(text: "AI 洞察", ...)` → `CardBadge(text: "Holo 看出来的一件事", ...)` // C04
   - `"查看依据"` → `"Holo 是怎么看出来的"`（C05a），`"收起依据"` → `"收起"`（C05b）
   - `private static let domainSymbols` 和 `domainTitles` 去掉 `private`（撞墙卡要复用）。

2. 用下面的结构**整体替换** `DiscoveryQuotaWallCard`：

```swift
// MARK: - 撞墙卡 / Holo 还注意到的事（2026-11-21 Plus 分层 I6，文案 C20~C50）

enum DiscoveryWallState: Equatable {
    /// A / A0：免费撞墙（clues 为空即 A0）
    case freeWalled(clues: [DiscoveryTeaserClue], resetText: String)
    /// B：Plus 本周用完
    case plusExhausted(limit: Int, resetText: String)
    /// C：Plus 可点名
    case plusPickable(clues: [DiscoveryTeaserClue], remaining: Int, pickingId: String?)
    /// D：本机 Plus、后端仍按免费判
    case syncing
}

struct DiscoveryQuotaWallCard: View {
    let state: DiscoveryWallState
    let onLearnPlus: () -> Void
    let onPick: (DiscoveryTeaserClue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            content
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.insight.quotaWall")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .freeWalled(let clues, let resetText):
            freeWalled(clues: clues, resetText: resetText)
        case .plusExhausted(let limit, let resetText):
            titleText("这周的 \(limit) 件都看完了")                       // C30
            bodyText("\(resetText)之后，Holo 会接着帮你看。")               // C31
        case .plusPickable(let clues, let remaining, let pickingId):
            titleText("Holo 还注意到的事")                                 // C40
            bodyText("这周还能看 \(remaining) 件，点一件让 Holo 先帮你看")     // C41
            ForEach(clues) { clue in
                clueRow(clue, trailing: pickButton(clue, pickingId: pickingId))
            }
        case .syncing:
            bodyText("会员状态还在同步，过几分钟再打开看看。")                 // C50
        }
    }
}
```

   然后在 `extension DiscoveryQuotaWallCard` 里实现这些私有子件（每个都是小函数，不要内联成巨型 body）：

   - `freeWalled(clues:resetText:)`：
     - 顶部 `HStack`：`Text("这周的发现你已经看过了")`（C20，`.holoText(.metadata)` + `.fontWeight(.semibold)` + `holoToolTextSecondary`）+ `Spacer()` + `HoloPlusEmblem(size: 24)`
     - clues 非空：`titleText("Holo 还注意到 \(clues.count) 件事，还没来得及细看")`（C21）→ `ForEach(clues) { clueRow($0, trailing: EmptyView()) }`（C22）→ `bodyText("开通 Plus，Holo 会把这些事一件件帮你看明白。")`（C23）
     - clues 为空：`titleText("这周的发现你已经看过了")` → `bodyText("开通 Plus，Holo 每周最多会告诉你 \(DiscoveryPlusCopy.plusWeeklyLimit) 件它看出来的事。")`
     - 主按钮：`Button(action: onLearnPlus) { Text("让 Holo 帮我看看").frame(maxWidth: .infinity, minHeight: 44) }`（C24），`.buttonStyle(HoloActionStyle(role: .primary))`，`.accessibilityIdentifier("chat.discovery.insight.quotaWall.plus")`。**颜色**：项目若已有金色 Plus 按钮样式（搜 `HoloPlusTheme` 里的 button/gradient），就用它；没有就用 `.primary`，不要自己造新颜色。
     - 底部：`Text("不开通也没关系，\(resetText)会有下一件")`（C25），`.holoText(.metadata)`，居中。
   - `clueRow(_:trailing:)`：`HStack(alignment: .top)`：领域图标 `Image(systemName: DiscoveryInsightCardView.domainSymbols[clue.domains.first ?? ""] ?? "lightbulb")` + `Text(clue.text)`（`.holoText(.supporting)`、`fixedSize(horizontal: false, vertical: true)`）+ `Spacer(minLength: 0)` + trailing；行与行之间用 `CardDivider()` 或 `.padding(.vertical, HoloSpacing.xs)`，二选一，跟同文件风格一致。
   - `pickButton(_:pickingId:)`：`pickingId == clue.id` 时显示 `Text("正在看…")`（C43），否则 `Button("帮我看") { onPick(clue) }`（C42），`.buttonStyle(HoloActionStyle(role: .secondary))`，`.disabled(pickingId != nil)`，`.accessibilityIdentifier("chat.discovery.insight.pick")`。
   - `titleText(_:)`：`.holoText(.body)` + `.fontWeight(.semibold)` + `holoToolText`；`bodyText(_:)`：`.holoText(.supporting)` + `holoToolTextSecondary`；都加 `.fixedSize(horizontal: false, vertical: true)`。

3. 原来的 `openPlus()` 删除（埋点挪到 I8 宿主里）。

4. 这个文件改完后，`DiscoveryReviewSheet` 里 `DiscoveryQuotaWallCard()` 的调用会编译失败——**本任务在 ReviewSheet 里临时改成**：

```swift
DiscoveryQuotaWallCard(
    state: .freeWalled(clues: [], resetText: DiscoveryPlusCopy.resetText(DiscoveryTopicStore.shared.quotaWallUntil)),
    onLearnPlus: { HoloPlusActionCoordinator.shared.requirePlus(context: .discoveryInsightWeekly) },
    onPick: { _ in }
)
```

   保证编译，I8 再接正式逻辑。

5. `ForEach(clues)` 要求 `DiscoveryTeaserClue: Identifiable`（I3 已声明）。这里渲染的是值类型，不是托管对象，ForEach Guard 不会拦。

### 验收

- `./holo_build.py build` 绿（View Weight Guard 也在构建里）。
- 新 SF Symbol：本任务没有新增符号（`lightbulb` 等是既有的），无需验证。

### 提交

`feat(iOS): 一个发现撞墙卡重写为预告问题与 Plus 点名列表`

---

## I7 · Plus 说明页 + 往期发现页（两个新视图）

**文件**：新建 `APP/Views/Chat/DiscoveryPlusExplainerSheet.swift`、新建 `APP/Views/Chat/DiscoveryInsightArchiveView.swift`

### `DiscoveryPlusExplainerSheet`

```swift
import SwiftUI

// 「一个发现」Plus 说明页（2026-11-21 Plus 分层 I7，文案 C60~C72）。
// 只负责讲清楚，不直接购买：点开通 → onUpgrade（宿主先关本页，在 onDismiss 里再弹系统付费墙，02 审查 E7）。
struct DiscoveryPlusExplainerSheet: View {
    let latestTitle: String?
    let monthlyPrice: String?
    let onUpgrade: () -> Void
    let onClose: () -> Void

    var body: some View {
        HoloSheetScaffold(title: "Holo Plus", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    header
                    if let latestTitle { recapBlock(latestTitle) }
                    comparison
                    clarifications
                    actions
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.lg)
            }
        }
        .presentationDetents([.large])
    }
}
```

在 `private extension DiscoveryPlusExplainerSheet` 里实现：

- `header`：`VStack(alignment: .center)`，`HoloPlusEmblem(size: 56)`（C60）+ `Text("每周 1 件不够看？\n让 Holo 多帮你看看")`（C61，`.font(.holoTitle2)`，`.multilineTextAlignment(.center)`），整体 `frame(maxWidth: .infinity)`。
- `recapBlock(_:)`：小字「这周 Holo 告诉过你」（C62）+ `Text("「\(title)」")`（C63），`.holoSurface()` 或 `Color.holoToolInset` 底，跟项目里既有提示块风格一致。
- `comparison`：`HStack(alignment: .top, spacing: HoloSpacing.sm)` 两个等宽栏（各 `frame(maxWidth: .infinity, alignment: .leading)`）：
  - 左栏 C64：「免费版」/「每周 1 件」/「Holo 每周挑一件最值得说的事告诉你」
  - 右栏 C65：「Plus」/「每周最多 \(DiscoveryPlusCopy.plusWeeklyLimit) 件」/「Holo 几乎每天都帮你看，有值得说的就告诉你」/「注意到的事可以点一下，让 Holo 先帮你看」；描边用 `HoloPlusTheme.strokeColor`（若名字不同，搜 `HoloPlusTheme` 找描边色）。
  - 大字用 `.holoText(.body).fontWeight(.bold)`；正文 `.holoText(.supporting)`。
  - 抽成一个 `planColumn(title:headline:lines:highlighted:)` 小函数复用。
- `clarifications`：标题「说清楚两件事」（C66）+ 两条（C67、C68，C67 里的数字用 `DiscoveryPlusCopy.plusWeeklyLimit`），每条前面一个「·」。
- `actions`：
  - 主按钮：`monthlyPrice.map { "开通 Plus · \($0) / 月" } ?? "开通 Holo Plus"`（C69/C70），`HoloActionStyle(role: .primary)`，`minHeight: 44`，`accessibilityIdentifier("chat.discovery.plusExplainer.upgrade")`
  - 小字「随时可以在系统设置里取消」（C71），居中
  - 次按钮「先不用，等下周的」（C72）→ `onClose`，`HoloActionStyle(role: .secondary)`，`accessibilityIdentifier("chat.discovery.plusExplainer.later")`

### `DiscoveryInsightArchiveView`

```swift
import SwiftUI

// 往期发现（2026-11-21 Plus 分层 I7，文案 C80~C84）。免费可看。
struct DiscoveryInsightArchiveView: View {
    let entries: [DiscoveryInsightArchive.Entry]
    let onClose: () -> Void

    var body: some View {
        HoloSheetScaffold(title: "往期发现", onClose: onClose) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("你看过的发现都会留在这里")                                   // C81
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    if entries.isEmpty {
                        Text("还没有看过的发现")                                       // C84
                            .holoText(.supporting)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.top, HoloSpacing.lg)
                    } else {
                        ForEach(groups, id: \.title) { group in
                            DiscoveryArchiveGroup(title: group.title, entries: group.entries)
                        }
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.vertical, HoloSpacing.md)
            }
        }
        .presentationDetents([.large])
    }

    private var groups: [(title: String, entries: [DiscoveryInsightArchive.Entry])] {
        var result: [(title: String, entries: [DiscoveryInsightArchive.Entry])] = []
        for entry in entries {
            let title = DiscoveryPlusCopy.weekTitle(for: entry.consumedAt)
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].entries.append(entry)
            } else {
                result.append((title, [entry]))
            }
        }
        return result
    }
}
```

`DiscoveryArchiveGroup`（同文件 `private struct`）：分组标题（C82，`.holoText(.metadata)`）+ 每条一个卡片：`CardBadge(text: "Holo 看出来的一件事", color: .holoToolTextSecondary)` + `Text(entry.title).font(.holoTitle3 或项目里次一级的标题字号)` + `Text(entry.body)` + 领域 chip（用 `DiscoveryInsightCardView.domainTitles`）+ 右下角日期（`DateFormatter` zh_CN，`"M 月 d 日"`），`.holoSurface()`。字号常量以项目 `DesignSystem.swift` 里实际存在的为准，找不到 `.holoTitle3` 就用 `.holoText(.body).fontWeight(.semibold)`。

### 验收 / 提交

build 绿。`feat(iOS): 一个发现 Plus 说明页与往期发现页`

---

## I8 · 评审页接入（核心串联）

**文件**：`APP/Views/Chat/DiscoveryReviewSheet.swift`（只改这一个文件；它约 720 行，View Weight Guard 上限是单 View 1400 行，新增界面块已经在 I6/I7 拆成独立 struct，这里只加状态和调用）

### 步骤

1. **新状态**：

```swift
    @ObservedObject private var entitlement = HoloEntitlementState.shared
    @State private var showsPlusExplainer = false
    @State private var upgradeAfterExplainer = false
    @State private var showsArchive = false
    @State private var pickingClueId: String?
```

2. **C01**：顶部说明 `Text("Holo 每天从你的记录里挑一件反复出现的事来问你，你确认了才会记住。")` 替换为 C01 全文。

3. **C02/C03**：今日卡分组 `DiscoverySectionHeader(title: "今日一条", trailing: Date().formatted(...))` 改为 `DiscoverySectionHeader(title: "今天的发现", trailing: quotaTrailing)`（这也顺带去掉了违规的 `.formatted()`）。新增计算属性：

```swift
    /// C03a~d
    private var quotaTrailing: String? {
        let store = DiscoveryTopicStore.shared
        guard let snapshot = store.quotaSnapshot() else { return nil }
        if entitlement.isPlusActive || snapshot.isPlus {
            return "这周已看 \(snapshot.used) 件 · 最多 \(snapshot.limit) 件"
        }
        if snapshot.used >= snapshot.limit {
            return "下一件：\(DiscoveryPlusCopy.resetText(snapshot.resetAt))"
        }
        return "免费版每周 \(DiscoveryPlusCopy.freeWeeklyLimit) 件"
    }
```

   **先看 `DiscoverySectionHeader` 的 `trailing` 参数类型**：如果是非可选 `String`，就传 `quotaTrailing ?? ""`，并确认空串时不渲染多余空白（不行就给 header 加一个 `if !trailing.isEmpty`，这是同文件的私有 struct，可以改）。

4. **撞墙卡状态**：新增

```swift
    /// 撞墙卡 / 还注意到的事 应显示哪种状态；nil 表示不显示。
    private var wallState: DiscoveryWallState? {
        let store = DiscoveryTopicStore.shared
        let snapshot = store.quotaSnapshot()
        let resetText = DiscoveryPlusCopy.resetText(store.quotaWallUntil ?? snapshot?.resetAt)
        let clues = store.teasers()
        let isPlus = entitlement.isPlusActive
        if store.isInsightQuotaWalled() {
            if isPlus && snapshot?.isPlus != true { return .syncing }
            if isPlus { return .plusExhausted(limit: snapshot?.limit ?? DiscoveryPlusCopy.plusWeeklyLimit, resetText: resetText) }
            return .freeWalled(clues: clues, resetText: resetText)
        }
        guard isPlus, todayCard == nil, !clues.isEmpty,
              store.focusPicksToday() < DiscoveryTopicStore.focusPicksPerDay else { return nil }
        let remaining = snapshot?.remaining ?? DiscoveryPlusCopy.plusWeeklyLimit
        guard remaining > 0 else { return nil }
        return .plusPickable(clues: clues, remaining: remaining, pickingId: pickingClueId)
    }
```

5. **放置位置**（`loadedContent` 里）：
   - 原来 `else if todayCard == nil { if isInsightQuotaWalled ... DiscoveryQuotaWallCard ... else DiscoveryEmptyCard }` 这段**只在 listedItems 为空时**才出墙卡——改为：墙卡不再依赖「等你确认」是否为空。具体：在 `if let receipt { ... }` 之后、`if !listedItems.isEmpty` 之前插入

```swift
        if todayCard == nil, let wallState {
            DiscoveryQuotaWallCard(
                state: wallState,
                onLearnPlus: openPlusExplainer,
                onPick: pick
            )
            .padding(.top, HoloSpacing.xl)
            .onAppear {
                HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "quota_wall_shown", "state": wallStateLabel(wallState)])
            }
        }
```

   - 原来末尾的 `else if todayCard == nil { ... }` 分支里删掉墙卡那半，只保留空态，并且**有 wallState 时不出空态**：

```swift
        } else if todayCard == nil && wallState == nil {
            DiscoveryEmptyCard(
                style: emptyStyle,
                onOpenMemory: { DeepLinkState.shared.navigate(to: .memoryGallery(focusNewMemories: false)) }
            )
            .padding(.top, HoloSpacing.xl)
        }
```

     其中 `emptyStyle`：`receipt != nil ? .doneToday : (DiscoveryTopicStore.shared.insightV2NoneWorthwhileToday() ? .nothingWorthSaying : .noneToday)`。

   - 页面最底部（`loadedContent` 末尾）加往期入口 C06：

```swift
        let archiveCount = DiscoveryInsightArchive.shared.entries.count
        if archiveCount > 0 {
            Button { showsArchive = true } label: {
                HStack {
                    Text("往期发现").holoText(.body).foregroundStyle(Color.holoToolText)
                    Spacer()
                    Text("\(archiveCount) 件 ›").holoText(.supporting).foregroundStyle(Color.holoToolTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .padding(.top, HoloSpacing.xl)
            .accessibilityIdentifier("chat.discovery.archive.entry")
        }
```

     如果 `@ViewBuilder` 里 `let` 报错，把 `archiveCount` 改成计算属性。

6. **`DiscoveryEmptyCard` 新增 `.nothingWorthSaying`**（同文件 private struct）：`icon` 用 `"text.magnifyingglass"`，`title` C10 标题，`subtitle` C10 说明；`.noneToday` 的 subtitle 改为 C11。

7. **动作函数**：

```swift
    private func openPlusExplainer() {
        HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "quota_wall_plus_tap"])
        showsPlusExplainer = true
    }

    private func pick(_ clue: DiscoveryTeaserClue) {
        guard pickingClueId == nil, let proposals = result?.insightProposals else { return }
        pickingClueId = clue.id
        receipt = nil
        HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "focus_pick_tap"])
        Task {
            let outcome = await DiscoveryInsightService.requestFocused(clue: clue, proposals: proposals)
            pickingClueId = nil
            HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "focus_pick_result", "outcome": "\(outcome)"])
            switch outcome {
            case .delivered:
                todayCard = DiscoveryTopicStore.shared.todayCard()
            case .nothingWorthSaying:
                receipt = Receipt(kind: .success, text: "Holo 看了看，这件事暂时没什么值得说的。这次不算次数。")   // C44
            case .changed:
                receipt = Receipt(kind: .warning, text: "这件事的记录刚有变化，换一件试试。")                  // C45
            case .limitReached:
                receipt = Receipt(kind: .warning, text: "今天先看到这里，明天再帮你看。")                    // C46
            case .failed:
                receipt = Receipt(kind: .warning, text: "这次没看成，稍后再试一次。")                       // C47
            }
        }
    }

    private func wallStateLabel(_ state: DiscoveryWallState) -> String {
        switch state {
        case .freeWalled(let clues, _): return clues.isEmpty ? "free_empty" : "free_clues"
        case .plusExhausted: return "plus_exhausted"
        case .plusPickable: return "plus_pickable"
        case .syncing: return "syncing"
        }
    }
```

   `result?.insightProposals` 的确切名字以 `DiscoveryMemoryReviewService.Result` 为准（`reload` 里用的是 `value.insightProposals`）。

8. **弹层**（挂在 `body` 最外层，和现有 `.onReceive` 并列）：

```swift
        .sheet(isPresented: $showsPlusExplainer, onDismiss: presentPaywallIfRequested) {
            DiscoveryPlusExplainerSheet(
                latestTitle: DiscoveryInsightArchive.shared.latest?.title,
                monthlyPrice: HoloSubscriptionService.shared.products
                    .first(where: { $0.id == HoloSubscriptionProduct.plusMonthly.rawValue })?.displayPrice,
                onUpgrade: {
                    HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "plus_explainer_upgrade"])
                    upgradeAfterExplainer = true
                    showsPlusExplainer = false
                },
                onClose: { showsPlusExplainer = false }
            )
        }
        .sheet(isPresented: $showsArchive) {
            DiscoveryInsightArchiveView(entries: DiscoveryInsightArchive.shared.entries, onClose: { showsArchive = false })
        }
```

```swift
    /// 说明页完全关闭后再弹系统付费墙（弹层叠弹层不可靠，02 审查 E7）。
    private func presentPaywallIfRequested() {
        guard upgradeAfterExplainer else { return }
        upgradeAfterExplainer = false
        HoloPlusActionCoordinator.shared.requirePlus(context: .discoveryInsightWeekly, resume: {
            await MainActor.run {
                DiscoveryTopicStore.shared.clearInsightQuotaWall()
                NotificationCenter.default.post(name: .holoDiscoverySettingsDidChange, object: nil)
            }
        })
    }
```

   - `.holoDiscoverySettingsDidChange` 已被本页监听并 `requestRefresh(force: true)`，开通后会立刻重新生成一件。
   - 如果 `HoloSubscriptionProduct` 的 case 名或 `Product.id` 用法不同，以 `Services/Subscription/HoloSubscriptionProducts.swift` 实际定义为准。

9. 删除 I6 留下的临时 `DiscoveryQuotaWallCard(state: .freeWalled(clues: [], ...))` 调用。

### 验收

- build 绿。
- 按 05 的「模拟器走查 S1~S6」全部走一遍并截图（截图交给只读子代理判读，主会话不读图）。
- **必须实点**说明页「开通 Plus」→ 系统付费墙确实弹出（E7）。不弹 → 停下，记录现象交回东林，不要自行换呈现方式超过一次。

### 提交

`feat(iOS): 一个发现评审页接入预告墙、Plus 说明页、点名看与往期发现`

---

## I9 · 记忆中心文案 + 付费墙标题 + 权益表

**文件**：`APP/Views/MemoryCenter/HoloMemoryCenterView.swift`、`APP/Views/MemoryCenter/HoloPortraitInsightsSection.swift`、`APP/Services/Subscription/HoloPlusActionCoordinator.swift`、`APP/Views/Subscription/HoloPlusBenefitComparisonTable.swift`（都是文案级小改）

### 步骤

1. `HoloMemoryCenterView.swift`：
   - 第 175 行附近 `ScrollView(.vertical, showsIndicators: true)` 内的 `VStack` 第一个子元素（`if showSearch` 之前）插入 C100 横幅：

```swift
                // C100（2026-11-21 Plus 分层 I9）：记忆永远免费
                HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.xs) {
                    Image(systemName: "checkmark.seal")
                    Text("这里是 Holo 记住的所有关于你的事。随时可以看、可以改、可以删，永远免费。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolSuccess)
                .padding(HoloSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolSuccess.opacity(0.1)))
                .padding(.bottom, HoloSpacing.sm)
                .accessibilityIdentifier("memoryCenter.freeBanner")
```

     `HoloRadius.md` / `Color.holoToolSuccess` 若不存在，以 `DesignSystem.swift` 实际常量为准（搜 `holoToolSuccess`、`enum HoloRadius`）。
   - 同一个 `ScrollView` 的 `showsIndicators: true` 改为 `false`（编码约定要求）。
   - 第 399 行附近 `"眼下还没有确定下来的理解"` → C104。
2. `HoloPortraitInsightsSection.swift`：C101（第 182 行附近）、C102（第 159 行）、C103（第 156 行）逐字替换。
3. `HoloPlusActionCoordinator.swift`：`.discoveryInsightWeekly` 的 title 改为 C90。
4. `HoloPlusBenefitComparisonTable.swift`：在「记忆洞察刷新」那一行之前，照着相邻行的写法插入 C91（icon `"sparkle.magnifyingglass"`——这个名字已在 PromptManager 里使用过，仍需用 00-README 红线 5 的命令验证一次）。
5. 确认记忆中心没有 Plus 门槛：`grep -rn "requirePlus" "Holo/Holo APP/Holo/Holo/Views/MemoryCenter"` 必须无输出；有输出就停下报告东林（D1 要求永远免费）。

### 验收 / 提交

build 绿；打开「Holo 记住的你」截图确认横幅出现、无滚动条（子代理判读）。
`feat(iOS): 记忆中心标明永远免费，付费墙与权益表补一个发现`

---

## 收尾（全部任务完成后，由最后一个执行者做）

1. 更新根目录 `CHANGELOG.md`（追加，不要覆盖；pre-commit 会拦整文件覆盖）和 `TODO.md` 对应条目。
2. 在 `07-实施记录.md` 填写总结。
3. 不要 push，不要装真机，等东林验收。
