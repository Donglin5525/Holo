import SwiftUI

// 往期发现（2026-11-21 Plus 分层 I7，文案 C80~C84）。免费可看。
struct DiscoveryInsightArchiveView: View {
    let entries: [DiscoveryInsightArchive.Entry]
    let onClose: () -> Void

    var body: some View {
        HoloSheetScaffold(title: "往期发现", onClose: onClose) {              // C80
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text("你看过的发现都会留在这里")                            // C81
                        .holoText(.supporting)
                        .foregroundStyle(Color.holoToolTextSecondary)
                    if entries.isEmpty {
                        Text("还没有看过的发现")                               // C84
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

/// 分组（C82 标题）+ 条目卡（C83：角标 + 标题 + 正文 + 领域 chip + 右下角日期）。
private struct DiscoveryArchiveGroup: View {
    let title: String
    let entries: [DiscoveryInsightArchive.Entry]

    /// 右下角日期（C83）：M 月 d 日。
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title)                                                      // C82
                .holoText(.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, HoloSpacing.sm)
            ForEach(entries) { entry in
                entryCard(entry)
            }
        }
    }

    private func entryCard(_ entry: DiscoveryInsightArchive.Entry) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            CardBadge(text: "Holo 看出来的一件事", color: .holoToolTextSecondary)   // C04 同款角标
            Text(entry.title)
                .font(.holoTitle3)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.body)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HoloSpacing.xs) {
                ForEach(entry.sourceDomains.filter { DiscoveryInsightCardView.domainTitles[$0] != nil }, id: \.self) { domain in
                    Text(DiscoveryInsightCardView.domainTitles[domain] ?? domain)
                        .holoText(.metadata)
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, HoloSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.holoToolTextSecondary.opacity(0.12)))
                }
                Spacer()
                Text(Self.dayFormatter.string(from: entry.consumedAt))
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoSurface()
        .accessibilityElement(children: .contain)
    }
}
