//
//  ThoughtReferenceListView.swift
//  Holo
//
//  想法模块 - 引用关系列表（编辑页「查看引用」弹层）
//  承接原详情页的「引用 / 被引用」区块：点卡片直接打开那条想法的编辑页。
//

import SwiftUI

// MARK: - ThoughtReferenceListView

/// 引用关系列表：上半区「引用」（本条 @ 过的想法）、下半区「被引用」（@ 过本条的想法）。
/// 从编辑页「…」菜单进入，点任意卡片以 sheet 打开对方想法的编辑器。
struct ThoughtReferenceListView: View {

    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository

    @Environment(\.dismiss) private var dismiss

    /// 该想法引用的其他想法
    @State private var references: [Thought] = []

    /// 引用该想法的其他想法
    @State private var referencedBy: [Thought] = []

    /// 选中的引用想法 ID（sheet 打开对方编辑器）
    @State private var selectedReferenceId: UUID? = nil

    var body: some View {
        NavigationStack {
            Group {
                if references.isEmpty && referencedBy.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                            if !references.isEmpty {
                                referenceSection(
                                    title: String(localized: "引用"),
                                    iconName: "quote.opening",
                                    thoughts: references
                                )
                            }
                            if !referencedBy.isEmpty {
                                referenceSection(
                                    title: String(localized: "被引用"),
                                    iconName: "link.circle",
                                    thoughts: referencedBy
                                )
                            }
                        }
                        .padding(.horizontal, HoloSpacing.md)
                        .padding(.vertical, HoloSpacing.sm)
                    }
                }
            }
            .background(Color.holoBackground)
            .navigationTitle("引用关系")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "完成")) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedReferenceId) { refId in
                ThoughtEditorView(editingThoughtId: refId)
            }
            .onAppear {
                loadData()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 区块

    private func referenceSection(title: String, iconName: String, thoughts: [Thought]) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: iconName)
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
            }

            VStack(spacing: HoloSpacing.sm) {
                ForEach(thoughts) { ref in
                    ReferenceCardView(thought: ref) {
                        selectedReferenceId = ref.id
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.lg)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
    }

    /// 无引用关系的空态：正文行内 @ 是唯一引用来源，没有引用很正常，轻文案即可
    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 32))
                .foregroundColor(.holoTextPlaceholder)
            Text("这条想法还没有引用关系")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("在正文输入 @ 可以引用另一条想法")
                .font(.holoCaption)
                .foregroundColor(.holoTextPlaceholder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 数据

    private func loadData() {
        references = (try? thoughtRepository.getReferences(for: thoughtId)) ?? []
        referencedBy = (try? thoughtRepository.getReferencedBy(id: thoughtId)) ?? []
    }
}

// MARK: - ReferenceCardView

/// 引用卡片组件
struct ReferenceCardView: View {
    let thought: Thought
    var onTap: (() -> Void)? = nil

    var body: some View {
        // 点击用 Button 承载：a11y 合并元素 + 纯 onTapGesture 在 iOS 26 不响应触摸（同想法卡片教训）
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // 顶部：日期
                HStack {
                    Text(thought.formattedDate)
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                    Spacer()
                }

                // 内容预览也走正文富文本管线，保证关系卡片里的 Markdown、@ 引用、任务标记
                // 与列表卡片使用同一字号、行距和 Token 展示逻辑。
                ReadOnlyRichTextView(
                    nodes: contentNodes,
                    onTokenTap: { _ in },
                    lineLimit: 2,
                    allowsTokenInteraction: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                // 标签
                if !thought.tagArray.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(thought.tagArray.prefix(3)) { tag in
                            Text("#\(ThoughtTagNormalizer.lastSegment(tag.name))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(tag.tagColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tag.tagColor.opacity(0.1))
                                .cornerRadius(HoloRadius.sm)
                                // 标签名称来自用户/AI数据，横向滚动时保持完整内容宽度
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(HoloSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .fill(Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md)
                    .stroke(Color.holoBorder, lineWidth: 1)
            )
            // contentShape 必须在 label 内声明（探针实证：Button 外=0 命中，label 内=命中）
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(.plain)
        // Button 天然合并 label 子元素；不挂额外的 a11y 合并修饰符（.ignore 实证会吞触摸）
        .accessibilityHint(onTap == nil ? "" : String(localized: "双击打开想法"))
    }

    private var contentNodes: [HoloContentNode] {
        RichContentSerializer.nodes(
            richJSON: thought.richContentJSON,
            fallbackPlainText: thought.content
        )
    }
}
