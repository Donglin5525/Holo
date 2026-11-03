//
//  DiscoveryEvidenceView.swift
//  Holo
//
//  「一个发现」依据列表（01 §2 第 4 条）：按真实独立来源（sourceRef）分组展示
//  展示引用；可跳转来源带「打开原记录」；sourceRef 为空的聚合事实不提供假箭头，
//  以覆盖范围说明（coverageNote）提供可核对的计算范围。
//
//  协议缺口（交付报告已列，主会话补协议后接线）：
//  ① 来源的真实日期（发生时间）不在 DiscoveryFindingPresentation 中——行内日期位留待扩展；
//  ② 支持/反例角色不在 Citation 中（发布 payload 的 citations 全部为支持依据，
//     反例边界由正文承担，hasCounterEvidenceNote 仅作提示）——「限制」标签待角色字段。
//

import SwiftUI

/// 单个独立来源的分组：同一 sourceRef 的多条引用归为一组（“单个来源可有多片段”）。
struct DiscoveryEvidenceSourceGroup: Identifiable, Equatable {
    /// 组标识：sourceRef；聚合事实（sourceRef 为 nil）用 evidenceID
    let id: String
    let sourceRef: String?
    /// canonical 前缀（"thought:" 等）解析出的来源类型；解析不出为 nil
    let kind: DiscoverySourceKind?
    let quotes: [String]
}

struct DiscoveryEvidenceView: View {

    let finding: DiscoveryFindingPresentation
    /// 打开真实原记录（sourceRef）；真实跳转由主会话接路由
    let onOpenSource: (String) -> Void

    /// 按来源分组的展示数据（与渲染解耦，供详情页统计 N）
    static func sourceGroups(in finding: DiscoveryFindingPresentation) -> [DiscoveryEvidenceSourceGroup] {
        var order: [String] = []
        var buckets: [String: DiscoveryEvidenceSourceGroup] = [:]
        for citation in finding.citations {
            let key = citation.sourceRef ?? citation.evidenceID
            let quote = finding.displayQuotes[citation.evidenceID] ?? citation.quote
            if let existing = buckets[key] {
                buckets[key] = DiscoveryEvidenceSourceGroup(
                    id: existing.id, sourceRef: existing.sourceRef,
                    kind: existing.kind, quotes: existing.quotes + [quote]
                )
            } else {
                order.append(key)
                buckets[key] = DiscoveryEvidenceSourceGroup(
                    id: key,
                    sourceRef: citation.sourceRef,
                    kind: Self.kind(of: citation.sourceRef),
                    quotes: [quote]
                )
            }
        }
        return order.compactMap { buckets[$0] }
    }

    /// 真实独立来源数（N）：有 sourceRef 的组数；聚合事实不是记录，不计入
    static func independentRecordSourceCount(in finding: DiscoveryFindingPresentation) -> Int {
        sourceGroups(in: finding).filter { $0.sourceRef != nil }.count
    }

    /// sourceRef 是 canonical 形如 "thought:<uuid>"（FactAtom.SourceRef.canonical），
    /// 前缀即来源类型；解析不出不猜测
    private static func kind(of sourceRef: String?) -> DiscoverySourceKind? {
        guard let sourceRef, let separator = sourceRef.firstIndex(of: ":") else { return nil }
        return DiscoverySourceKind(rawValue: String(sourceRef[..<separator]))
    }

    var body: some View {
        let groups = Self.sourceGroups(in: finding)

        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                sourceCard(group, ordinal: index + 1)
            }

            // 反例边界提示：正文已体现边界（发布门禁保证），这里只做存在性提示不藏折叠
            if finding.hasCounterEvidenceNote {
                Label {
                    Text("存在改变这条解释的相反记录，边界已写进上方解释。")
                        .holoText(.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.holoToolWarning)
                .accessibilityIdentifier("chat.discovery.evidence.counterNote")
            }

            // 覆盖范围说明：聚合事实的可核对计算范围 + 召回覆盖
            coverageCard
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.discovery.evidence.list")
    }

    // MARK: - 来源卡

