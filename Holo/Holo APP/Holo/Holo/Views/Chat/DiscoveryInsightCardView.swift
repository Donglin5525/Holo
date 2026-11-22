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

    // 2026-11-21 Plus 分层 I6：去掉 private，撞墙卡 / 往期页复用领域图标与名称。
    static let domainTitles: [String: String] = [
        "finance": "财务", "health": "健康", "habit": "习惯",
        "thought": "想法", "task": "任务", "goal": "目标", "profile": "画像",
        "conversation": "对话",
    ]

    static let domainSymbols: [String: String] = [
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
            CardBadge(text: "Holo 看出来的一件事", color: .holoToolTextSecondary)   // C04（2026-11-21 Plus 分层 I6）
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
                    Text(showsEvidence ? "收起" : "Holo 是怎么看出来的")   // C05b / C05a（2026-11-21 Plus 分层 I6）
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

// MARK: - 撞墙卡 / Holo 还注意到的事（2026-11-21 Plus 分层 I6，文案 C20~C50）

/// 撞墙卡应显示哪种状态；由评审页 wallState 计算（I8 接入）。
enum DiscoveryWallState: Equatable {
    /// A / A0：免费撞墙（clues 为空即 A0）
    case freeWalled(clues: [DiscoveryTeaserClue], resetText: String)
    /// B：Plus 本周用完
    case plusExhausted(limit: Int, resetText: String)
    /// C：Plus 可点名
    case plusPickable(clues: [DiscoveryTeaserClue], remaining: Int, pickingId: String?)
    /// D：本机 Plus、后端仍按免费判（会员状态同步延迟）
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

private extension DiscoveryQuotaWallCard {

    /// 状态 A / A0：免费撞墙（有预告问题走 A，没有走 A0）。
    @ViewBuilder
    func freeWalled(clues: [DiscoveryTeaserClue], resetText: String) -> some View {
        HStack {
            Text("这周的发现你已经看过了")                                   // C20
                .holoText(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolTextSecondary)
            Spacer()
            plusCoinEmblem(size: 24)   // 2026-11-22 东林拍板：换会员中心同款深黑底样式
        }
        if clues.isEmpty {
            titleText("这周的发现你已经看过了")
            bodyText("开通 Plus，每周最多 \(DiscoveryPlusCopy.plusWeeklyLimit) 件。")
        } else {
            titleText("Holo 还注意到 \(clues.count) 件事")                    // C21（2026-11-22 精简）
            ForEach(clues) { clue in
                clueRow(clue, trailing: EmptyView())                        // C22
            }
        }
        Button(action: onLearnPlus) {
            Text("让 Holo 帮我看看")                                        // C24
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(HoloPlusTheme.ctaGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.discovery.insight.quotaWall.plus")
        Text("\(resetText)会有下一件")                                       // C25（2026-11-22 精简）
            .holoText(.metadata)
            .foregroundStyle(Color.holoToolTextSecondary)
            .frame(maxWidth: .infinity)
    }

    /// 会员中心同款深黑底金币徽章（2026-11-22 东林拍板替换透底金徽章）。
    /// 底用 darkGradient（会员卡同材质深黑渐变）——首版用的半透明灰底被东林判「不够黑」。
    func plusCoinEmblem(size: CGFloat) -> some View {
        HoloPlusEmblem(size: size, tier: .plus)
            .background(Circle().fill(HoloPlusTheme.darkGradient))
            .overlay(Circle().strokeBorder(HoloPlusTheme.strokeColor.opacity(0.6), lineWidth: 1))
    }

    /// 问题行：领域图标 + 文本（+ 尾部操作）。
    func clueRow<Trailing: View>(_ clue: DiscoveryTeaserClue, trailing: Trailing) -> some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            Image(systemName: DiscoveryInsightCardView.domainSymbols[clue.domains.first ?? ""] ?? "lightbulb")
                .font(.footnote)
                .foregroundStyle(Color.holoToolTextSecondary)
            Text(clue.text)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, HoloSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// 点名按钮：进行中显示「正在看…」，其余可点。
    @ViewBuilder
    func pickButton(_ clue: DiscoveryTeaserClue, pickingId: String?) -> some View {
        if pickingId == clue.id {
            Text("正在看…")                                                 // C43
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.trailing, HoloSpacing.sm)   // 2026-11-22 走查挂账：右缘与按钮留白对齐
        } else {
            Button("帮我看") { onPick(clue) }                               // C42
                .buttonStyle(HoloActionStyle(role: .secondary))
                .disabled(pickingId != nil)
                .accessibilityIdentifier("chat.discovery.insight.pick")
        }
    }

    func titleText(_ text: String) -> some View {
        Text(text)
            .holoText(.body)
            .fontWeight(.semibold)
            .foregroundStyle(Color.holoToolText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func bodyText(_ text: String) -> some View {
        Text(text)
            .holoText(.supporting)
            .foregroundStyle(Color.holoToolTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
