# Holo Agent 深度分析卡片化（阶段 1：卡片化 + 排版）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Agent 深度分析结果从「纯文本气泡」改造为「Chat 内卡片（四态）→ 点击进入结构化详情页」，并修复渲染层 title/body 同值浪费。

**Architecture:** 复用账单分析卡片的四态分发模式与详情页结构。新增 `AgentDeepAnalysisCard`（入口卡）+ `AgentDeepAnalysisDetailSheet`（详情页），底层复用 `ChatCardView` / `CardHeaderView` / `HoloAIHeroMetric` / `HoloAIFactItem` / `MarkdownAttributedStringRenderer`。Agent 结果结构化持久化到 `ChatMessage.agentResultJSON`（新增 Core Data 属性，轻量迁移），不再用 `\n` 拍扁成字符串。

**Tech Stack:** SwiftUI, Core Data（轻量迁移）, XCTest, XcodeBuildMCP（`build_run_sim` / `test_sim`）

**关联 spec:** `docs/superpowers/specs/2026-06-14-holo-agent-deep-analysis-redesign-design.md`

---

## File Structure

| 文件 | 动作 | 责任 |
|------|------|------|
| `Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift` | 改 | 修复 section.title/body 同值；section 加 `confidence` 字段（为阶段 2 铺路） |
| `Models/ChatMessage.xcdatamodeld`（ChatMessage entity） | 改 | 加 `agentResultJSON` 属性（String, optional），轻量迁移 |
| `Models/ChatMessage+CoreDataProperties.swift` | 改 | 加 `@NSManaged var agentResultJSON: String?` |
| `Models/ChatMessageViewData.swift` | 改 | 加 `agentResult: HoloRenderedAgentResult?` 字段 + 4 处 init 解码 + `decodeAgentResult` 静态方法 |
| `Data/Repositories/ChatMessageRepository.swift` | 改 | `finalizeMessage` 加 `agentResultJSON` 参数；3 处 fetch 字段列表加 `agentResultJSON`；`setAnalysisLoadingState` 不变 |
| `Views/Chat/ChatViewModel.swift:272-293` | 改 | Agent 路径不再拍扁成字符串，编码 `rendered` 存 `agentResultJSON` |
| `Views/Chat/Analysis/AgentDeepAnalysisCard.swift` | 新建 | 入口卡，四态（loading/loaded/unloaded/degrade），复用 ChatCardView 等 |
| `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift` | 新建 | 详情页：核心结论卡 + 事实段 + Markdown 分段 + 证据段 |
| `Views/Chat/MessageBubbleView.swift:105-119` | 改 | agent 消息走 `AgentDeepAnalysisCard`，不走文本气泡 |
| `Views/Chat/ChatView.swift` | 改 | 接 agent 详情 Sheet（照 analysisDetail 的 `.sheet(item:)` 模式） |

**测试文件：**
- `HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`（新建，TDD 核心）
- `HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`（新建，TDD 编解码 + 向后兼容）

---

## Task 1: 修复 HoloAgentResultRenderer 的 title/body 同值 + 暴露 confidence

**Files:**
- Modify: `Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift`
- Test: `HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift`：

