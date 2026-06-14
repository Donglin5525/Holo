# Memory Gallery Life Constellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Memory Gallery insight tab's stacked AI cards with a Light/Dark "life constellation" overview, fold AI replay/deep analysis into explanation layers, keep health as a first-class signal, and soften milestone/highlight copy.

**Architecture:** Add a small presentation-model layer for constellation signals and gentle story snippets, then build focused SwiftUI components around those models. Keep existing data loading intact in `MemoryGalleryViewModel`; the first implementation maps current `MemoryInsight`, `DailySenseSnapshot`, `HoloRenderedAgentResult`, timeline highlights, and health availability into display-only models.

**Tech Stack:** Swift, SwiftUI, XCTest, existing Holo design tokens (`HoloSpacing`, `HoloRadius`, `Color.holo*`), current Core Data-backed `MemoryGalleryViewModel`.

---

## File Structure

- Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Models/MemoryConstellationModels.swift`
  - Owns display-only enums and structs for the constellation: module, status, health state, selected signal, story snippet.
- Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryLifeConstellationCard.swift`
  - Owns the Light/Dark constellation rendering and tap targets.
- Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryConstellationExplanationCard.swift`
  - Owns the selected-signal explanation card and secondary actions.
- Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryInsightDisclosureCard.swift`
  - Owns collapsible AI replay and deep analysis explanation sections.
- Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryStorySnippetCard.swift`
  - Owns the warmer "可回看的片段" row/card.
- Modify `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`
  - Add computed presentation properties and helper methods. Do not change fetching or persistence.
- Modify `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift`
  - Replace the insight-tab top stack with the constellation structure and rename the old featured section.
- Modify `Holo/Holo APP/Holo/Holo/Models/HighlightDetector.swift`
  - Soften spending highlight primary text at the source so both detail timeline and insight snippets stop using sharp percent copy.
- Test `Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift`
  - Unit tests for module ordering, health states, fallback main line, gentle finance wording.

## Task 1: Add Constellation Presentation Models

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Models/MemoryConstellationModels.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift`

- [ ] **Step 1: Write failing tests for module order and gentle finance copy**

Create `Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift`:

```swift
import XCTest
@testable import Holo

final class MemoryConstellationModelsTests: XCTestCase {

    func testModulesKeepHealthAsFifthPeerSignal() {
        XCTAssertEqual(
            MemoryConstellationModule.allCases,
            [.habit, .finance, .task, .thought, .health]
        )
        XCTAssertEqual(MemoryConstellationModule.health.displayName, "健康")
    }

    func testFinanceSnippetUsesGentleObservationCopy() {
        let snippet = MemoryStorySnippet.financeSpendingPeak()

        XCTAssertEqual(snippet.title, "这天的外出支出比较集中")
        XCTAssertEqual(snippet.subtitle, "具体金额和对比留在详情里看")
        XCTAssertFalse(snippet.title.contains("超过"))
        XCTAssertFalse(snippet.title.contains("%"))
        XCTAssertFalse(snippet.title.contains("异常"))
    }

    func testHealthSignalCanRepresentPendingAgentConnection() {
        let signal = MemoryConstellationSignal.health(state: .agentPending)

        XCTAssertEqual(signal.module, .health)
        XCTAssertEqual(signal.title, "健康")
        XCTAssertEqual(signal.summary, "健康证据接入中")
        XCTAssertTrue(signal.isDashed)
    }

    func testFallbackMainLineIsConservativeWhenDataIsSparse() {
        let summary = MemoryConstellationSummary.fallback(hasInsight: false)

        XCTAssertEqual(summary.title, "记录还不多")
        XCTAssertEqual(summary.body, "先从几个生活信号开始，等数据更多后 Holo 会帮你连成一张星图。")
    }
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: fail because `MemoryConstellationModule`, `MemoryStorySnippet`, `MemoryConstellationSignal`, and `MemoryConstellationSummary` do not exist yet.

- [ ] **Step 3: Add minimal presentation models**

Create `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Models/MemoryConstellationModels.swift`:

```swift
import Foundation
import SwiftUI

