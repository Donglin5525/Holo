# HoloAI 数据洞察卡片化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 HoloAI 分析查询结果从 Chat 直接展开改为「紧凑入口卡片 + Sheet 详情」模式

**Architecture:** 复用现有 `AnalysisContext` + `ChatCardData.fromAnalysisContext(_:)` 管线，新增紧凑卡片和 Sheet 层。AI 文本中的 `{{card:xxx}}` 标记控制卡片插入位置，无标记时使用默认插入策略。

**Tech Stack:** SwiftUI, Swift 5+, MVVM, Core Data

**Design Doc:** `docs/chat/plans/2026-05-10-insight-card-design.md`

**Source Root:** `Holo/Holo APP/Holo/Holo/`（以下文件路径均相对于项目根目录 `HOLO/`）

---

## File Structure

### New Files

| File | Responsibility | ~Lines |
|------|----------------|--------|
| `{SRC}Views/Chat/Analysis/AnalysisSummaryFormatter.swift` | AnalysisContext → AnalysisCompactSummary 纯逻辑转换 | ~100 |
| `{SRC}Views/Chat/Analysis/AnalysisCompactChatCard.swift` | Chat 中的紧凑入口卡片（含占位态） | ~100 |
| `{SRC}Views/Chat/Analysis/MarkdownRenderer.swift` | Markdown → AttributedString 解析工具（从 StreamingTextView 提取） | ~30 |
| `{SRC}Views/Chat/Analysis/AnalysisDetailBlockParser.swift` | AI 文本标记解析 + 默认插入策略 | ~130 |
| `{SRC}Views/Chat/Analysis/AnalysisDetailSheet.swift` | Sheet 详情主视图（AI 文本 + 嵌入卡片） | ~150 |

### Modified Files

| File | Change |
|------|--------|
| `{SRC}Views/Chat/StreamingTextView.swift` | 提取 Markdown 解析为 MarkdownRenderer，自身调用新工具 |
| `{SRC}Views/Chat/MessageBubbleView.swift` | `intent == .queryAnalysis` 时渲染 AnalysisCompactChatCard |
| `{SRC}Views/Chat/ChatView.swift` | 新增 `selectedAnalysisMessage` Sheet 状态 + 弹出 AnalysisDetailSheet |
| `{SRC}Services/AI/PromptManager.swift` | `analysisPrompt` 末尾追加可选标记指令 |
| `{SRC}Models/ChatMessageViewData.swift` | 新增 `isQueryAnalysis` 便利属性 |

> `{SRC}` = `Holo/Holo APP/Holo/Holo/`

---

## Task 1: AnalysisSummaryFormatter

**Files:**
- Create: `{SRC}Views/Chat/Analysis/AnalysisSummaryFormatter.swift`

**Goal:** 从 `AnalysisContext` 生成紧凑摘要数据，供紧凑卡片和 Sheet 标题使用。

- [ ] **Step 1: 创建 Analysis 目录和文件**

在 `{SRC}Views/Chat/` 下新建 `Analysis/` 目录，创建 `AnalysisSummaryFormatter.swift`：

