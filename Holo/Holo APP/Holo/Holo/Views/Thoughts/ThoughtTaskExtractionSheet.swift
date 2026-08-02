//
//  ThoughtTaskExtractionSheet.swift
//  Holo
//
//  从想法内容里逐行/批量提取任务，每条任务自动关联来源想法
//

import SwiftUI

/// 单行候选任务
struct TaskCandidateRow: Identifiable {
    let id = UUID()
    var text: String
    var isSelected: Bool
}

/// 从想法文本里提取任务的批量确认面板
///
/// 用法：传入想法的纯文本内容（保留换行），面板会按行拆分，
/// 自动识别列表型内容（`-` / `*` / `[]` / `数字.` 开头）并预勾选，
/// 用户可逐行增删、编辑文本，确认后批量建任务。
struct ThoughtTaskExtractionSheet: View {

    /// 预填的候选行（由调用方拆好传入）
    @State private var candidates: [TaskCandidateRow]

    /// 来源想法（每条任务都关联它）
    private let sourceThought: Thought

    /// 想法纯文本（供 AI 提取用）
    private let plainContent: String

    /// 关闭回调
    private let onDismiss: () -> Void

    /// 成功创建后刷新来源数据
    private let onCreated: () -> Void

    /// 是否正在批量创建
    @State private var isCreating = false

    /// 是否正在 AI 提取
    @State private var isExtracting = false

    /// AI 提取失败提示
    @State private var extractError = false

    /// 成功提示
    @State private var createdCount = 0
    @State private var showSuccess = false

    init(
        plainContent: String,
        sourceThought: Thought,
        onDismiss: @escaping () -> Void,
        onCreated: @escaping () -> Void
    ) {
        self.sourceThought = sourceThought
        self.plainContent = plainContent
        self.onDismiss = onDismiss
        self.onCreated = onCreated
        _candidates = State(initialValue: Self.buildCandidates(from: plainContent))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if candidates.isEmpty {
                    emptyState
                } else {
                    candidateList
                }
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("提取任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消", action: onDismiss)
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        Task { await runAIExtraction() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                            if isExtracting {
                                Text("识别中…")
                                    .font(.holoCaption)
                            } else {
                                Text("AI 智能识别")
                                    .font(.holoCaption.bold())
                            }
                        }
                        .foregroundColor(isExtracting ? .holoTextSecondary : .holoPrimary)
                    }
                    .disabled(isExtracting || isCreating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        createTasks()
                    } label: {
                        if isCreating {
                            Text("创建中…")
                                .font(.holoBody)
                                .foregroundColor(.holoTextSecondary)
                        } else {
                            Text("创建 \(selectedCount) 项")
                                .font(.holoBody.bold())
                                .foregroundColor(selectedCount > 0 ? .holoPrimary : .holoTextSecondary)
                        }
                    }
                    .disabled(selectedCount == 0 || isCreating)
                }
            }
            .alert("已创建 \(createdCount) 个任务", isPresented: $showSuccess) {
                Button("好的", role: .cancel) {
                    onCreated()
                    onDismiss()
                }
            } message: {
                Text("任务已加入待办列表，可在任务模块查看。")
            }
            .alert("识别失败", isPresented: $extractError) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("AI 暂时无法识别，请稍后再试，或手动勾选下方内容。")
            }
        }
    }

    // MARK: - 列表

    private var candidateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                Text("已自动识别列表内容并勾选，可逐行调整。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.top, HoloSpacing.sm)

                ForEach($candidates) { $row in
                    HStack(spacing: 10) {
                        Button {
                            row.isSelected.toggle()
                        } label: {
                            Image(systemName: row.isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundColor(row.isSelected ? .holoPrimary : .holoTextSecondary)
                        }
                        .buttonStyle(.plain)

                        TextField("任务内容", text: $row.text)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .textFieldStyle(.plain)
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
                    .padding(.horizontal, HoloSpacing.md)
                }

                Spacer(minLength: HoloSpacing.lg)
            }
            .padding(.top, HoloSpacing.sm)
        }
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 40))
                .foregroundColor(.holoTextSecondary)
            Text("没有可提取的内容")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 操作

    private var selectedCount: Int {
        candidates.filter { $0.isSelected && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// 批量创建任务
    private func createTasks() {
        let picked = candidates
            .filter { $0.isSelected }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !picked.isEmpty else { return }
        isCreating = true

        for title in picked {
            do {
                _ = try TodoRepository.shared.createTask(
                    title: title,
                    description: nil,
                    sourceThought: sourceThought
                )
            } catch {
                continue
            }
        }

        isCreating = false
        createdCount = picked.count
        showSuccess = true
        HapticManager.success()
    }

    // MARK: - AI 智能识别

    /// 调 AI 从整篇想法里提炼待办，替换当前候选列表
    @MainActor
    private func runAIExtraction() async {
        isExtracting = true
        defer { isExtracting = false }

        do {
            let extractor = ThoughtTaskExtractor()
            let result = try await extractor.extract(from: plainContent)

            guard !result.titles.isEmpty else {
                extractError = true
                return
            }

            // 用 AI 提取的结果替换候选列表，全部预勾选
            candidates = result.titles.map { TaskCandidateRow(text: $0, isSelected: true) }
            HapticManager.light()
        } catch {
            extractError = true
        }
    }

    // MARK: - 文本拆分逻辑

    /// 把纯文本按行拆成候选行，识别列表型内容并预勾选
    static func buildCandidates(from plainContent: String) -> [TaskCandidateRow] {
        let lines = plainContent
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.map { line in
            let cleaned = Self.stripListMarker(line)
            return TaskCandidateRow(
                text: cleaned,
                isSelected: Self.isListLine(line)
            )
        }
        .filter { !$0.text.isEmpty }
    }

    /// 判断是否是列表型行（`-` / `*` / `+` / `[]` / `[x]` / `1.` 等开头）
    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.lowercased()
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("[ ] ") || trimmed.hasPrefix("[x] ") {
            return true
        }
        // 数字编号：1. / 1) / 1、
        if let regex = try? NSRegularExpression(pattern: "^\\d+[.\\)、] ", options: []) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            return regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }
        return false
    }

    /// 去掉行首的列表标记，保留纯文本
    private static func stripListMarker(_ line: String) -> String {
        var s = line
        let markers: [String] = ["- [ ] ", "- [x] ", "- [X] ", "[ ] ", "[x] ", "[X] "]
        for m in markers {
            if s.lowercased().hasPrefix(m.lowercased()) {
                s = String(s.dropFirst(m.count))
                return s.trimmingCharacters(in: .whitespaces)
            }
        }
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            s = String(s.dropFirst(2))
            return s.trimmingCharacters(in: .whitespaces)
        }
        // 数字编号
        if let regex = try? NSRegularExpression(pattern: "^\\d+[.\\)、] ", options: []) {
            let range = NSRange(location: 0, length: s.utf16.count)
            if let match = regex.firstMatch(in: s, options: [], range: range) {
                s = String(s.dropFirst(match.range.length))
                return s.trimmingCharacters(in: .whitespaces)
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
