//
//  MatterListView.swift
//  Holo
//
//  正在推进（2026-09-21 V2 §4.4）：主列表只显示 active；
//  已完成 / 已归档收进右上筛选，不再三组同屏。
//  列表不展示 candidate；dismissed 不出现。右上「+」打开 Holo 对话（带引导语，不预写用户消息）。
//

import SwiftUI

/// 列表内容模式：.allGroups = 旧三组同屏（看板/共用路由零回归）；
/// .single = V2 单组模式（列表页：主列表 active，历史经筛选查看）。
enum MatterListScope {
    case allGroups
    case single(HoloMatterLifecycleStatus)
}

struct MatterListView: View {

    /// 列表内点进详情（首版由调用方接管，nil 时行内不导航）。
    var onOpenMatter: ((UUID) -> Void)? = nil
    /// 「+」出口：打开 HoloAI 并给引导问题（不预写为用户消息）。
    var onAddTapped: (() -> Void)? = nil
    /// 详情页「和 Holo 讨论」出口（§8.5：所有入口统一接线，由调用方进 scoped Chat）。
    var onDiscussMatter: ((UUID) -> Void)? = nil

    @ObservedObject private var repository = HoloMatterRepository.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pushedMatterID: UUID?
    @State private var selectedScope: HoloMatterLifecycleStatus = .active

    public var body: some View {
        NavigationStack {
            MatterListContent(onDiscussMatter: { matterID in
                onDiscussMatter?(matterID)
            }, scope: .single(selectedScope))
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "正在推进"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(selection: $selectedScope) {
                            Text(verbatim: "正在推进").tag(HoloMatterLifecycleStatus.active)
                            Text(verbatim: "已完成").tag(HoloMatterLifecycleStatus.completed)
                            Text(verbatim: "已归档").tag(HoloMatterLifecycleStatus.archived)
                        } label: {
                            Text(verbatim: "筛选")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(Text(verbatim: "筛选"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onAddTapped?()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text(verbatim: "添加正在推进的事"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .navigationDestination(item: $pushedMatterID) { id in
                MatterDetailView(matterID: id) { discussID in
                    onDiscussMatter?(discussID)
                }
            }
        }
    }
}

/// 列表内容（无 NavigationStack）：独立 sheet 与「今天」内部路由共用（§10.1）。
struct MatterListContent: View {

    /// 详情页「和 Holo 讨论」出口。
    var onDiscussMatter: ((UUID) -> Void)? = nil
    /// .allGroups（默认）保持旧三组；.single 为 V2 单组模式。
    var scope: MatterListScope = .allGroups

    @ObservedObject private var repository = HoloMatterRepository.shared
    @State private var contentPushedMatterID: UUID?

    var body: some View {
        ScrollView(showsIndicators: false) {
            switch scope {
            case .allGroups:
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
            case .single(let status):
                let matters = repository.matters(lifecycles: [status])
                VStack(alignment: .leading, spacing: 14) {
                    if matters.isEmpty {
                        Text(verbatim: emptyText(for: status))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        ForEach(matters, id: \.id) { matter in
                            row(matter, hidePhaseBadge: true)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .navigationDestination(item: $contentPushedMatterID) { id in
            MatterDetailView(matterID: id) { discussID in
                onDiscussMatter?(discussID)
            }
        }
    }

    private func emptyText(for status: HoloMatterLifecycleStatus) -> String {
        switch status {
        case .active: return "还没有正在推进的事。想推进什么，直接告诉 Holo。"
        case .completed: return "还没有完成的事"
        default: return "还没有归档的事"
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

    private func row(_ matter: HoloMatter, hidePhaseBadge: Bool = false) -> some View {
        Button {
            contentPushedMatterID = matter.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(matter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    lifecycleBadge(matter, hidden: hidePhaseBadge)
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
        HStack(spacing: 6) {
            if matter.lifecycle == .active {
                // 实时确定性计算（V2 §5.6）：不读可能 stale 的 projection。
                if let next = MatterPlanQuery.nextActionTask(matterID: matter.id, repository: repository) {
                    Text(verbatim: "下一步：\(next.title)")
                        .lineLimit(1)
                }
            } else if matter.lifecycle == .completed, let completedAt = matter.completedAt {
                Text(String(localized: "已完成 · \(Self.dateText(completedAt))"))
            }
            if matter.lifecycle == .active, activeCount > 0 {
                Text(verbatim: "· \(activeCount) 个待确认")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func lifecycleBadge(_ matter: HoloMatter, hidden: Bool = false) -> some View {
        let (text, color): (String, Color) = {
            switch matter.lifecycle {
            case .active:
                // V2：active 态不显示内部阶段词汇（§4.2），仅完成/归档态保留状态徽章。
                return (hidden ? "" : (matter.phase?.displayLabel ?? String(localized: "进行中")), .accentColor)
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