```swift
//
//  AnalysisSummaryFormatter.swift
//  Holo
//
//  从 AnalysisContext 生成紧凑摘要
//

import Foundation

/// 分析查询紧凑摘要
struct AnalysisCompactSummary: Equatable {
    let icon: String
    let title: String
    let subtitle: String
    let summaryLine: String
}

/// 从 AnalysisContext 生成紧凑摘要
enum AnalysisSummaryFormatter {

    static func format(from context: AnalysisContext) -> AnalysisCompactSummary? {
        let periodLabel = resolvePeriodLabel(context)

        switch context.domain {
        case .finance:
            return formatFinance(context: context, periodLabel: periodLabel)
        case .habit:
            return formatHabit(context: context, periodLabel: periodLabel)
        case .task:
            return formatTask(context: context, periodLabel: periodLabel)
        case .thought:
            return formatThought(context: context, periodLabel: periodLabel)
        case .crossModule:
            return formatCrossModule(context: context, periodLabel: periodLabel)
        }
    }

    // MARK: - Finance

    private static func formatFinance(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let finance = context.finance else { return nil }

        let totalExpense = NumberFormatter.compactCurrency(finance.totalExpense)
        let dailyAvg = NumberFormatter.compactCurrency(finance.averageDailyExpense)

        var changePart = ""
        if let previous = finance.previousPeriodExpense, previous > 0 {
            let diff = finance.totalExpense - previous
            let percent = Double(truncating: NSDecimalNumber(decimal: abs(diff) / previous * 100))
            if diff < 0 {
                changePart = " · 较上期 ↓\(String(format: "%.1f", percent))%"
            } else if diff > 0 {
                changePart = " · 较上期 ↑\(String(format: "%.1f", percent))%"
            }
        }

        return AnalysisCompactSummary(
            icon: "yensign",
            title: "账单分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "总支出 \(totalExpense) · 日均 \(dailyAvg)\(changePart)"
        )
    }

    // MARK: - Habit

    private static func formatHabit(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let habit = context.habit else { return nil }

        var parts: [String] = []
        if let rate = habit.averageCompletionRate {
            parts.append("完成率 \(String(format: "%.0f%%", rate * 100))")
        }
        parts.append("活跃 \(habit.activeHabitCount) 个")
        let maxStreak = habit.streaks.map(\.currentStreak).max() ?? 0
        if maxStreak > 0 {
            parts.append("最佳连续 \(maxStreak) 天")
        }

        return AnalysisCompactSummary(
            icon: "flame",
            title: "习惯分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: parts.joined(separator: " · ")
        )
    }

    // MARK: - Task

    private static func formatTask(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let task = context.task else { return nil }

        let ratePercent = String(format: "%.0f%%", task.completionRate * 100)

        return AnalysisCompactSummary(
            icon: "checklist",
            title: "任务分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "完成率 \(ratePercent) · 完成 \(task.completedCount)/\(task.totalCount) · 逾期 \(task.overdueCount)"
        )
    }

    // MARK: - Thought

    private static func formatThought(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let thought = context.thought else { return nil }

        return AnalysisCompactSummary(
            icon: "lightbulb",
            title: "想法分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "想法 \(thought.totalCount) 条 · 标签 \(thought.topTags.count) 个 · 心情分布 \(thought.moodDistribution.count) 类"
        )
    }

    // MARK: - CrossModule

    private static func formatCrossModule(context: AnalysisContext, periodLabel: String) -> AnalysisCompactSummary? {
        guard let cross = context.crossModule else { return nil }

        return AnalysisCompactSummary(
            icon: "chart.bar.xaxis",
            title: "综合分析 · \(periodLabel)",
            subtitle: periodLabel,
            summaryLine: "亮点 \(cross.highlights.count) 条 · 提醒 \(cross.warnings.count) 条"
        )
    }

    // MARK: - Period Label

    private static func resolvePeriodLabel(_ context: AnalysisContext) -> String {
        if !context.periodLabel.isEmpty {
            return context.periodLabel
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月"

        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"

        guard let start = inputFormatter.date(from: context.startDate),
              let end = inputFormatter.date(from: context.endDate) else {
            return "\(context.startDate) — \(context.endDate)"
        }

        return "\(formatter.string(from: start)) — \(formatter.string(from: end))"
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AnalysisSummaryFormatter.swift"
git commit -m "feat(iOS): 新增 AnalysisSummaryFormatter 紧凑摘要生成器"
```

---

## Task 2: AnalysisCompactChatCard

**Files:**
- Create: `{SRC}Views/Chat/Analysis/AnalysisCompactChatCard.swift`

**Goal:** Chat 中的紧凑入口卡片，替代现有分析卡片直接展开模式。支持三种状态：占位态（元数据未加载）、真实紧凑卡片、无数据退化。

- [ ] **Step 1: 创建 AnalysisCompactChatCard**

创建 `{SRC}Views/Chat/Analysis/AnalysisCompactChatCard.swift`：