enum MemoryConstellationModule: String, CaseIterable, Identifiable, Equatable {
    case habit
    case finance
    case task
    case thought
    case health

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .habit: return "习惯"
        case .finance: return "财务"
        case .task: return "任务"
        case .thought: return "思考"
        case .health: return "健康"
        }
    }

    var iconName: String {
        switch self {
        case .habit: return "leaf.fill"
        case .finance: return "yensign.circle.fill"
        case .task: return "checkmark.circle.fill"
        case .thought: return "bubble.left.and.text.bubble.right.fill"
        case .health: return "heart.fill"
        }
    }
}

enum MemoryConstellationHealthState: Equatable {
    case unauthorized
    case agentPending
    case connected(summary: String)

    var displayText: String {
        switch self {
        case .unauthorized:
            return "等待健康数据"
        case .agentPending:
            return "健康证据接入中"
        case .connected(let summary):
            return summary
        }
    }
}

struct MemoryConstellationSummary: Equatable {
    let title: String
    let body: String

    static func fallback(hasInsight: Bool) -> MemoryConstellationSummary {
        if hasInsight {
            return MemoryConstellationSummary(
                title: "本期观察",
                body: "Holo 正在把这些生活信号整理成更清楚的星图。"
            )
        }
        return MemoryConstellationSummary(
            title: "记录还不多",
            body: "先从几个生活信号开始，等数据更多后 Holo 会帮你连成一张星图。"
        )
    }
}

struct MemoryConstellationSignal: Identifiable, Equatable {
    let module: MemoryConstellationModule
    let title: String
    let summary: String
    let detail: String
    let level: SignalLevel
    let isDashed: Bool

    var id: String { module.rawValue }

    static func health(state: MemoryConstellationHealthState) -> MemoryConstellationSignal {
        switch state {
        case .unauthorized:
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: state.displayText,
                detail: "授权后可把睡眠、步数、站立和运动恢复纳入生活星图。",
                level: .warning,
                isDashed: true
            )
        case .agentPending:
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: state.displayText,
                detail: "健康会用于解释睡眠、步数、站立和运动恢复；Agent Health 接入后这里会显示证据摘要。",
                level: .warning,
                isDashed: true
            )
        case .connected(let summary):
            return MemoryConstellationSignal(
                module: .health,
                title: "健康",
                summary: summary,
                detail: "健康证据已纳入本期观察，可在深度分析中查看来源。",
                level: .normal,
                isDashed: false
            )
        }
    }
}

struct MemoryStorySnippet: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let iconName: String
    let module: MemoryConstellationModule

    static func financeSpendingPeak(id: String = "finance-spending-peak") -> MemoryStorySnippet {
        MemoryStorySnippet(
            id: id,
            title: "这天的外出支出比较集中",
            subtitle: "具体金额和对比留在详情里看",
            iconName: "fork.knife",
            module: .finance
        )
    }
}
```

- [ ] **Step 4: Run the model tests**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Models/MemoryConstellationModels.swift" \
        "Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift"
git commit -m "feat(iOS): add memory constellation presentation models"
```

## Task 2: Map Existing Memory Gallery Data Into Constellation State

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift`

- [ ] **Step 1: Add failing tests for signal derivation helpers**

Append to `MemoryConstellationModelsTests`:

```swift
func testSignalFromDailySenseExpenseUsesFinanceModule() {
    let signal = MemoryConstellationSignal.from(
        dailySense: DailySenseSignal(dimension: .expense, level: .warning, text: "花费节奏有一个小高点")
    )

    XCTAssertEqual(signal?.module, .finance)
    XCTAssertEqual(signal?.summary, "花费节奏有一个小高点")
    XCTAssertEqual(signal?.level, .warning)
}