```swift
import XCTest
@testable import Holo

final class HoloAgentResultRendererTests: XCTestCase {

    private func makeClaim(
        id: String = "c1",
        type: String = "observation",
        text: String = "本月支出偏高，主要集中在餐饮",
        confidence: Double = 0.82
    ) -> HoloAgentClaim {
        HoloAgentClaim(
            id: id,
            type: type,
            displayText: text,
            metricAssertions: [],
            evidenceIDs: [],
            prohibitedInferences: [],
            confidence: confidence
        )
    }

    func testRender_sectionTitleNotEqualToBody() throws {
        let claim = makeClaim(text: "本月支出偏高，主要集中在餐饮")
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [])

        XCTAssertEqual(result.sections.count, 1)
        let section = try XCTUnwrap(result.sections.first)
        XCTAssertNotEqual(section.title, section.body, "title 不应等于 body（修复同值浪费）")
        XCTAssertEqual(section.body, "本月支出偏高，主要集中在餐饮")
        XCTAssertFalse(section.title.isEmpty)
    }

    func testRender_sectionCarriesConfidence() throws {
        let claim = makeClaim(confidence: 0.82)
        let result = HoloAgentResultRenderer().render(claims: [claim], evidence: [])

        let section = try XCTUnwrap(result.sections.first)
        XCTAssertEqual(section.confidence, 0.82, accuracy: 0.001)
    }

    func testRender_multipleClaimsHaveDistinctTitles() {
        let claims = [
            makeClaim(id: "c1", text: "观察一的内容"),
            makeClaim(id: "c2", text: "观察二的内容"),
            makeClaim(id: "c3", text: "观察三的内容")
        ]
        let result = HoloAgentResultRenderer().render(claims: claims, evidence: [])

        let titles = result.sections.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "多条 claim 的 title 应互不相同")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

运行：`test_sim`（XcodeBuildMCP）过滤 `HoloTests/HoloAgentResultRendererTests`，或：
```
xcodebuild test -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HoloTests/HoloAgentResultRendererTests
```
预期：编译失败（`section.confidence` 不存在）或断言失败（title == body）。

- [ ] **Step 3: 实现 — 扩展渲染模型 + 修复 render()**

改 `HoloAgentResultRenderer.swift`：

```swift
struct HoloRenderedAgentSection: Codable, Equatable, Sendable {
    var title: String
    var body: String
    var confidence: Double?
}

struct HoloRenderedEvidenceReference: Codable, Equatable, Sendable {
    var id: String
    var summary: String
}

struct HoloRenderedAgentResult: Codable, Equatable, Sendable {
    var title: String
    var summary: String
    var sections: [HoloRenderedAgentSection]
    var evidenceReferences: [HoloRenderedEvidenceReference]
}

struct HoloAgentResultRenderer {

    func render(claims: [HoloAgentClaim], evidence: [HoloEvidenceRecord],
                title: String = "本期观察") -> HoloRenderedAgentResult {
        let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })

        // section.title 用「观察 N」作为 kicker，body 用 claim 正文，二者不再同值
        let sections = claims.enumerated().map { index, claim in
            HoloRenderedAgentSection(
                title: "观察 \(index + 1)",
                body: claim.displayText,
                confidence: claim.confidence
            )
        }

        var seen = Set<String>()
        var references: [HoloRenderedEvidenceReference] = []
        for claim in claims {
            for evidenceID in claim.evidenceIDs where !seen.contains(evidenceID) {
                seen.insert(evidenceID)
                let record = evidenceByID[evidenceID]
                references.append(HoloRenderedEvidenceReference(
                    id: evidenceID,
                    summary: record?.redactedExcerpt ?? "（证据缺失）"
                ))
            }
        }

        let summary = claims.isEmpty
            ? "本期暂无显著观察"
            : claims.map(\.displayText).joined(separator: "；")

        return HoloRenderedAgentResult(
            title: title,
            summary: summary,
            sections: sections,
            evidenceReferences: references
        )
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

运行同 Step 2 命令。预期：4 个测试全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Services/AI/Agent/Presentation/HoloAgentResultRenderer.swift HoloTests/Services/AI/Agent/HoloAgentResultRendererTests.swift
git commit -m "fix(iOS): Agent 结果渲染器修复 title/body 同值并暴露 confidence"
```

---

## Task 2: ChatMessage 加 agentResultJSON 持久化字段

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Holo.xcdatamodeld`（ChatMessage entity 加属性）
- Modify: `Models/ChatMessage+CoreDataProperties.swift:33`
- Modify: `Models/ChatMessageViewData.swift`
- Test: `HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`

- [ ] **Step 1: 在 Core Data 模型加 agentResultJSON 属性**

在 Xcode 打开 `Holo.xcdatamodeld` → 选 `ChatMessage` entity → Data Model Inspector 点 `+` 加 Attribute：
- Name: `agentResultJSON`
- Attribute Type: `String`
- Optional: ✅ 勾选
- （不勾 Transient，要持久化）

> 这是加可选属性，属轻量迁移，无需写 migration plan；`NSPersistentContainer` 启动自动迁移。确认 `Holo.xcdatamodeld` 当前 version 标记为 default，新的轻量变更会自动应用。