```swift
//
//  AnalysisCompactChatCard.swift
//  Holo
//
//  Chat 中的分析结果紧凑入口卡片
//

import SwiftUI

struct AnalysisCompactChatCard: View {

    let message: ChatMessageViewData
    var onTap: (() -> Void)? = nil

    var body: some View {
        if message.metadataState == .loaded, let context = message.analysisContext,
           let summary = AnalysisSummaryFormatter.format(from: context) {
            // 真实紧凑卡片
            realCard(summary: summary)
        } else if message.metadataState == .unloaded || message.metadataState == .loading {
            // 占位态
            placeholderCard
        }
        // .loaded 但 analysisContext == nil → 不渲染（退化为普通气泡，由 MessageBubbleView 处理）
    }

    // MARK: - Real Card

    private func realCard(summary: AnalysisCompactSummary) -> some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // 标题行
                HStack(spacing: 6) {
                    Image(systemName: summary.icon)
                        .font(.system(size: 16))
                        .foregroundColor(.holoPrimary)
                    Text(summary.title)
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)
                        .lineLimit(1)
                }

                // 摘要行
                Text(summary.summaryLine)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                // 提示行
                HStack(spacing: 4) {
                    Text("点击查看详细分析")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }
            }
            .padding(HoloSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Placeholder

    private var placeholderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16))
                    .foregroundColor(.holoTextSecondary)
                Text("分析结果加载中...")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AnalysisCompactChatCard.swift"
git commit -m "feat(iOS): 新增 AnalysisCompactChatCard 紧凑入口卡片"
```

---

## Task 3: MarkdownRenderer

**Files:**
- Create: `{SRC}Views/Chat/Analysis/MarkdownRenderer.swift`
- Modify: `{SRC}Views/Chat/StreamingTextView.swift`

**Goal:** 将 StreamingTextView 中的 Markdown 解析逻辑提取为独立工具方法，供 AnalysisDetailSheet 和 StreamingTextView 共享。

- [ ] **Step 1: 创建 MarkdownRenderer**

创建 `{SRC}Views/Chat/Analysis/MarkdownRenderer.swift`：

```swift
//
//  MarkdownRenderer.swift
//  Holo
//
//  Markdown → AttributedString 解析工具
//  从 StreamingTextView 提取，供 Sheet 等场景共享
//

import Foundation

enum MarkdownRenderer {

    /// 判断文本是否值得尝试 Markdown 渲染
    static func shouldRender(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 2_000 else { return false }
        let indicators = ["**", "`", "#", "- ", "* ", "[", "> "]
        return indicators.contains { text.contains($0) }
    }

    /// 异步解析 Markdown 文本为 AttributedString
    static func parse(_ text: String) async -> AttributedString? {
        await Task.detached(priority: .utility) {
            try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }.value
    }

    /// 同步解析（短文本可用，不在热路径上使用）
    static func parseSync(_ text: String) -> AttributedString? {
        try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}
```

- [ ] **Step 2: 更新 StreamingTextView 使用 MarkdownRenderer**

修改 `{SRC}Views/Chat/StreamingTextView.swift`：

**替换** `shouldRenderMarkdown` 计算属性（第 55-59 行）为：

```swift
    private var shouldRenderMarkdown: Bool {
        MarkdownRenderer.shouldRender(text)
    }
```

**替换** `parseMarkdown` 静态方法（第 63-69 行）为：

```swift
    private static func parseMarkdown(_ text: String) async -> AttributedString? {
        await MarkdownRenderer.parse(text)
    }
```

**删除** 第 61 行的 `markdownIndicators` 静态属性：

```swift
    // 删除这行
    private static let markdownIndicators = ["**", "`", "#", "- ", "* ", "[", "> "]
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED（行为与改动前完全一致，只是提取了共享工具）

- [ ] **Step 4: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/MarkdownRenderer.swift" \
        "Holo/Holo APP/Holo/Holo/Views/Chat/StreamingTextView.swift"
git commit -m "refactor(iOS): 提取 MarkdownRenderer 共享 Markdown 解析逻辑"
```

---

## Task 4: AnalysisDetailBlockParser

**Files:**
- Create: `{SRC}Views/Chat/Analysis/AnalysisDetailBlockParser.swift`

**Goal:** 定义 Sheet 内的渲染模型，解析 AI 文本中的 `{{card:xxx}}` 标记，实现默认插入策略。

- [ ] **Step 1: 创建 AnalysisDetailBlockParser**

创建 `{SRC}Views/Chat/Analysis/AnalysisDetailBlockParser.swift`：

```swift
//
//  AnalysisDetailBlockParser.swift
//  Holo
//
//  AI 文本标记解析 + 默认插入策略
//