func testThoughtFallbackSignalKeepsThoughtAsPeerModule() {
    let signal = MemoryConstellationSignal.thoughtFallback(hasThoughts: true)

    XCTAssertEqual(signal.module, .thought)
    XCTAssertEqual(signal.summary, "有新的想法片段")
    XCTAssertFalse(signal.isDashed)
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: fail because `from(dailySense:)` and `thoughtFallback(hasThoughts:)` do not exist.

- [ ] **Step 3: Add mapping helpers to `MemoryConstellationModels.swift`**

Add below `MemoryConstellationSignal.health(state:)`:

```swift
static func from(dailySense signal: DailySenseSignal) -> MemoryConstellationSignal? {
    let module: MemoryConstellationModule
    switch signal.dimension {
    case .habit:
        module = .habit
    case .expense:
        module = .finance
    case .task:
        module = .task
    case .health:
        return .health(state: .connected(summary: signal.text))
    }

    return MemoryConstellationSignal(
        module: module,
        title: module.displayName,
        summary: signal.text,
        detail: signal.text,
        level: signal.level,
        isDashed: false
    )
}

static func thoughtFallback(hasThoughts: Bool) -> MemoryConstellationSignal {
    MemoryConstellationSignal(
        module: .thought,
        title: "思考",
        summary: hasThoughts ? "有新的想法片段" : "等待更多想法",
        detail: hasThoughts
            ? "近期的想法记录会成为生活星图里的一颗信号。"
            : "记录一些观点或感受后，Holo 会把它们纳入周期回放。",
        level: .normal,
        isDashed: !hasThoughts
    )
}
```

- [ ] **Step 4: Add computed properties to `MemoryGalleryViewModel`**

Add these computed properties near `selectedInsightDateRange`:

```swift
var constellationSummary: MemoryConstellationSummary {
    if let insight = currentInsight {
        return MemoryConstellationSummary(
            title: insight.title,
            body: insight.summary
        )
    }

    if let agentRenderedResult, !agentRenderedResult.summary.isEmpty {
        return MemoryConstellationSummary(
            title: agentRenderedResult.title,
            body: agentRenderedResult.summary
        )
    }

    return MemoryConstellationSummary.fallback(hasInsight: false)
}

var constellationSignals: [MemoryConstellationSignal] {
    let dailySignals = dailySenseSnapshot?.signals.compactMap {
        MemoryConstellationSignal.from(dailySense: $0)
    } ?? []
    var byModule = Dictionary(uniqueKeysWithValues: dailySignals.map { ($0.module, $0) })

    for module in MemoryConstellationModule.allCases where byModule[module] == nil {
        switch module {
        case .habit:
            byModule[module] = MemoryConstellationSignal(
                module: .habit,
                title: "习惯",
                summary: "等待更多习惯信号",
                detail: "继续记录后，Holo 会观察习惯节奏的恢复和断裂。",
                level: .normal,
                isDashed: true
            )
        case .finance:
            byModule[module] = MemoryConstellationSignal(
                module: .finance,
                title: "财务",
                summary: "等待更多财务信号",
                detail: "记账更多后，Holo 会观察外出日、预算节奏和集中花费。",
                level: .normal,
                isDashed: true
            )
        case .task:
            byModule[module] = MemoryConstellationSignal(
                module: .task,
                title: "任务",
                summary: "等待更多任务信号",
                detail: "任务完成和收尾节奏会逐步进入星图。",
                level: .normal,
                isDashed: true
            )
        case .thought:
            byModule[module] = MemoryConstellationSignal.thoughtFallback(
                hasThoughts: cachedItems.contains { $0.type == .thought }
            )
        case .health:
            byModule[module] = MemoryConstellationSignal.health(state: .agentPending)
        }
    }

    return MemoryConstellationModule.allCases.compactMap { byModule[$0] }
}
```

- [ ] **Step 5: Run model tests**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Models/MemoryConstellationModels.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift" \
        "Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift"
git commit -m "feat(iOS): map memory gallery data to constellation state"
```

## Task 3: Build Life Constellation SwiftUI Components

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryLifeConstellationCard.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryConstellationExplanationCard.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryInsightDisclosureCard.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryStorySnippetCard.swift`

- [ ] **Step 1: Create `MemoryLifeConstellationCard`**

Create `MemoryLifeConstellationCard.swift`:

```swift
import SwiftUI

struct MemoryLifeConstellationCard: View {
    let summary: MemoryConstellationSummary
    let signals: [MemoryConstellationSignal]
    @Binding var selectedModule: MemoryConstellationModule

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            header
            starMap
        }
        .padding(HoloSpacing.lg)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("生活星图")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                Text(summary.title)
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var starMap: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

            ZStack {
                constellationBackground

                ForEach(signals) { signal in
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: point(for: signal.module, in: size))
                    }
                    .stroke(lineColor(for: signal), style: StrokeStyle(lineWidth: 1.2, dash: signal.isDashed ? [4, 5] : []))

                    signalButton(signal, at: point(for: signal.module, in: size))
                }

                VStack(spacing: 4) {
                    Text("本期主线")
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Text(shortTitle(summary.title))
                        .font(.holoCaption)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                .frame(width: 104, height: 104)
                .background(centerBackground)
                .clipShape(Circle())
                .overlay(Circle().stroke(borderColor, lineWidth: 1))
                .position(center)
            }
        }
        .frame(height: 236)
    }

    private var constellationBackground: some View {
        RoundedRectangle(cornerRadius: HoloRadius.lg)
            .fill(
                colorScheme == .dark
                    ? LinearGradient(colors: [Color.black.opacity(0.55), Color.holoCardBackground], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color.holoGlassBackground, Color.holoCardBackground], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private func signalButton(_ signal: MemoryConstellationSignal, at point: CGPoint) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedModule = signal.module
            }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .strokeBorder(signalColor(signal), style: StrokeStyle(lineWidth: signal.isDashed ? 2 : 0, dash: signal.isDashed ? [4, 3] : []))
                    .background(Circle().fill(signal.isDashed ? Color.clear : signalColor(signal)))
                    .frame(width: selectedModule == signal.module ? 20 : 15, height: selectedModule == signal.module ? 20 : 15)
                Text(signal.title)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(selectedModule == signal.module ? selectedBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        .position(point)
        .accessibilityLabel("\(signal.title)，\(signal.summary)")
    }

    private func point(for module: MemoryConstellationModule, in size: CGSize) -> CGPoint {
        switch module {
        case .habit:
            return CGPoint(x: size.width * 0.24, y: size.height * 0.22)
        case .finance:
            return CGPoint(x: size.width * 0.78, y: size.height * 0.28)
        case .task:
            return CGPoint(x: size.width * 0.78, y: size.height * 0.78)
        case .thought:
            return CGPoint(x: size.width * 0.25, y: size.height * 0.78)
        case .health:
            return CGPoint(x: size.width * 0.14, y: size.height * 0.52)
        }
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 14 ? String(title.prefix(14)) : title
    }

    private func signalColor(_ signal: MemoryConstellationSignal) -> Color {
        switch signal.module {
        case .habit: return .holoSuccess
        case .finance: return .orange
        case .task: return .holoPurple
        case .thought: return .holoPrimary
        case .health: return .pink
        }
    }

    private func lineColor(for signal: MemoryConstellationSignal) -> Color {
        signalColor(signal).opacity(colorScheme == .dark ? 0.45 : 0.35)
    }

    private var selectedBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.62)
    }

    private var centerBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55)
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color.holoCardBackground : Color.holoGlassBackground
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.holoBorder.opacity(0.55)
    }
}
```

- [ ] **Step 2: Create `MemoryConstellationExplanationCard`**

Create `MemoryConstellationExplanationCard.swift`:

```swift
import SwiftUI

struct MemoryConstellationExplanationCard: View {
    let signal: MemoryConstellationSignal
    let onOpenHealth: () -> Void
    let onContinueInChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: signal.module.iconName)
                    .foregroundColor(.holoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(signal.title)
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.holoTextPrimary)
                    Text(signal.summary)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
            }

            Text(signal.detail)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HoloSpacing.sm) {
                if signal.module == .health {
                    Button("打开健康", action: onOpenHealth)
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                }
                Button("继续问 AI", action: onContinueInChat)
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
            }
            .padding(.top, HoloSpacing.xs)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 3: Create `MemoryInsightDisclosureCard`**

Create `MemoryInsightDisclosureCard.swift`:

```swift
import SwiftUI

struct MemoryInsightDisclosureCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    Image(systemName: icon)
                        .foregroundColor(.holoPrimary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.holoBody)
                            .fontWeight(.semibold)
                            .foregroundColor(.holoTextPrimary)
                        Text(subtitle)
                            .font(.holoTinyLabel)
                            .foregroundColor(.holoTextSecondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextPlaceholder)
                }
                .padding(HoloSpacing.md)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Divider().background(Color.holoBorder.opacity(0.4))
                    content()
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.bottom, HoloSpacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 4: Create `MemoryStorySnippetCard`**