- [ ] **Step 2: 在 ChatMessage+CoreDataProperties.swift 声明属性**

在 `Models/ChatMessage+CoreDataProperties.swift:33`（`messageType` 下方）加：

```swift
    @NSManaged var messageType: String
    @NSManaged var agentResultJSON: String?  // Agent 深度分析结果 JSON（HoloRenderedAgentResult）
```

- [ ] **Step 3: 写 ChatMessageViewData 编解码失败测试**

创建 `HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`：

```swift
import XCTest
@testable import Holo

final class ChatMessageViewDataAgentResultTests: XCTestCase {

    private func sampleResultJSON() -> String {
        """
        {"title":"本期观察","summary":"支出偏高","sections":[{"title":"观察 1","body":"餐饮超预算","confidence":0.8}],"evidenceReferences":[]}
        """
    }

    func testDecodeAgentResult_validJSON() throws {
        let decoded = ChatMessageViewData.decodeAgentResult(sampleResultJSON())
        let result = try XCTUnwrap(decoded)
        XCTAssertEqual(result.title, "本期观察")
        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections[0].confidence, 0.8, accuracy: 0.001)
    }

    func testDecodeAgentResult_nilInput() {
        XCTAssertNil(ChatMessageViewData.decodeAgentResult(nil))
    }

    func testDecodeAgentResult_invalidJSON() {
        XCTAssertNil(ChatMessageViewData.decodeAgentResult("not a json"))
    }
}
```

- [ ] **Step 4: 运行测试，确认失败**

运行：`test_sim` 过滤 `HoloTests/ChatMessageViewDataAgentResultTests`。
预期：编译失败（`ChatMessageViewData.decodeAgentResult` 不存在）。

- [ ] **Step 5: 实现 — ViewData 加 agentResult 字段 + 解码**

在 `Models/ChatMessageViewData.swift`：

(a) 在属性区（`var analysisContext: AnalysisContext?` 下方，约 49 行）加：
```swift
    var analysisContext: AnalysisContext?
    var agentResult: HoloRenderedAgentResult?
```

(b) 主 init（55-89）参数加 `agentResult: HoloRenderedAgentResult? = nil`（放在 `rawLog` 参数后），并赋值 `self.agentResult = agentResult`。

(c) `init(message:)`（91-107）调用里加 `agentResult: Self.decodeAgentResult(message.agentResultJSON)`。

(d) `init?(dictionary:)`（109-132）调用里加 `agentResult: Self.decodeAgentResult(dictionary["agentResultJSON"] as? String)`。

(e) `init?(lightweightDictionary:)`（136-183）：在 `analysisContext` 解码那段（158-164）后面，加：
```swift
        // queryAnalysis 的 Agent 深度分析结果解码
        if intentStr == AIIntent.queryAnalysis.rawValue {
            self.agentResult = Self.decodeAgentResult(dictionary["agentResultJSON"] as? String)
        } else {
            self.agentResult = nil
        }
```

(f) `enrichMetadata`（186-198）方法签名加 `agentResult: HoloRenderedAgentResult?` 参数，函数体加 `self.agentResult = agentResult`。

(g) 在私有静态方法区（`decodeRawLog` 下方，约 392 行）加：
```swift
    nonisolated static func decodeAgentResult(_ json: String?) -> HoloRenderedAgentResult? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(HoloRenderedAgentResult.self, from: data)
    }
```

- [ ] **Step 6: 运行测试，确认通过**

运行同 Step 4。预期：3 个测试 PASS。

- [ ] **Step 7: Commit**

```bash
git add Holo/Holo\ APP/Holo/Holo/Holo.xcdatamodeld Models/ChatMessage+CoreDataProperties.swift Models/ChatMessageViewData.swift HoloTests/Models/ChatMessageViewDataAgentResultTests.swift
git commit -m "feat(iOS): ChatMessage 新增 agentResultJSON 持久化 Agent 深度分析结果"
```

---

## Task 3: ChatMessageRepository 支持 agentResultJSON

**Files:**
- Modify: `Data/Repositories/ChatMessageRepository.swift`（`finalizeMessage` 433、3 处 fetch 字段列表 77/118/189/272/719）

- [ ] **Step 1: finalizeMessage 加参数**