import Foundation

/// Sheet 内的渲染块类型
enum AnalysisDetailBlock: Equatable {
    case text(String)
    case card(AnalysisCardSlot)
}

/// 分析卡片插槽，与 ChatCardData 的分析类型一一对应
enum AnalysisCardSlot: String, CaseIterable {
    case summary
    case breakdown
    case trend
    case comparison
    case highlights
}

/// AI 文本 → [AnalysisDetailBlock] 解析器
enum AnalysisDetailBlockParser {

    /// 标记行前缀
    private static let markerPrefix = "{{card:"
    private static let markerSuffix = "}}"

    /// 解析 AI 文本，识别标记并生成渲染块序列
    /// - Parameters:
    ///   - text: AI Markdown 文本
    ///   - availableSlots: 当前 AnalysisContext 实际可生成的卡片类型
    /// - Returns: 有序渲染块列表
    static func parse(text: String, availableSlots: Set<AnalysisCardSlot>) -> [AnalysisDetailBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [AnalysisDetailBlock] = []
        var textBuffer: [String] = []
        var usedSlots = Set<AnalysisCardSlot>()

        for line in lines {
            if let slot = parseMarker(line) {
                // 遇到标记：先 flush 文本 buffer
                flushTextBuffer(&textBuffer, into: &blocks)

                // 只使用第一次出现的标记，且该 slot 必须在 availableSlots 中
                if usedSlots.insert(slot).inserted, availableSlots.contains(slot) {
                    blocks.append(.card(slot))
                }
                // 重复标记或不可用的标记直接忽略（不保留为文本）
            } else {
                textBuffer.append(line)
            }
        }
        flushTextBuffer(&textBuffer, into: &blocks)

        // 检查是否使用了任何标记
        let parsedSlots = Set(blocks.compactMap { block -> AnalysisCardSlot? in
            if case .card(let slot) = block { return slot }
            return nil
        })

        // AI 没有输出任何有效标记时，使用默认插入策略
        if parsedSlots.isEmpty {
            return applyDefaultStrategy(text: text, availableSlots: availableSlots)
        }

        // 补充未被标记引用但可用的卡片（追加到末尾）
        var result = blocks
        let referencedSlots = parsedSlots
        for slot in AnalysisCardSlot.allCases {
            if !referencedSlots.contains(slot), availableSlots.contains(slot) {
                result.append(.card(slot))
            }
        }

        return result
    }

    // MARK: - Marker Parsing

