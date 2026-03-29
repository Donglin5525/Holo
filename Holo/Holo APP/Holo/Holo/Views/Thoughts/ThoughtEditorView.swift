//
//  ThoughtEditorView.swift
//  Holo
//
//  观点模块 - 编辑器视图
//  用于创建和编辑想法
//

import SwiftUI
import CoreData

import os.log

/// 简易日志工具
private enum ThoughtLog {
    private static let logger = Logger(subsystem: "com.holo.app", category: "ThoughtEditor")
    static func error(_ message: String, _ error: String) {
        logger.error("\(message): \(error)")
    }
}

// MARK: - ThoughtEditorView

/// 想法编辑器视图
struct ThoughtEditorView: View {

    // MARK: - Properties

    @Environment(\.dismiss) var dismiss
    private let thoughtRepository = ThoughtRepository()

    /// 保存完成回调
    var onSave: (() -> Void)?
    /// 编辑模式（传入已有想法 ID）
    var editingThoughtId: UUID? = nil

    // MARK: - Form State
    @State private var content: String = ""
    @State private var selectedMood: ThoughtMoodType? = nil
    @State private var selectedTags: [String] = []
    @State private var referencedThoughtIds: [UUID] = []

    // MARK: - UI State
    @State private var showMoodSelector: Bool = false
    @State private var showTagInput: Bool = false
    @State private var showReferenceSelector: Bool = false
    @State private var isSaving: Bool = false
    /// 是否为编辑模式
    private var isEditing: Bool { editingThoughtId != nil }

    /// 是否可保存
    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    // MARK: - Body
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    // 心情选择
                    moodSection
                    // 内容编辑区
                    contentSection
                    // 标签区域
                    tagsSection
                    // 引用区域
                    referencesSection
                }
                .padding(.horizontal, HoloSpacing.lg)
            }
            .background(Color.holoBackground)
            .navigationTitle(isEditing ? "编辑想法" : "记录想法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveThought()
                    }
                    .foregroundColor(canSave ? .holoPrimary : .holoTextSecondary)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
        .sheet(isPresented: $showMoodSelector) {
            MoodSelectorView(selectedMood: $selectedMood)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTagInput) {
            TagInputView(selectedTags: $selectedTags)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showReferenceSelector) {
            ReferenceSelectorView(selectedIds: $referencedThoughtIds)
                .presentationDetents([.large])
        }
        .onAppear {
            loadEditingData()
        }
    }

    // MARK: - Sections

    /// 心情选择区域
    private var moodSection: some View {
        Button {
            showMoodSelector = true
        } label: {
            HStack {
                if let mood = selectedMood {
                    Text(mood.emoji)
                        .font(.system(size: 20))
                    Text(mood.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                } else {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundColor(.holoTextSecondary)
                    Text("选择心情（可选）")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    /// 内容编辑区域
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("内容")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            TextEditor(text: $content)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .frame(minHeight: 200)
                .padding(HoloSpacing.sm)
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.md)
                        .stroke(Color.holoBorder, lineWidth: 1)
                )
        }
    }

    /// 标签区域
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    showTagInput = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }

            if selectedTags.isEmpty {
                Text("点击 + 添加标签")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedTags, id: \.self) { tag in
                            TagChip(
                                text: "#\(tag)",
                                isSelected: true,
                                color: .holoPrimary
                            ) {
                                removeTag(tag)
                            }
                        }
                    }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    /// 引用区域
    private var referencesSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("引用")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    showReferenceSelector = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.holoPrimary)
                }
            }

            if referencedThoughtIds.isEmpty {
                Text("点击 + 引用其他想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
            } else {
                Text("已引用 \(referencedThoughtIds.count) 条想法")
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    // MARK: - Actions
    /// 加载编辑数据
    private func loadEditingData() {
        guard let thoughtId = editingThoughtId else { return }

        do {
            let repo = ThoughtRepository()
            guard let thought = try repo.fetchById(thoughtId) else {
                return
            }

            content = thought.content
            selectedMood = ThoughtMoodType(from: thought.mood)
            selectedTags = thought.tagArray.map { $0.name }
            referencedThoughtIds = (thought.references as? Set<ThoughtReference>)?.compactMap { $0.targetThought.id } ?? []
        } catch {
            ThoughtLog.error("加载编辑数据失败", error.localizedDescription)
        }
    }

    /// 移除标签
    private func removeTag(_ tag: String) {
        selectedTags.removeAll { $0 == tag }
    }

    /// 保存想法
    private func saveThought() {
        guard canSave else { return }
        isSaving = true

        let repository = ThoughtRepository()

        do {
            if isEditing, let thoughtId = editingThoughtId {
                // 编辑模式：更新已有想法
                try repository.update(
                    thoughtId,
                    content: content,
                    mood: selectedMood?.rawValue,
                    tags: selectedTags
                )
            } else {
                // 新建模式
                let thought = try repository.create(
                    content: content,
                    mood: selectedMood?.rawValue,
                    tags: selectedTags
                )
                // 添加引用关系
                for targetId in referencedThoughtIds {
                    try repository.addReference(sourceId: thought.id, targetId: targetId)
                }
            }
        } catch {
            ThoughtLog.error("观点保存失败", error.localizedDescription)
            isSaving = false
            return
        }

        // 发送数据变更通知
        NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        onSave?()
        dismiss()
    }
}

// MARK: - Preview
#Preview {
    ThoughtEditorView()
}
