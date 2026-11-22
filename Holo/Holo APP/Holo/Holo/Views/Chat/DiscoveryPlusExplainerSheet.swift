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

private extension DiscoveryPlusExplainerSheet {

    /// C60 / C61
    var header: some View {
        VStack(alignment: .center, spacing: HoloSpacing.md) {
            HoloPlusEmblem(size: 56)                                         // C60
            Text("每周 1 件不够看？\n让 Holo 多帮你看看")                       // C61
                .font(.holoTitle2)
                .foregroundStyle(Color.holoToolText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// C62 / C63：这周 Holo 告诉过你什么（有往期才显示整块）。
    func recapBlock(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("这周 Holo 告诉过你")                                        // C62
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
            Text("「\(title)」")                                              // C63
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))
    }

    /// C64 / C65：免费版与 Plus 两栏对比（Plus 栏金色描边）。
    var comparison: some View {
        HStack(alignment: .top, spacing: HoloSpacing.sm) {
            planColumn(
                title: "免费版",                                              // C64
                headline: "每周 1 件",
                lines: ["Holo 每周挑一件最值得说的事告诉你"],
                highlighted: false
            )
            planColumn(
                title: "Plus",                                               // C65
                headline: "每周最多 \(DiscoveryPlusCopy.plusWeeklyLimit) 件",
                lines: [
                    "Holo 几乎每天都帮你看，有值得说的就告诉你",
                    "注意到的事可以点一下，让 Holo 先帮你看",
                ],
                highlighted: true
            )
        }
    }

    func planColumn(title: String, headline: String, lines: [String], highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title)
                .holoText(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolTextSecondary)
            Text(headline)
                .holoText(.body)
                .fontWeight(.bold)
                .foregroundStyle(highlighted ? HoloPlusTheme.plusValueColor : Color.holoToolText)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
            .fill(highlighted ? HoloPlusTheme.plusColumnTint : Color.holoToolInset))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .strokeBorder(HoloPlusTheme.strokeColor, lineWidth: 1)
            }
        }
    }

    /// C66 / C67 / C68：说清楚两件事。
    var clarifications: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("说清楚两件事")                                              // C66
                .holoText(.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolText)
            Text("· 没有值得说的，Holo 就不说，不会为了凑数硬编。所以有的周可能不到 \(DiscoveryPlusCopy.plusWeeklyLimit) 件。")   // C67
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("· Holo 记住的关于你的事、往期发现，免费版和 Plus 一样都能用。")          // C68
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous).fill(Color.holoToolInset))
    }

    var actions: some View {
        VStack(spacing: HoloSpacing.sm) {
            Button(action: onUpgrade) {
                Text(monthlyPrice.map { "开通 Plus · \($0) / 月" } ?? "开通 Holo Plus")   // C69 / C70
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(HoloPlusTheme.ctaGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.discovery.plusExplainer.upgrade")
            Text("随时可以在系统设置里取消")                                    // C71
                .holoText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
            Button("先不用，等下周的", action: onClose)                         // C72
                .buttonStyle(HoloActionStyle(role: .secondary))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat.discovery.plusExplainer.later")
        }
    }
}