    private static func parseMarker(_ line: String) -> AnalysisCardSlot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(markerPrefix), trimmed.hasSuffix(markerSuffix) else { return nil }
        let rawValue = String(trimmed.dropFirst(markerPrefix.count).dropLast(markerSuffix.count))
        return AnalysisCardSlot(rawValue: rawValue)
    }

    // MARK: - Text Buffer

    private static func flushTextBuffer(_ buffer: inout [String], into blocks: inout [AnalysisDetailBlock]) {
        guard !buffer.isEmpty else { return }
        let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        buffer.removeAll()
    }

    // MARK: - Default Insertion Strategy

    /// 无标记时的默认卡片插入策略
    private static func applyDefaultStrategy(text: String, availableSlots: Set<AnalysisCardSlot>) -> [AnalysisDetailBlock] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let n = paragraphs.count
        var result: [AnalysisDetailBlock] = []

        // 所有段落先转为 text block
        for para in paragraphs {
            result.append(.text(para))
        }

        // 确定可用的卡片（按 slot 声明顺序）
        let orderedSlots = AnalysisCardSlot.allCases.filter { availableSlots.contains($0) }
        guard !orderedSlots.isEmpty else { return result }

        // 少于 3 段：所有卡片追加到末尾
        if n < 3 {
            for slot in orderedSlots {
                result.append(.card(slot))
            }
            return result
        }

        // 计算插入点
        let summaryInsertIndex = 1                      // 第 1 段之后
        let midInsertIndex = max(1, n / 2)              // 中间位置
        let highlightsInsertIndex = n - 1               // 最后一段之前

        // 生成 (insertIndex, slotOrder, slot) 并按 (insertIndex, slotOrder) 排序
        var insertions: [(insertIndex: Int, slotOrder: Int, slot: AnalysisCardSlot)] = []

        for (order, slot) in orderedSlots.enumerated() {
            let index: Int
            switch slot {
            case .summary:
                index = summaryInsertIndex
            case .highlights:
                index = highlightsInsertIndex
            default: // breakdown, trend, comparison
                index = midInsertIndex
            }
            insertions.append((index, order, slot))
        }

        // 稳定排序：先按 insertIndex 升序，再按 slotOrder 升序
        insertions.sort { a, b in
            if a.insertIndex != b.insertIndex { return a.insertIndex < b.insertIndex }
            return a.slotOrder < b.slotOrder
        }

        // 从后向前插入（避免索引偏移）
        for insertion in insertions.reversed() {
            result.insert(.card(insertion.slot), at: insertion.insertIndex)
        }

        return result
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AnalysisDetailBlockParser.swift"
git commit -m "feat(iOS): 新增 AnalysisDetailBlockParser 标记解析和默认插入策略"
```

---

## Task 5: AnalysisDetailSheet

**Files:**
- Create: `{SRC}Views/Chat/Analysis/AnalysisDetailSheet.swift`

**Goal:** 分析结果的 Sheet 详情视图，展示 AI 文本和嵌入的数据卡片。

- [ ] **Step 1: 创建 AnalysisDetailSheet**

创建 `{SRC}Views/Chat/Analysis/AnalysisDetailSheet.swift`：

```swift
//
//  AnalysisDetailSheet.swift
//  Holo
//
//  分析结果详情 Sheet
//  AI 文本为主体，数据卡片作为可视化辅助嵌入
//

import SwiftUI

struct AnalysisDetailSheet: View {

    let message: ChatMessageViewData

    @State private var renderedBlocks: [AnalysisDetailBlockRenderItem] = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // 标题区
                header