读 `Data/Repositories/ChatMessageRepository.swift:433` 的 `finalizeMessage` 签名。在参数列表（`analysisContextJSON: String? = nil` 附近）加：
```swift
        agentResultJSON: String? = nil,
```
在函数体里 `message.analysisContextJSON = analysisContextJSON` 附近加：
```swift
        message.agentResultJSON = agentResultJSON
```

- [ ] **Step 2: fetch 字段列表加 agentResultJSON**

文件里所有 `propertiesToFetch` / 字段数组中含 `"analysisContextJSON"` 的位置（77、118、189、272、719 附近），在 `"analysisContextJSON"` 后面追加 `"agentResultJSON"`。逐处确认是在 fetch 字段列表中（`[...]` 数组），不要改错位置。

- [ ] **Step 3: 编译验证**

运行 `build_sim`（XcodeBuildMCP）确认编译通过（Repository 改动纯签名扩展 + 字段追加，有默认值不破坏现有调用方）。

- [ ] **Step 4: Commit**

```bash
git add Data/Repositories/ChatMessageRepository.swift
git commit -m "feat(iOS): ChatMessageRepository 支持 agentResultJSON 读写与查询"
```

---

## Task 4: ChatViewModel Agent 路径结构化存储

**Files:**
- Modify: `Views/Chat/ChatViewModel.swift:272-293`

- [ ] **Step 1: 替换 Agent 路径的拍扁逻辑**

读 `Views/Chat/ChatViewModel.swift:272-293`。当前逻辑：
```swift
if processResult.shouldRouteToAgent {
    self.chatRepo?.setAnalysisLoadingState(aiMessageId, intent: "query_analysis", analysisContext: nil)
    self.streamingText = "正在为你深度分析本地数据…"
    let rendered = await self.analysisService.runAnalysis(question: text)
    var lines = [rendered.title, rendered.summary]
    lines.append(contentsOf: rendered.sections.map(\.body))
    let finalText = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    self.chatRepo?.finalizeMessage(aiMessageId, finalContent: finalText, intent: ..., extractedDataJSON: nil, parsedBatchJSON: nil, executionBatchJSON: nil, analysisContextJSON: nil, rawLogJSON: nil)
}
```

替换为（不再拍扁；fallback 文本用于历史回看退化；agent 结果结构化存储）：
```swift
if processResult.shouldRouteToAgent {
    self.chatRepo?.setAnalysisLoadingState(
        aiMessageId,
        intent: "query_analysis",
        analysisContext: nil
    )
    self.streamingText = "Holo 正在为你深度分析本地数据…"
    let rendered = await self.analysisService.runAnalysis(question: text)

    // fallback 文本：历史回看 / 解码失败时退化展示（仍是结构化的标题+摘要）
    let fallbackText = [rendered.title, rendered.summary]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

    let agentResultJSON = Self.encodeAgentResult(rendered)

    self.chatRepo?.finalizeMessage(
        aiMessageId,
        finalContent: fallbackText,
        intent: processResult.firstIntent?.rawValue,
        extractedDataJSON: nil,
        parsedBatchJSON: nil,
        executionBatchJSON: nil,
        analysisContextJSON: nil,
        agentResultJSON: agentResultJSON,
        rawLogJSON: nil
    )
}
```

- [ ] **Step 2: 加 encodeAgentResult 辅助方法**

在 `ChatViewModel` 里（与 `encodeAnalysisContext` 同区，搜索 `encodeAnalysisContext` 定位）加：
```swift
    private static func encodeAgentResult(_ result: HoloRenderedAgentResult) -> String? {
        guard let data = try? JSONEncoder().encode(result) else { return nil }
        return String(data: data, encoding: .utf8)
    }
```

- [ ] **Step 3: 编译验证 + 模拟器冒烟**

运行 `build_run_sim`，在对话里发「帮我分析近两个月的消费趋势」（需 `agentRuntimeEnabled` 开启，见 `Models/AI/HoloAICapability.swift:134` 或 Settings）。
预期：编译通过；消息不再是一坨纯文本气泡，但因 Task 5-7 未做，当前仍走文本气泡（`finalContent` = title+summary）。确认不崩。

- [ ] **Step 4: Commit**

