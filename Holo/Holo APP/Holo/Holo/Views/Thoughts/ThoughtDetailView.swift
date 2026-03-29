//
//  ThoughtDetailView.swift
//  Holo
//
//  观点模块 - 想法详情页
//  展示想法完整内容、引用关系和反向链接
//

import SwiftUI
import CoreData

// MARK: - ThoughtDetailView

/// 想法详情视图
struct ThoughtDetailView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    let thoughtId: UUID
    let thoughtRepository: ThoughtRepository

    /// 当前想法
    @State private var thought: Thought? = nil

    /// 该想法引用的其他想法
    @State private var references: [Thought] = []

    /// 引用该想法的其他想法
    @State private var referencedBy: [Thought] = []

    /// 选中的引用想法 ID（用于跳转）
    @State private var selectedReferenceId: UUID? = nil

    /// 是否显示编辑 sheet
    @State private var showEditSheet: Bool = false

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                    // 内容区域
                    contentSection

                    // 标签区域
                    if let thought = thought, !thought.tagArray.isEmpty {
                        tagsSection
                    }

                    // 引用区域（该想法引用的其他想法）
                    if !references.isEmpty {
                        referencesSection
                    }

                    // 反向链接区域（引用该想法的其他想法）
                    if !referencedBy.isEmpty {
                        referencedBySection
                    }

                    // 底部间距
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("想法详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("编辑") {
                        showEditSheet = true
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .sheet(item: $selectedReferenceId) { refId in
                ThoughtDetailView(
                    thoughtId: refId,
                    thoughtRepository: thoughtRepository
                )
            }
            .sheet(isPresented: $showEditSheet) {
                ThoughtEditorView(
                    onSave: {
                        loadData()
                    },
                    editingThoughtId: thoughtId
                )
            }
            .onAppear {
                loadData()
            }
        }
    }

    // MARK: - 数据加载

    private func loadData() {
        do {
            thought = try thoughtRepository.fetchById(thoughtId)
            references = try thoughtRepository.getReferences(for: thoughtId)
            referencedBy = try thoughtRepository.getReferencedBy(id: thoughtId)
        } catch {
            print("[ThoughtDetailView] 加载数据失败：\(error)")
        }
    }

    // MARK: - 内容区域

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 心情和日期
            HStack {
                if let moodType = thought?.moodType {
                    Text(moodType.emoji)
                        .font(.system(size: 28))
                    Text(moodType.displayName)
                        .font(.holoCaption)
                        .foregroundColor(moodType.color)
                }

                Spacer()

                Text(thought?.formattedDate ?? "")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            // 内容
            Text(thought?.content ?? "")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .multilineTextAlignment(.leading)
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

    // MARK: - 标签区域

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("标签")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(thought?.tagArray ?? []) { tag in
                    TagChip(
                        text: "#\(tag.name)",
                        isSelected: true,
                        color: tag.tagColor
                    ) {
                        // 无操作
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

    // MARK: - 引用区域

    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("引用")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: HoloSpacing.sm) {
                ForEach(references) { ref in
                    ReferenceCardView(thought: ref)
                        .onTapGesture {
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

    // MARK: - 反向链接区域

    private var referencedBySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("被引用")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "link.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimary)
            }

            VStack(spacing: HoloSpacing.sm) {
                ForEach(referencedBy) { ref in
                    ReferenceCardView(thought: ref)
                        .onTapGesture {
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
}

// MARK: - ReferenceCardView

/// 引用卡片组件
struct ReferenceCardView: View {
    let thought: Thought

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：心情 + 日期
            HStack {
                if let moodType = thought.moodType {
                    Text(moodType.emoji)
                        .font(.system(size: 16))
                }
                Text(thought.formattedDate)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
            }

            // 内容预览
            Text(thought.previewText)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(2)

            // 标签
            if !thought.tagArray.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(thought.tagArray.prefix(3)) { tag in
                        Text("#\(tag.name)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(tag.tagColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tag.tagColor.opacity(0.1))
                            .cornerRadius(HoloRadius.sm)
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
    }
}

// MARK: - Preview

#Preview {
    // 需要 Core Data 环境
    Text("ThoughtDetailView Preview")
}
