//
//  ThoughtKnowledgeDrawerView.swift
//  Holo
//
//  观点模块 - 左侧知识树抽屉
//  顶部菜单按钮唤出，点击遮罩关闭（P1）；右边缘左滑关闭（P1.5）
//  spec: docs/superpowers/specs/2026-06-23-thought-knowledge-tree-design.md
//

import SwiftUI

// MARK: - DrawerNode 抽屉节点

/// 抽屉节点类型（右侧列表的筛选意图载体）
/// 实施方案 §4.6
enum DrawerNode: Hashable {
    case allNotes          // 全部笔记
    case unclassified      // 未归类（未进入任何 Topic）
    case aiTag(String)     // AI 标签池某标签（tagName）
    case topic(UUID)       // 某主题（topicId，P1.5）
    case aiOrganize        // AI 整理入口（非筛选，触发预告）
}

// MARK: - ThoughtKnowledgeDrawerView

/// 观点左侧知识树抽屉
struct ThoughtKnowledgeDrawerView: View {

    /// 当前选中节点
    @Binding var selection: DrawerNode?

    /// 点击节点回调（选中节点；不关闭抽屉，关闭由遮罩/右边缘负责）
    let onSelect: (DrawerNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = min(320, geo.size.width * 0.82)
            HStack(spacing: 0) {
                content
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color.holoCardBackground)
                // 右侧留白（遮罩盖住，提示可关闭）
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                nodeRow(.allNotes, icon: "tray.full", title: "全部笔记")
                nodeRow(.unclassified, icon: "square.dashed", title: "未归类")

                sectionLabel("主题")
                topicEmpty

                sectionLabel(".ai 标签池")
                aiPoolPlaceholder

                Divider()
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.vertical, HoloSpacing.sm)

                aiOrganizeRow
            }
            .padding(.vertical, HoloSpacing.md)
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("观点")
                .font(.holoHeading)
                .foregroundColor(.holoTextPrimary)
            Text("知识树")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.md)
    }

    // MARK: - 通用节点行

    private func nodeRow(_ node: DrawerNode, icon: String, title: String) -> some View {
        let isSelected = selection == node
        return Button {
            onSelect(node)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
                    .frame(width: 26)

                Text(title)
                    .font(.holoBody)
                    .foregroundColor(isSelected ? .holoPrimary : .holoTextPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary)
                    .opacity(isSelected ? 1 : 0.3)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(isSelected ? Color.holoPrimary.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 分组标题

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.holoLabel)
            .foregroundColor(.holoTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.top, HoloSpacing.md)
            .padding(.bottom, HoloSpacing.xs)
    }

    // MARK: - 主题区空态（P1 Topic 表为空）

    private var topicEmpty: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundColor(.holoAI)
            Text("暂无主题，AI 整理后生成")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - AI 标签池（P1.2 接 fetchAITagBuckets）

    private var aiPoolPlaceholder: some View {
        // TODO: P1.2 接 ThoughtRepository.fetchAITagBuckets 真实聚合
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "tag")
                .font(.system(size: 13))
                .foregroundColor(.holoAI)
            Text("暂无 AI 标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.sm)
    }

    // MARK: - AI 整理入口（P1.3 接「待整理 N 条」）

    private var aiOrganizeRow: some View {
        Button {
            onSelect(.aiOrganize)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundColor(.holoAI)
                    .frame(width: 26)

                Text("AI 整理")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer()

                // TODO: P1.3 改为「待整理 N 条 .ai 标签」
                Text("功能开发中")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.sm)
                    .padding(.vertical, 2)
                    .background(Color.holoBackground)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .buttonStyle(.plain)
    }
}