```bash
git add Views/Chat/ChatViewModel.swift
git commit -m "refactor(iOS): ChatViewModel Agent 路径结构化存储结果，不再拍扁成字符串"
```

---

## Task 5: 新建 AgentDeepAnalysisCard（入口卡，四态）

**Files:**
- Create: `Views/Chat/Analysis/AgentDeepAnalysisCard.swift`

- [ ] **Step 1: 实现入口卡**

创建 `Views/Chat/Analysis/AgentDeepAnalysisCard.swift`（照 `AnalysisCompactChatCard.swift` 的四态模式，数据源换成 `agentResult`）：

```swift
//
//  AgentDeepAnalysisCard.swift
//  Holo
//
//  Agent 深度分析结果的紧凑入口卡片（四态：loading / loaded / unloaded / degrade）
//

import SwiftUI

struct AgentDeepAnalysisCard: View {

    let message: ChatMessageViewData
    var onTap: (() -> Void)? = nil

    var body: some View {
        if message.isStreaming {
            loadingCard
        } else if message.metadataState == .loaded, let result = message.agentResult {
            realCard(result: result)
        } else if message.metadataState == .unloaded || message.metadataState == .loading {
            placeholderCard
        }
        // .loaded 但 agentResult == nil → 不渲染（退化文本气泡，由 MessageBubbleView 处理）
    }

    // MARK: - Real Card

    private func realCard(result: HoloRenderedAgentResult) -> some View {
        Button {
            onTap?()
        } label: {
            ChatCardView {
                CardHeaderView(
                    icon: "sparkles",
                    title: result.title,
                    subtitle: primarySummary(result)
                )

                if let first = result.sections.first {
                    HoloAIHeroMetric(
                        label: "核心观察",
                        value: first.title,
                        note: first.body,
                        tint: .holoTextPrimary
                    )
                }

                HStack(spacing: 6) {
                    Text("查看深度分析")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading Card

    private var loadingCard: some View {
        ChatCardView {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Holo 正在深度分析中…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        ChatCardView {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func primarySummary(_ result: HoloRenderedAgentResult) -> String {
        let count = result.sections.count
        if result.summary.isEmpty {
            return count > 0 ? "共 \(count) 条观察" : "本期暂无显著观察"
        }
        return result.summary
    }
}
```

- [ ] **Step 2: SF Symbol 校验**

`sparkles` / `chevron.right` 已在项目其它处使用（`MessageBubbleView` 的 aiAvatar 用 `sparkles`），确认有效。无需额外验证。

- [ ] **Step 3: 编译验证**

运行 `build_sim`。预期：编译通过（`ChatCardView` / `CardHeaderView` / `HoloAIHeroMetric` / `CardButtonStyle` 均在 `Views/Chat/Cards/ChatCardView.swift`）。

- [ ] **Step 4: Commit**

```bash
git add Views/Chat/Analysis/AgentDeepAnalysisCard.swift
git commit -m "feat(iOS): 新增 AgentDeepAnalysisCard 深度分析入口卡片（四态）"
```

---

## Task 6: 新建 AgentDeepAnalysisDetailSheet（详情页）

**Files:**
- Create: `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift`

- [ ] **Step 1: 实现详情页**

创建 `Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift`（照 `AnalysisDetailSheet.swift` 的结构：header + 核心结论卡 + 事实段 + 证据段）：