Create `MemoryStorySnippetCard.swift`:

```swift
import SwiftUI

struct MemoryStorySnippetCard: View {
    let snippet: MemoryStorySnippet

    var body: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: snippet.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoPrimary)
                .frame(width: 28, height: 28)
                .background(Color.holoPrimary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))

            VStack(alignment: .leading, spacing: 4) {
                Text(snippet.title)
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = snippet.subtitle {
                    Text(subtitle)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(HoloSpacing.sm)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.35), lineWidth: 1)
        )
    }
}
```

- [ ] **Step 5: Build to catch SwiftUI compile errors**

Run:

```bash
xcodebuild build \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds. If it fails due to unavailable custom colors, replace `.holoPurple` or `.pink` with existing Holo colors used elsewhere in the repo.

- [ ] **Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryLifeConstellationCard.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryConstellationExplanationCard.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryInsightDisclosureCard.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/MemoryStorySnippetCard.swift"
git commit -m "feat(iOS): add memory life constellation components"
```

## Task 4: Wire Constellation Into Memory Gallery Insight Tab

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift`

- [ ] **Step 1: Add selected constellation state and health navigation hook**

In `MemoryGalleryView.swift`, add state near `selectedTab`:

```swift
@State private var selectedConstellationModule: MemoryConstellationModule = .habit
@State private var showHealthFromConstellation = false
```

Add a full-screen cover near the existing sheets:

```swift
.fullScreenCover(isPresented: $showHealthFromConstellation) {
    NavigationStack {
        HealthView()
    }
}
```

- [ ] **Step 2: Replace top of `insightTab` with constellation**

Inside the `VStack(spacing: HoloSpacing.lg)` in `insightTab`, replace the standalone Daily Sense + Agent card + direct `MemoryInsightHeroCard` ordering with:

```swift
MemoryLifeConstellationCard(
    summary: viewModel.constellationSummary,
    signals: viewModel.constellationSignals,
    selectedModule: $selectedConstellationModule
)