    private func sourceCard(_ group: DiscoveryEvidenceSourceGroup, ordinal: Int) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: iconName(for: group.kind))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.holoPrimary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.holoPrimary.opacity(0.12)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(typeName(for: group.kind))
                        .holoText(.supporting)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.holoToolText)
                    // 协议缺口①：来源真实日期不在 payload，扩展后在此展示
                    if group.quotes.count > 1 {
                        Text("\(group.quotes.count) 段片段")
                            .holoText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("chat.discovery.evidence.source.\(ordinal)")

            ForEach(Array(group.quotes.enumerated()), id: \.offset) { quoteIndex, quote in
                Text(quote)
                    .holoText(.supporting)
                    .foregroundStyle(Color.holoToolText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.sm, style: .continuous)
                            .fill(Color.holoToolInset)
                    )
                    .accessibilityIdentifier("chat.discovery.evidence.quote.\(ordinal).\(quoteIndex + 1)")
            }

            if let sourceRef = group.sourceRef {
                Button {
                    onOpenSource(sourceRef)
                } label: {
                    Label("打开原记录", systemImage: "arrow.up.right")
                        .holoText(.metadata)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.holoToolAction)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 32)
                .accessibilityIdentifier("chat.discovery.evidence.openSource.\(ordinal)")
            } else {
                // 无法跳转的聚合事实：给可核对的范围，不做无响应箭头
                Label("由程序按下方范围计算，无单独原记录可打开", systemImage: "function")
                    .holoText(.metadata)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .strokeBorder(Color.holoToolBorder, lineWidth: 0.5)
        }
    }

    // MARK: - 覆盖范围卡

    private var coverageCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Label {
                Text("覆盖范围")
                    .holoText(.metadata)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.holoToolTextSecondary)
            } icon: {
                Image(systemName: "scope")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.holoToolTextSecondary)
            }
            Text(finding.coverageNote)
                .holoText(.supporting)
                .foregroundStyle(Color.holoToolText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoToolInset.opacity(0.5))
        )
        .accessibilityIdentifier("chat.discovery.evidence.coverage")
    }

    // MARK: - 类型名与图标

    private func typeName(for kind: DiscoverySourceKind?) -> String {
        switch kind {
        case .thought: return "想法"
        case .task: return "任务"
        case .habitEvent: return "习惯打卡"
        case .computedFact: return "汇总计算"
        case nil: return "记录"
        }
    }

    private func iconName(for kind: DiscoverySourceKind?) -> String {
        switch kind {
        case .thought: return "lightbulb"
        case .task: return "checklist"
        case .habitEvent: return "flame"
        case .computedFact: return "function"
        case nil: return "doc.text"
        }
    }
}

// #Preview 已临时禁用（Xcode 26.2 隔离协议混淆崩溃规避，恢复见实施进度.md）

/// 预览样例数据（供 EvidenceView / DetailSheet 的 #Preview 与走查脚本复用）
enum DiscoveryServicePreviewSamples {
    static let finding = DiscoveryFindingPresentation(
        findingID: "finding-preview",
        title: "这两次重新开始，你都把第一步变轻了。",
        body: [
            "恢复运动时，你先出门走了十分钟；重新开始阅读时，你放下了每天读完一章的要求。",
            "这两段记录有一个相似之处：先允许自己做少一点，再尝试继续。它还不足以说明，这种方式一直对你有效。"
        ],
        citations: [
            DiscoveryPublishedPayload.Citation(evidenceID: "E01", quote: "停了一阵，今天先出去走十分钟。跑不跑都行。", sourceRef: "thought:preview-1001"),
            DiscoveryPublishedPayload.Citation(evidenceID: "E02", quote: "不要求一口气读一章了，今晚先翻两页。", sourceRef: "thought:preview-1002"),
            DiscoveryPublishedPayload.Citation(evidenceID: "E03", quote: "近 30 天习惯完成率 62%。", sourceRef: nil)
        ],
        displayQuotes: [
            "E01": "停了一阵，今天先出去走十分钟。跑不跑都行。",
            "E02": "不要求一口气读一章了，今晚先翻两页。",
            "E03": "近 30 天习惯完成率 62%。"
        ],
        coverageNote: "覆盖 9 月 28 日至 10 月 16 日的想法与习惯打卡，共匹配 41 条、采用 6 条；未包含健康与财务记录。",
        timeRangeText: "9 月 28 日 – 10 月 16 日",
        publishedAt: Date().addingTimeInterval(-3600 * 20),
        expiresAt: Date().addingTimeInterval(3600 * 52),
        viewed: false,
        hasCounterEvidenceNote: false
    )
}