```swift
//
//  AgentDeepAnalysisDetailSheet.swift
//  Holo
//
//  Agent 深度分析详情 Sheet：核心结论 + 事实段（每条 claim）+ 证据段
//

import SwiftUI

struct AgentDeepAnalysisDetailSheet: View {

    let result: HoloRenderedAgentResult

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                coreConclusion
                factsSection
                evidenceSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 34)
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 38, height: 38)
                    .background(Color.holoPrimary.opacity(0.12))
                    .clipShape(Circle())
                Text("深度分析")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
            Text(result.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)
        }
    }

    // MARK: - Core Conclusion

    private var coreConclusion: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("核心结论")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.holoPrimary)
                .tracking(0.6)

            Text(result.summary.isEmpty ? "本期暂无显著观察" : result.summary)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.holoPrimary.opacity(0.10), Color.holoCardBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.13), lineWidth: 1)
        )
    }

    // MARK: - Facts Section（每条 claim 一项）

    @ViewBuilder
    private var factsSection: some View {
        if !result.sections.isEmpty {
            HoloAISectionLabel(text: "观察")
            VStack(spacing: 12) {
                ForEach(Array(result.sections.enumerated()), id: \.offset) { _, section in
                    HoloAIFactItem(kicker: section.title, bodyText: section.body)
                }
            }
        }
    }

    // MARK: - Evidence Section

    @ViewBuilder
    private var evidenceSection: some View {
        if !result.evidenceReferences.isEmpty {
            HoloAISectionLabel(text: "数据依据")
            VStack(spacing: 10) {
                ForEach(Array(result.evidenceReferences.enumerated()), id: \.offset) { _, ref in
                    HoloAIFactItem(kicker: "依据", bodyText: ref.summary)
                }
            }
        }
    }
}
```

- [ ] **Step 2: 确认 HoloAIFactItem / HoloAISectionLabel 签名**

这两个组件在 `AnalysisDetailSheet.swift` 中已使用（`HoloAIFactItem(kicker:bodyText:)`、`HoloAISectionLabel(text:)`）。签名匹配，无需改动。

- [ ] **Step 3: 编译验证**

运行 `build_sim`。预期：编译通过。

- [ ] **Step 4: Commit**

```bash
git add Views/Chat/Analysis/AgentDeepAnalysisDetailSheet.swift
git commit -m "feat(iOS): 新增 AgentDeepAnalysisDetailSheet 深度分析详情页"
```

---

## Task 7: MessageBubbleView agent 消息走新卡片 + ChatView 接 Sheet

**Files:**
- Modify: `Views/Chat/MessageBubbleView.swift:105-119`
- Modify: `Views/Chat/ChatView.swift`（agent 详情 sheet state + onTap 回调）

- [ ] **Step 1: MessageBubbleView 加 agent 分支**

读 `Views/Chat/MessageBubbleView.swift:105-119`。当前 `message.isQueryAnalysis` 分支判断 `analysisContext != nil` 走 `AnalysisCompactChatCard`，否则退化文本气泡。

改造为：先判断 agent 结果。把 105-119 的 `else if message.isQueryAnalysis { ... }` 块替换为：

```swift
                } else if message.isQueryAnalysis {
                    if message.agentResult != nil || message.isStreaming {
                        // Agent 深度分析：走新卡片（loading 态 / 结果卡）
                        AgentDeepAnalysisCard(message: message) {
                            onAgentDeepAnalysisTap?()
                        }
                    } else if message.analysisContext != nil {
                        // 账单分析（流式 analysisContext 路径）
                        AnalysisCompactChatCard(message: message) {
                            onCompactAnalysisTap?()
                        }
                    } else {
                        // 无分析数据（退化或加载失败）→ 普通气泡
                        bubbleContent
                    }
                } else if hasAnalysisCards {
```

- [ ] **Step 2: MessageBubbleView 加 onAgentDeepAnalysisTap 回调**

在 `MessageBubbleView` 的属性区（与 `onCompactAnalysisTap` 同处，搜索定位）加：
```swift
    var onAgentDeepAnalysisTap: (() -> Void)? = nil
```

- [ ] **Step 3: ChatView 加 agent 详情 Sheet state**

读 `Views/Chat/ChatView.swift`，找到 `selectedAnalysisMessage`（约 487-488 附近 `.sheet(item:)` 用）。在同级加 agent 选中状态：

```swift
    @State private var selectedAgentMessage: ChatMessageViewData? = nil
```

在渲染 `MessageBubbleView` 的地方（搜索 `onCompactAnalysisTap` 传参处），加：
```swift
                        onAgentDeepAnalysisTap: {
                            selectedAgentMessage = message
                        }
```

在 `.sheet(item:)` 区（analysisDetail 附近）加 agent sheet：
```swift
        .sheet(item: $selectedAgentMessage) { message in
            if let result = message.agentResult {
                AgentDeepAnalysisDetailSheet(result: result)
            }
        }
```

- [ ] **Step 4: （无需额外改动）**