if let selectedSignal = viewModel.constellationSignals.first(where: { $0.module == selectedConstellationModule }) {
    MemoryConstellationExplanationCard(
        signal: selectedSignal,
        onOpenHealth: {
            showHealthFromConstellation = true
        },
        onContinueInChat: {
            if let prompt = viewModel.buildContinueInChatPrompt() {
                onNavigateToChat?(prompt)
            }
        }
    )
}

MemoryInsightDisclosureCard(
    title: "AI 回放",
    subtitle: replayDisclosureSubtitle,
    icon: "sparkles"
) {
    MemoryInsightHeroCard(
        state: viewModel.insightGenerationState,
        selectedPeriod: viewModel.selectedInsightPeriod,
        insight: viewModel.currentInsight,
        weeklyIsFallback: viewModel.weeklyIsFallback,
        monthlyIsFallback: viewModel.monthlyIsFallback,
        customStartDate: $viewModel.customInsightStartDate,
        customEndDate: $viewModel.customInsightEndDate,
        fallbackTitle: viewModel.fallbackReplayTitle,
        fallbackSummary: viewModel.fallbackReplaySummary,
        onPeriodChange: { period in
            Task { await viewModel.switchInsightPeriod(to: period) }
        },
        onCustomRangeChange: { start, end in
            Task { await viewModel.updateCustomInsightRange(start: start, end: end) }
        },
        onGenerate: {
            Task { await viewModel.generateCurrentInsight() }
        },
        onRefresh: {
            Task { await viewModel.refreshInsight(force: true) }
        },
        onContinueInChat: {
            if let prompt = viewModel.buildContinueInChatPrompt() {
                onNavigateToChat?(prompt)
            }
        },
        onGoToAISettings: {
            #if DEBUG
            showAISettings = true
            #endif
        }
    )
}

