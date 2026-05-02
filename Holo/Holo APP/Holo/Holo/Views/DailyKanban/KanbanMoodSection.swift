//
//  KanbanMoodSection.swift
//  Holo
//
//  今日看板 — 心情日记输入卡片
//  输入内容自动同步到观点模块
//

import SwiftUI
import os.log

struct KanbanMoodSection: View {

    @State private var text: String = ""
    @State private var selectedMood: String? = nil
    @State private var isSaved: Bool = false
    @State private var selectedTags: Set<String> = []
    @State private var customTagInput: String = ""
    @State private var showTagField: Bool = false
    @State private var availableTags: [String] = []

    private let moods: [(emoji: String, name: String, value: String)] = [
        ("😄", "开心", "happy"),
        ("😌", "平静", "calm"),
        ("🤔", "思考", "thinking"),
        ("💡", "灵感", "inspired"),
        ("😢", "难过", "sad"),
        ("😤", "愤怒", "angry"),
        ("😴", "疲惫", "tired"),
        ("😰", "焦虑", "anxious"),
        ("🥳", "兴奋", "excited"),
        ("🙏", "感恩", "grateful"),
    ]

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedMood != nil
    }

    var body: some View {
        VStack(spacing: 8) {
            sectionHeader

            VStack(spacing: 10) {
                textEditor

                if isSaved {
                    savedView
                } else {
                    moodSelector
                    tagSection
                    saveRow
                }
            }
            .padding(16)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 1))
            .shadow(color: HoloShadow.card, radius: 4, y: 1)
        }
        .onAppear { loadTags() }
    }

    private var sectionHeader: some View {
        HStack {
            Label("今日心情", systemImage: "pencil.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var textEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .fill(Color.holoBackground)

            if text.isEmpty {
                Text("记录今天发生了什么...")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPlaceholder)
                    .padding(12)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(8)
                .disabled(isSaved)
        }
    }

    // MARK: - Mood Selector (single scrollable row)

    private var moodSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(moods, id: \.value) { mood in
                    Button {
                        selectedMood = selectedMood == mood.value ? nil : mood.value
                        HapticManager.selection()
                    } label: {
                        Text(mood.emoji)
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                            .background(
                                selectedMood == mood.value
                                    ? Color.holoPrimaryLight
                                    : Color.clear
                            )
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(
                                        selectedMood == mood.value ? Color.holoPrimary : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tag Section (from ThoughtTag)

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !availableTags.isEmpty || !selectedTags.subtracting(availableTags).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allDisplayTags, id: \.self) { tag in
                            tagChip(tag)
                        }

                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                showTagField.toggle()
                            }
                        } label: {
                            Image(systemName: showTagField ? "xmark" : "plus")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.holoTextSecondary)
                                .frame(width: 28, height: 28)
                                .background(Color.holoBackground)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showTagField.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                            .font(.system(size: 10))
                        Text("添加标签")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.holoTextSecondary)
                }
                .buttonStyle(.plain)
            }

            if showTagField {
                tagInputField
            }
        }
    }

    private var allDisplayTags: [String] {
        let custom = selectedTags.subtracting(Set(availableTags))
        return availableTags + custom.sorted()
    }

    private func tagChip(_ tag: String) -> some View {
        let isSelected = selectedTags.contains(tag)
        return Button {
            if isSelected {
                selectedTags.remove(tag)
            } else {
                selectedTags.insert(tag)
            }
            HapticManager.selection()
        } label: {
            HStack(spacing: 3) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(tag)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .holoPrimary : .holoTextSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.holoPrimaryLight : Color.holoBackground)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.holoPrimary : Color.holoBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var tagInputField: some View {
        HStack(spacing: 8) {
            TextField("自定义标签", text: $customTagInput)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.holoBackground)
                .clipShape(Capsule())

            Button {
                addCustomTag()
            } label: {
                Text("添加")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoPrimary)
            }
            .disabled(customTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var saveRow: some View {
        HStack {
            Spacer()
            saveButton
        }
    }

    private var saveButton: some View {
        Button { saveMood() } label: {
            Text("保存")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(canSave ? Color.holoPrimary : Color.holoPrimary.opacity(0.4))
                .clipShape(Capsule())
        }
        .disabled(!canSave)
    }

    private var savedView: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.holoSuccess)
            Text("已保存到观点模块")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoSuccess)
        }
    }

    // MARK: - Actions

    private func loadTags() {
        do {
            let repo = ThoughtRepository()
            let tags = try repo.getAllTags()
            availableTags = tags.map { $0.name }.sorted { $0 < $1 }
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("加载标签失败: \(error.localizedDescription)")
        }
    }

    private func addCustomTag() {
        let trimmed = customTagInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedTags.insert(trimmed)
        if !availableTags.contains(trimmed) {
            availableTags.append(trimmed)
        }
        customTagInput = ""
    }

    private func saveMood() {
        do {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty || selectedMood != nil else { return }

            var tags = ["每日记录"]
            tags.append(contentsOf: selectedTags)

            let repo = ThoughtRepository()
            _ = try repo.create(
                content: content.isEmpty ? "\(selectedMood ?? "记录")" : content,
                mood: selectedMood,
                tags: tags
            )

            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isSaved = true
            }
            HapticManager.success()
        } catch {
            Logger(subsystem: "com.holo.app", category: "UI").error("保存心情日记失败: \(error.localizedDescription)")
        }
    }
}
