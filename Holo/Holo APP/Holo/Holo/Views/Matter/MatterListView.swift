//
//  MatterListView.swift
//  Holo
//
//  全部进行中的事（方案 §13.3）：正在进行 / 已完成 / 已归档 三组。
//  列表不展示 candidate；dismissed 不出现。右上「+」打开 Holo 对话（带引导语，不预写用户消息）。
//

import SwiftUI

struct MatterListView: View {

    /// 列表内点进详情（首版由调用方接管，nil 时行内不导航）。
    var onOpenMatter: ((UUID) -> Void)? = nil
    /// 「+」出口：打开 HoloAI 并给引导问题（不预写为用户消息）。
    var onAddTapped: (() -> Void)? = nil

    @ObservedObject private var repository = HoloMatterRepository.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pushedMatterID: UUID?

    public var body: some View {
        NavigationStack {
            content
                .background(Color.holoBackground.ignoresSafeArea())
                .navigationTitle(String(localized: "进行中的事"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onAddTapped?()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "添加进行中的事"))
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(String(localized: "完成")) { dismiss() }
                    }
                }
                .navigationDestination(item: $pushedMatterID) { id in
                    MatterDetailView(matterID: id)
                }
        }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                groupSection(
                    title: String(localized: "正在进行"),
                    matters: repository.matters(lifecycles: [.active])
                )
                groupSection(
                    title: String(localized: "已完成"),
                    matters: repository.matters(lifecycles: [.completed])
                )
                archiveSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func groupSection(title: String, matters: [HoloMatter]) -> some View {
        if !matters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(matters, id: \.id) { matter in
                    row(matter)
                }
            }
        }
    }

    /// 已归档：数量为 0 时显示轻空态（不给首页制造空模块，列表页交代清楚即可）。
    @ViewBuilder
    private var archiveSection: some View {
        let archived = repository.matters(lifecycles: [.archived])
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "已归档"))
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            if archived.isEmpty {
                Text(String(localized: "还没有归档的事"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: HoloRadius.md).fill(Color(.secondarySystemGroupedBackground)))
            } else {
                ForEach(archived, id: \.id) { matter in
                    row(matter)
                }
            }
        }
    }

    private func row(_ matter: HoloMatter) -> some View {
        Button {
            pushedMatterID = matter.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(matter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    lifecycleBadge(matter)
                }
                subtitleLine(matter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.lg)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
            )
        }
        .buttonStyle(.plain)
        .opacity(matter.lifecycle == .completed || matter.lifecycle == .archived ? 0.65 : 1)
    }

    @ViewBuilder
    private func subtitleLine(_ matter: HoloMatter) -> some View {
        let loops = repository.openLoops(matterID: matter.id)
        let activeCount = loops.filter { $0.state == .open || $0.state == .waiting }.count
        let suggestedCount = loops.filter { $0.epistemic == .suggested && ($0.state == .open || $0.state == .waiting) }.count
        HStack(spacing: 6) {
            if matter.lifecycle == .active, let next = matter.projection?.nextAction?.title {
                Text(String(localized: "下一步：\(next)"))
                    .lineLimit(1)
            } else if matter.lifecycle == .completed, let completedAt = matter.completedAt {
                Text(String(localized: "已完成 · \(Self.dateText(completedAt))"))
            } else if activeCount > 0 {
                Text(String(localized: "\(activeCount) 个待确认"))
                    .lineLimit(1)
            }
            if matter.lifecycle == .active, suggestedCount > 0 {
                Text(String(localized: "· \(suggestedCount) 个 AI 猜测待你确认"))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func lifecycleBadge(_ matter: HoloMatter) -> some View {
        let (text, color): (String, Color) = {
            switch matter.lifecycle {
            case .active:
                return (matter.phase?.displayLabel ?? String(localized: "进行中"), .accentColor)
            case .completed:
                return (String(localized: "已完成"), .secondary)
            case .archived:
                return (String(localized: "已归档"), .secondary)
            case .candidate, .dismissed:
                return ("", .secondary)
            }
        }()
        return Group {
            if !text.isEmpty {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.12)))
            }
        }
    }

    nonisolated private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
