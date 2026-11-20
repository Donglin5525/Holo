import SwiftUI

// 「一个发现」v4 洞察卡（2026-11-20 方案 03-I6，结构按方案自上而下）：
// 领域 chip（跨域显示「习惯 × 任务」）→ headline → insight 正文 →
// 「依据」折叠区（默认收起，1~3 行 evidenceLines，行前带领域 SF Symbol）→
// prompt（弱化样式）→ 底部三按钮（对，记住 / 不太准确 / 先放一放）。
// 版式沿用 v3 今日卡调型（holoSurface / holoTitle2 / HoloActionStyle）。
struct DiscoveryInsightCardView: View {
    let card: DiscoveryTopicStore.QueuedCard
    @Binding var showsEvidence: Bool
    let isDisabled: Bool
    let onConfirm: () -> Void
    let onInaccurate: () -> Void
    let onDefer: () -> Void

    private static let domainTitles: [String: String] = [
        "finance": "财务", "health": "健康", "habit": "习惯",
        "thought": "想法", "task": "任务", "goal": "目标", "profile": "画像",
        "conversation": "对话",
    ]

    private static let domainSymbols: [String: String] = [
        // SF Symbol 存在性已核对（notebook 教训：不存在的符号渲染空白）。
        "finance": "creditcard.circle",
        "health": "heart.text.square",
        "habit": "checkmark.seal",
        "thought": "lightbulb",
        "task": "checklist",
        "goal": "target",
        "profile": "person.crop.circle",
        "conversation": "bubble.left",
    ]

    private var domains: [String] {
        (card.sourceDomains ?? []).filter { Self.domainTitles[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            CardBadge(text: "AI 洞察", color: .holoToolTextSecondary)
            if !domains.isEmpty {
                HStack(spacing: HoloSpacing.xs) {
                    ForEach(domains, id: \.self) { domain in
                        Text(Self.domainTitles[domain] ?? domain)
                            .holoText(.metadata)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .padding(.horizontal, HoloSpacing.sm)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.holoToolTextSecondary.opacity(0.12))
                            )
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(domains.map { Self.domainTitles[$0] ?? $0 }.joined(separator: " × ")))
            }
            Text(card.title)
                .font(.holoTitle2)
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(HoloSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.body)
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .lineSpacing(HoloSpacing.xs)
                .fixedSize(horizontal: false, vertical: true)

            evidenceSection

            if let prompt = card.prompt, !prompt.isEmpty {
                Text(prompt)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            DiscoveryDecisionControls(
                elevated: true,
                isDisabled: isDisabled,
                idPrefix: "chat.discovery.insight",
                onConfirm: onConfirm,
                onInaccurate: onInaccurate,
                onDefer: onDefer
            )
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.insight.card")
    }

    // MARK: - 依据折叠区（默认收起；行前带领域图标）

    @ViewBuilder
    private var evidenceSection: some View {
        let lines = card.evidenceLines ?? []
        if !lines.isEmpty {
            Button {
                withAnimation(HoloAnimation.replayReveal) { showsEvidence.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(showsEvidence ? "收起依据" : "查看依据")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: showsEvidence ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Color.holoToolTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityIdentifier("chat.discovery.insight.evidenceToggle")

            if showsEvidence {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: HoloSpacing.sm) {
                            Image(systemName: Self.domainSymbols[card.evidenceDomains?.safe(at: index) ?? ""] ?? "lightbulb")
                                .font(.footnote)
                                .foregroundStyle(Color.holoToolTextSecondary)
                            Text(line)
                                .holoText(.supporting)
                                .foregroundStyle(Color.holoToolTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private extension Array {
    /// 越界安全取值（evidenceDomains 与 evidenceLines 平行数组，行数裁剪后可能更短）。
    func safe(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 预算墙卡（2026-11-21 东林拍板：免费 1 条/周、Plus 5 条/周）

/// 「今日一条」空位上的升级引导卡：只替换空态，不打断「等你确认」列表。
struct DiscoveryQuotaWallCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.xs) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(Color.holoToolTextSecondary)
                Text("本周的一条发现已看完")
                    .holoText(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            Text("Holo Plus 每周可以看更多条你自己的记录里长出来的洞察。")
                .holoText(.body)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: openPlus) {
                Text("了解 Holo Plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(HoloActionStyle(role: .secondary))
            .accessibilityIdentifier("chat.discovery.insight.quotaWall.plus")
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.insight.quotaWall")
    }

    private func openPlus() {
        HoloProductAnalytics.shared.track(.discoveryTodayAction, ["action": "quota_wall_plus_tap"])
        HoloPlusActionCoordinator.shared.requirePlus(context: .discoveryInsightWeekly)
    }
}