`ChatMessageViewData` 已符合 `Identifiable`（`Models/ChatMessageViewData.swift:34`），`.sheet(item: $selectedAgentMessage)` 可直接用。`HoloRenderedAgentResult` **不需要**加 `Identifiable`——避开给 Codable 加非可选 `id` 字段、导致旧 JSON 缺该字段时解码失败的坑。

- [ ] **Step 5: 编译 + 模拟器端到端验证**

运行 `build_run_sim`。在对话里发分析类问题（确保 `agentRuntimeEnabled` 开启）。
预期：
1. Agent 分析中显示「Holo 正在深度分析中…」loading 卡片
2. 分析完成显示结果卡（标题 + 核心观察 + 「查看深度分析」CTA）
3. 点卡片弹出详情 Sheet（核心结论 + 观察段 + 数据依据段）
4. 不再是一坨纯文本气泡

- [ ] **Step 6: Commit**

```bash
git add Views/Chat/MessageBubbleView.swift Views/Chat/ChatView.swift
git commit -m "feat(iOS): Agent 深度分析消息接入卡片渲染与详情 Sheet"
```

---

## Task 8: 端到端集成验证 + 回归

**Files:** 无新增（验证性任务）

- [ ] **Step 1: 跑全部新增测试**

运行：`test_sim` 全量，或过滤两个新测试类：
```
xcodebuild test -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:HoloTests/HoloAgentResultRendererTests \
  -only-testing:HoloTests/ChatMessageViewDataAgentResultTests
```
预期：全 PASS。

- [ ] **Step 2: 模拟器回归验证**

`build_run_sim`，验证：
1. **Agent 深度分析**：发「分析近两月消费」→ loading 卡 → 结果卡 → 详情 Sheet ✅
2. **账单分析（流式）未回归**：发普通分析问题（`agentRuntimeEnabled` 关时）→ 仍走 `AnalysisCompactChatCard` + `AnalysisDetailSheet` ✅
3. **历史消息回看**：杀 App 重开，之前的 Agent 消息仍能显示卡片（`agentResultJSON` 持久化生效）；更早的旧消息（无 agentResultJSON）退化为文本气泡 ✅
4. **错误态**：Agent 失败时（可断网模拟）→ 退化文本气泡，不崩 ✅

- [ ] **Step 3: 更新 CHANGELOG + TODO**

在 `CHANGELOG.md` 顶部加：
```
## [2026-06-14] HoloAI Agent 深度分析卡片化（阶段 1）

### 新增
- Agent 深度分析结果改为卡片承载（入口卡四态 + 详情 Sheet），替代原纯文本气泡
- 详情页结构化：核心结论卡 + 观察段 + 数据依据段
- ChatMessage 新增 agentResultJSON 持久化字段

### 修复
- HoloAgentResultRenderer section.title/body 同值浪费
```

`TODO.md`：把「深度分析卡片化 阶段 1」标记完成，阶段 2（可视化）/3（目标感受工具）/4（文案）列为待办。

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md TODO.md
git commit -m "docs: 阶段 1 完成记入 CHANGELOG 与 TODO"
```

---

## Self-Review 备注

- **Spec 覆盖**：阶段 1 的「卡片化 + 排版 + loading 文案 Holo 化」全部由 Task 1-8 覆盖；`HoloAgentResultRenderer` 修复（Task 1）+ 结构化存储（Task 2-4）+ 卡片/详情（Task 5-6）+ 接线（Task 7）+ 验证（Task 8）。
- **类型一致性**：`HoloRenderedAgentResult` 在 Task 1 加 `confidence`，Task 7 加 `Identifiable`/`id`；`ChatMessageViewData.agentResult` / `decodeAgentResult` / `encodeAgentResult` 跨 Task 2/4 命名一致；`finalizeMessage` 的 `agentResultJSON` 参数在 Task 3 加、Task 4 调用。
- **阶段 2 铺路**：Task 1 暴露的 `section.confidence` + 已有 `metricAssertions`（claim 层，未丢弃但渲染层暂未用）为阶段 2 的 metric → viz 映射留好钩子。
- **后续阶段**：阶段 2（可视化）、阶段 3（目标/感受工具）、阶段 4（全局 AI 文案）各自独立 plan，待阶段 1 落地后基于真实代码再写。