                // 内容区：AI 文本 + 嵌入卡片
                ForEach(renderedBlocks) { item in
                    switch item.block {
                    case .text(let text):
                        textBlock(text)
                    case .card(let slot):
                        cardBlock(slot)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.holoBackground)
        .presentationDetents([.medium, .large])
        .task {
            buildBlocks()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let context = message.analysisContext,
               let summary = AnalysisSummaryFormatter.format(from: context) {
                HStack(spacing: 8) {
                    Image(systemName: summary.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.holoPrimary)
                    Text(domainLabel(context.domain))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.holoTextPrimary)
                }
                Text(summary.subtitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Text Block

    private func textBlock(_ text: String) -> some View {
        Text(MarkdownRenderer.parseSync(text) ?? AttributedString(text))
            .font(.holoBody)
            .foregroundColor(.holoTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Card Block

    @ViewBuilder
    private func cardBlock(_ slot: AnalysisCardSlot) -> some View {
        if let cardData = slotToCardData(slot) {
            switch cardData {
            case .analysisSummary(let data):
                AnalysisSummaryChatCard(data: data)
            case .analysisBreakdown(let data):
                AnalysisBreakdownChatCard(data: data)
            case .analysisTrend(let data):
                AnalysisTrendChatCard(data: data)
            case .analysisComparison(let data):
                AnalysisComparisonChatCard(data: data)
            case .analysisHighlights(let data):
                AnalysisHighlightsChatCard(data: data)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    private func buildBlocks() {
        let text = message.content
        let availableSlots = computeAvailableSlots()
        let blocks = AnalysisDetailBlockParser.parse(text: text, availableSlots: availableSlots)
        renderedBlocks = blocks.enumerated().map { index, block in
            AnalysisDetailBlockRenderItem(id: index, block: block)
        }
    }

    private func computeAvailableSlots() -> Set<AnalysisCardSlot> {
        let cards = message.analysisCards
        var slots = Set<AnalysisCardSlot>()

        for card in cards {
            switch card {
            case .analysisSummary: slots.insert(.summary)
            case .analysisBreakdown: slots.insert(.breakdown)
            case .analysisTrend: slots.insert(.trend)
            case .analysisComparison: slots.insert(.comparison)
            case .analysisHighlights: slots.insert(.highlights)
            default: break
            }
        }

        return slots
    }

    private func slotToCardData(_ slot: AnalysisCardSlot) -> ChatCardData? {
        for card in message.analysisCards {
            switch card {
            case .analysisSummary where slot == .summary,
                 .analysisBreakdown where slot == .breakdown,
                 .analysisTrend where slot == .trend,
                 .analysisComparison where slot == .comparison,
                 .analysisHighlights where slot == .highlights:
                return card
            default:
                continue
            }
        }
        return nil
    }

    private func domainLabel(_ domain: AnalysisDomain) -> String {
        switch domain {
        case .finance: return "账单分析"
        case .habit: return "习惯分析"
        case .task: return "任务分析"
        case .thought: return "想法分析"
        case .crossModule: return "综合分析"
        }
    }
}

/// ForEach 渲染包装
private struct AnalysisDetailBlockRenderItem: Identifiable {
    let id: Int
    let block: AnalysisDetailBlock
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/Analysis/AnalysisDetailSheet.swift"
git commit -m "feat(iOS): 新增 AnalysisDetailSheet 分析详情 Sheet 视图"
```

---

## Task 6: 集成 — MessageBubbleView + ChatView + ChatMessageViewData

**Files:**
- Modify: `{SRC}Models/ChatMessageViewData.swift`
- Modify: `{SRC}Views/Chat/MessageBubbleView.swift`
- Modify: `{SRC}Views/Chat/ChatView.swift`

**Goal:** 将紧凑卡片和 Sheet 接入现有聊天界面。

### ChatMessageViewData 改动

- [ ] **Step 1: 添加 `isQueryAnalysis` 便利属性**

在 `{SRC}Models/ChatMessageViewData.swift` 的 `analysisCards` 计算属性之后（约第 188 行后）添加：

```swift
    /// 是否为分析查询消息
    var isQueryAnalysis: Bool {
        guard let intentStr = intent,
              let intent = AIIntent(rawValue: intentStr) else { return false }
        return intent == .queryAnalysis
    }
```

### MessageBubbleView 改动

- [ ] **Step 2: 修改 body 中的渲染逻辑**

在 `{SRC}Views/Chat/MessageBubbleView.swift` 中修改 body 的渲染优先级判断。

**替换** 第 63-84 行的渲染优先级块：

```swift
                // 渲染优先级：分析紧凑卡片 > 分析卡片展开（旧路径兜底） > 批处理卡片 > 单卡片 > 气泡
                if message.isQueryAnalysis {
                    // 分析查询：紧凑入口卡片
                    AnalysisCompactChatCard(message: message) {
                        onCompactAnalysisTap?()
                    }
                } else if hasAnalysisCards {
                    // 旧路径兜底：卡片 + 文本叠加渲染（兼容非 query_analysis 但有分析卡片的场景）
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(analysisCardsData.enumerated()), id: \.offset) { index, card in
                            cardView(for: card)
                        }
                        if !displayText.isEmpty {
                            bubbleContent
                        }
                    }
                } else if hasCards {
                    if cards.count > 1 {
                        multiCardView(cards: cards)
                    } else {
                        cardView(for: cards[0])
                    }
                } else if let card = singleCard {
                    cardView(for: card)
                } else {
                    bubbleContent
                }
```

- [ ] **Step 3: 添加紧凑卡片点击回调和意图标签条件**

在 `{SRC}Views/Chat/MessageBubbleView.swift` 顶部的属性声明区（第 17 行后）添加回调：

```swift
    var onCompactAnalysisTap: (() -> Void)? = nil
```

修改第 87 行的意图标签显示条件，增加 `!message.isQueryAnalysis`：

```swift
                if let intent = message.intent, !isUser, !hasCards, singleCard == nil, !hasAnalysisCards, !message.isQueryAnalysis {
```

### ChatView 改动

- [ ] **Step 4: 添加 Sheet 状态和展示逻辑**

在 `{SRC}Views/Chat/ChatView.swift` 的 `@State` 属性区（第 18 行后）添加：

```swift
    @State private var selectedAnalysisMessage: ChatMessageViewData?
```

在 body 的 `.fullScreenCover` 之后（第 61 行后）添加 Sheet：

```swift
        .sheet(item: $selectedAnalysisMessage) { msg in
            AnalysisDetailSheet(message: msg)
        }
```

- [ ] **Step 5: 传递紧凑卡片点击回调**

在 `messageList` 的 `MessageBubbleView` 构造中（约第 182-194 行），添加 `onCompactAnalysisTap` 参数：

```swift
                        MessageBubbleView(
                            message: message,
                            streamingText: viewModel.isStreaming && message.isStreaming ? viewModel.streamingText : nil,
                            onIntentTagTap: { msg in
                                handleIntentTagTap(msg)
                            },
                            onCardTap: { message, cardData in
                                handleCardTap(message: message, cardData: cardData)
                            },
                            onViewLog: { msg in
                                viewingLogMessage = msg
                            },
                            onCompactAnalysisTap: {
                                guard message.metadataState == .loaded,
                                      message.analysisContext != nil else { return }
                                selectedAnalysisMessage = message
                            }
                        )
```

- [ ] **Step 6: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Models/ChatMessageViewData.swift" \
        "Holo/Holo APP/Holo/Holo/Views/Chat/MessageBubbleView.swift" \
        "Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift"
git commit -m "feat(iOS): 集成紧凑分析卡片和详情 Sheet 到聊天界面"
```

---

## Task 7: PromptManager 追加标记指令

**Files:**
- Modify: `{SRC}Services/AI/PromptManager.swift`

**Goal:** 在 `analysisPrompt` 末尾追加可选卡片标记指令，让新生成的分析文本开始携带 `{{card:xxx}}` 标记。

- [ ] **Step 1: 追加标记指令**

在 `{SRC}Services/AI/PromptManager.swift` 的 `analysisPrompt` 模板中（第 669 行 `- 控制在 300-500 字` 之后，第 670 行 `"""` 之前），追加：

```text

## 卡片标记

你可以在分析文本中插入卡片标记，用来建议数据卡片出现的位置：
- {{card:summary}}：关键指标概览
- {{card:breakdown}}：分类、分布或排行
- {{card:trend}}：趋势走向
- {{card:comparison}}：本期与上期对比
- {{card:highlights}}：亮点与提醒

规则：
1. 标记是可选的，只在相关段落后使用。
2. 每种标记最多使用一次。
3. 标记必须独占一行。
4. 不要为了使用标记而编造数据。
5. 如果不确定是否适合插入卡片，可以不输出标记。
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/PromptManager.swift"
git commit -m "feat(iOS): analysisPrompt 追加可选卡片标记指令"
```

---

## 验收清单

实施完成后，逐项确认：

- [ ] Chat 中 `queryAnalysis` 意图消息只显示一个紧凑入口卡片（非旧的多卡片展开模式）
- [ ] 紧凑卡片显示域图标、标题、摘要行和"点击查看详细分析"提示
- [ ] 元数据未加载时显示占位卡片（"分析结果加载中..."），禁用点击
- [ ] 元数据加载后占位卡片自动切换为真实紧凑卡片
- [ ] 点击紧凑卡片弹出 AnalysisDetailSheet
- [ ] Sheet 内显示完整 AI 文本（Markdown 渲染）
- [ ] Sheet 内嵌入现有分析卡片（Summary、Breakdown、Trend、Comparison、Highlights）
- [ ] AI 文本有 `{{card:xxx}}` 标记时，卡片在标记位置插入
- [ ] AI 文本无标记时，使用默认插入策略（summary 第 1 段后、mid cards 中间、highlights 末段前）
- [ ] 重复标记只使用第一次，后续忽略
- [ ] 未知标记作为普通文本保留
- [ ] 标记对应的卡片不存在时不渲染该卡片，文本照常显示
- [ ] 旧的历史消息（无标记）能通过默认插入策略正常展示
- [ ] Sheet 支持 `.medium` 和 `.large` 两种高度
- [ ] Sheet dismiss 后 `selectedAnalysisMessage` 置 nil
- [ ] 财务和习惯摘要使用正确的字段（不使用不存在的字段）
- [ ] 没有引入第二套分析卡片数据模型
- [ ] Markdown 渲染失败时降级为纯文本，不崩溃