MemoryInsightDisclosureCard(
    title: "深度分析",
    subtitle: viewModel.agentRenderedResult == nil ? "暂无证据化分析" : "查看证据和结论",
    icon: "checkmark.seal"
) {
    if let agentResult = viewModel.agentRenderedResult {
        HoloAgentResultCard(result: agentResult)
    } else {
        Text("本周期暂时没有可展示的证据化分析。健康证据接入后，也会在这里显示状态。")
            .font(.holoCaption)
            .foregroundColor(.holoTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

featuredStoriesSection
```

- [ ] **Step 3: Add `replayDisclosureSubtitle` helper**

In `MemoryGalleryView.swift`, add:

```swift
private var replayDisclosureSubtitle: String {
    switch viewModel.insightGenerationState {
    case .idle:
        return "还没有生成本周期回放"
    case .notConfigured:
        return "AI 服务暂时不可用"
    case .generating:
        return "正在整理生活星图"
    case .ready:
        return "展开周期故事"
    case .stale:
        return "有新记录，可刷新"
    case .failed:
        return "生成失败，可重试"
    }
}
```

- [ ] **Step 4: Build**

Run:

```bash
xcodebuild build \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryViewModel.swift"
git commit -m "feat(iOS): wire life constellation into memory gallery"
```

## Task 5: Soften Highlights and Rename Featured Stories

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/HighlightDetector.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/HighlightNode.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift`

- [ ] **Step 1: Add failing test for spending highlight text policy**

Append to `MemoryConstellationModelsTests`:

```swift
func testGentleFinanceTextPolicyRejectsSharpCopy() {
    let sharpPhrases = ["超过", "%", "异常", "太多"]

    let title = MemoryStorySnippet.financeSpendingPeak().title
    for phrase in sharpPhrases {
        XCTAssertFalse(title.contains(phrase))
    }
}
```

- [ ] **Step 2: Update spending anomaly copy at the source**

In `HighlightDetector.detectSpendingAnomalies`, replace:

```swift
let percentage = Int((ratio - 1.0) * 100)
let highlight = HighlightData(
    category: .spendingAnomaly,
    title: "今日消费比日均高 \(percentage)%",
    subtitle: String(format: "¥%.0f vs 日均¥%.0f", dayExpense, dailyAverage),
    icon: "exclamationmark.triangle.fill",
    sourceModule: .transaction
)
```

with:

```swift
let highlight = HighlightData(
    category: .spendingAnomaly,
    title: "这天的外出支出比较集中",
    subtitle: "具体金额和对比留在详情里看",
    icon: "fork.knife",
    sourceModule: .transaction
)
```

- [ ] **Step 3: Rename section heading in `MemoryGalleryView`**

In `featuredStoriesSection`, replace:

```swift
sectionHeading(title: "里程碑与高光", icon: "flag.fill")
```

with:

```swift
sectionHeading(title: "可回看的片段", icon: "sparkles")
```

- [ ] **Step 4: Soften `HighlightNode` negative styling**

In `HighlightNode`, change negative colors from error red to a warm primary/orange treatment:

```swift
private var textColor: Color {
    switch data.tone {
    case .positive: return .holoPrimary
    case .negative: return .orange
    case .achievement: return .holoPrimary
    }
}

private var borderColor: Color {
    switch data.tone {
    case .positive: return Color.holoPrimary.opacity(0.2)
    case .negative: return Color.orange.opacity(0.22)
    case .achievement: return Color.holoSuccess.opacity(0.2)
    }
}

private var backgroundColor: Color {
    switch data.tone {
    case .positive: return Color.holoPrimary.opacity(0.06)
    case .negative: return Color.orange.opacity(0.07)
    case .achievement: return Color.holoSuccess.opacity(0.06)
    }
}
```

- [ ] **Step 5: Run focused tests and build**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: pass.

Then run:

```bash
xcodebuild build \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add "Holo/Holo APP/Holo/Holo/Models/HighlightDetector.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift" \
        "Holo/Holo APP/Holo/Holo/Views/MemoryGallery/Components/HighlightNode.swift" \
        "Holo/Holo APP/Holo/HoloTests/Views/MemoryGallery/MemoryConstellationModelsTests.swift"
git commit -m "feat(iOS): soften memory gallery story snippets"
```

## Task 6: Final Verification and Changelog

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add changelog entry**

Add near the top of `CHANGELOG.md`:

```markdown
## [2026-06-15] 记忆长廊洞察区生活星图改版

### 新增
- 记忆长廊洞察 Tab 改为「生活星图」首屏：习惯、财务、任务、思考、健康五个模块作为同级信号星展示
- AI 回放与 Agent 深度分析改为折叠解释层，避免深度分析卡片突兀占据首屏
- 健康作为第五颗星预留入口，支持未授权 / 接入中 / 已接入状态承接

### 优化
- 「里程碑与高光」改为「可回看的片段」
- 财务高光文案改为温和的节奏观察，不再用「消费超过 XX%」作为主文案
```

- [ ] **Step 2: Run full focused verification**

Run:

```bash
xcodebuild test \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoloTests/MemoryConstellationModelsTests
```

Expected: pass.

Run:

```bash
xcodebuild build \
  -project "Holo/Holo APP/Holo/Holo.xcodeproj" \
  -scheme Holo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: build succeeds.

- [ ] **Step 3: Manual screenshot verification**

Open the app in Simulator and inspect:

- Memory Gallery insight tab in Light Mode: paper constellation, no text overlap.
- Memory Gallery insight tab in Dark Mode: night constellation, no text overlap.
- Tap each of the five stars: explanation card changes without opening a sheet.
- Health star: shows pending/unauthorized copy and can open `HealthView`.
- AI 回放 and 深度分析: both default collapsed.
- 可回看的片段: no sharp finance percent copy in primary text.

- [ ] **Step 4: Commit final docs**

```bash
git add CHANGELOG.md
git commit -m "docs: update changelog for memory constellation"
```

## Self-Review

- Spec coverage:
  - Life constellation first screen: Tasks 1-4.
  - Light/Dark visual language: Task 3 component uses color scheme-specific background and styling; Task 6 requires manual screenshots.
  - Health as fifth peer signal: Tasks 1-4.
  - AI replay/deep analysis collapsed: Task 4.
  - Gentle milestone/highlight copy: Task 5.
  - Changelog: Task 6.
- Placeholder scan:
  - No unresolved placeholder markers remain. The only double-question-mark token in the plan is Swift nil-coalescing syntax inside concrete code.
- Type consistency:
  - `MemoryConstellationModule`, `MemoryConstellationSignal`, `MemoryConstellationSummary`, and `MemoryStorySnippet` are defined before use.
  - `MemoryGalleryViewModel.constellationSummary` and `constellationSignals` are consumed by `MemoryGalleryView`.
  - `MemoryInsightDisclosureCard` is generic over content and can host both the old `MemoryInsightHeroCard` and `HoloAgentResultCard`.
