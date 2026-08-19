//
//  ThoughtTaskExtractionSheet.swift
//  Holo
//
//  从想法内容里逐行/批量提取任务，每条任务自动关联来源想法
//

import SwiftUI
import Foundation

/// 候选任务（整篇模式通常对应一行，选区模式可对应一整段）
struct TaskCandidateRow: Identifiable {
    let id = UUID()
    var text: String
    var isSelected: Bool
    /// 候选行在编辑器可见文本中的作用范围；AI 无法可靠映射时为空。
    var sourceRange: NSRange? = nil
    /// AI 预填的截止日期与优先级；用户在设置卡统一设置对应字段后不再生效
    var aiDueDate: Date? = nil
    var aiDueDateHasTime = false
    var aiPriority: TaskPriority? = nil
}

/// 创建任务后的结果，保留它对应的原文范围，供编辑器写入持续可见的关系标识。
struct CreatedThoughtTask: Equatable {
    let id: UUID
    let title: String
    let sourceRange: NSRange?
}

/// 从想法文本里提取任务的批量确认面板
///
/// 用法：传入想法的纯文本内容（保留换行），面板会按行拆分，
/// 自动识别列表型内容（`-` / `*` / `[]` / `数字.` 开头）并预勾选，
/// 用户可逐行增删、编辑文本；「任务设置」卡统一确认日期/优先级/清单/提醒
/// （AI 识别的日期/优先级预填到各行，用户统一设置后覆盖），确认后批量建任务。
struct ThoughtTaskExtractionSheet: View {

    /// 预填的候选行（由调用方拆好传入）
    @State private var candidates: [TaskCandidateRow]

    /// 来源想法（每条任务都关联它）
    private let sourceThought: Thought

    /// 想法原始内容（保留 markdown 标记，用于按行拆分和识别列表预勾选）。
    /// 任务标题和 AI 输入优先使用 visibleSourceText，避免把 `**`、颜色标记等存储语法
    /// 泄漏给用户；不能直接用整体 stripFormatting 后的文本判断列表，否则会丢失行首语义。
    private let rawContent: String

    /// 关闭回调
    private let onDismiss: () -> Void

    /// 成功创建后回调，参数同时携带任务 ID 和原文范围，供调用方插入关系标识 / 刷新数据。
    private let onCreated: ([CreatedThoughtTask]) -> Void

    /// 是否来自"选中文字转化"（影响顶部说明文案）
    private let isFromSelection: Bool

    /// 是否正在批量创建
    @State private var isCreating = false

    /// 是否正在 AI 提取
    @State private var isExtracting = false

    /// AI 提取失败提示
    @State private var extractError = false

    /// 成功提示
    @State private var createdCount = 0
    @State private var showSuccess = false
    /// 本批创建的任务 ID（供 onCreated 回调传出，调用方据此插入 ✅ 标记）
    @State private var createdTasks: [CreatedThoughtTask] = []

    /// 批量任务设置：截止日期/优先级/所属清单/提醒，统一应用于本批任务
    @State private var settings = ThoughtTaskBatchSettings()

    init(
        content: String,
        sourceThought: Thought,
        isFromSelection: Bool = false,
        visibleSourceText: String? = nil,
        sourceRange: NSRange? = nil,
        onDismiss: @escaping () -> Void,
        onCreated: @escaping ([CreatedThoughtTask]) -> Void
    ) {
        self.sourceThought = sourceThought
        self.rawContent = content
        self.isFromSelection = isFromSelection
        self.visibleSourceText = visibleSourceText
        self.onDismiss = onDismiss
        self.onCreated = onCreated
        _candidates = State(initialValue: Self.buildCandidates(
            from: content,
            defaultSelected: isFromSelection,
            sourceRange: sourceRange,
            visibleSourceText: visibleSourceText
        ))
    }

    /// 编辑器当前可见文本（已去掉 Markdown 标记），用于将整篇候选行映射回真实展示位置。
    private let visibleSourceText: String?

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
                if !isFromSelection {
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
                    onCreated(createdTasks)
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
                Text(hintText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.top, HoloSpacing.sm)

                ThoughtTaskSettingsCard(settings: $settings, selectedRows: selectedCandidates)

                ForEach($candidates) { $row in
                    HStack(spacing: 10) {
                        Button {
                            row.isSelected.toggle()
                        } label: {
                            Image(systemName: row.isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18))
                                .foregroundColor(row.isSelected ? .holoPrimary : .holoTextSecondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.isSelected ? "取消选择任务" : "选择任务")

                        TextField("任务内容", text: $row.text)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .textFieldStyle(.plain)

                        if !settings.userTouchedDate, let aiDate = row.aiDueDate {
                            ThoughtTaskAIBadge(text: ThoughtTaskBadgeFormatter.shortDateLabel(aiDate))
                        }
                        if !settings.userTouchedPriority, let aiPriority = row.aiPriority, aiPriority != .medium {
                            ThoughtTaskAIBadge(text: aiPriority.displayTitle, tint: aiPriority.color)
                        }
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

    private var selectedCandidates: [TaskCandidateRow] {
        candidates.filter { $0.isSelected && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var selectedCount: Int {
        selectedCandidates.count
    }

    /// 顶部说明文案：根据来源（选中文字 / 整篇想法）动态显示
    private var hintText: String {
        if isFromSelection {
            return "已选文字将创建为一个任务，可先修改标题，并设置日期、优先级等信息。"
        }
        return "已自动识别列表内容并勾选，可逐行调整；下方任务设置将统一应用于本批任务。"
    }

    /// 批量创建任务
    private func createTasks() {
        let picked = candidates.compactMap { row -> (row: TaskCandidateRow, title: String)? in
            guard row.isSelected else { return nil }
            let title = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (row, title)
        }

        guard !picked.isEmpty else { return }
        isCreating = true

        var succeeded = 0
        var tasks: [CreatedThoughtTask] = []
        for item in picked {
            do {
                let dueDate = settings.effectiveDueDate(for: item.row)
                let task = try TodoRepository.shared.createTask(
                    title: item.title,
                    description: nil,
                    list: settings.selectedList,
                    priority: settings.effectivePriority(for: item.row),
                    dueDate: dueDate,
                    isAllDay: settings.effectiveIsAllDay(for: item.row),
                    reminders: dueDate != nil && !settings.reminders.isEmpty ? settings.reminders : nil,
                    sourceThought: sourceThought,
                    sourceTextSnippet: isFromSelection ? item.title : nil
                )
                succeeded += 1
                tasks.append(CreatedThoughtTask(
                    id: task.id,
                    title: item.title,
                    sourceRange: item.row.sourceRange
                ))
            } catch {
                continue
            }
        }

        isCreating = false
        createdCount = succeeded
        createdTasks = tasks
        showSuccess = succeeded > 0
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
            let result = try await extractor.extract(from: visibleSourceText ?? rawContent)

            guard !result.tasks.isEmpty else {
                extractError = true
                return
            }

            // 用 AI 提取的结果替换候选列表，全部预勾选；
            // 日期/优先级预填到各行（用户在设置卡统一设置后覆盖）
            candidates = result.tasks.map { task in
                TaskCandidateRow(
                    text: task.title,
                    isSelected: true,
                    sourceRange: Self.uniqueSourceRange(for: task.title, in: visibleSourceText),
                    aiDueDate: task.dueDate,
                    aiDueDateHasTime: task.dueDateHasTime,
                    aiPriority: task.priority
                )
            }
            HapticManager.light()
        } catch {
            extractError = true
        }
    }

    // MARK: - 文本拆分逻辑

    /// 把纯文本按行拆成候选行。
    /// - defaultSelected=false（整篇转化）：仅列表型行预勾选
    /// - defaultSelected=true（选中转化）：整段选区对应一个任务，避免多行选区生成无法逐一标记的任务。
    static func buildCandidates(
        from plainContent: String,
        defaultSelected: Bool = false,
        sourceRange: NSRange? = nil,
        visibleSourceText: String? = nil
    ) -> [TaskCandidateRow] {
        if defaultSelected {
            let selectedText = plainContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedText.isEmpty else { return [] }
            return [TaskCandidateRow(
                text: selectedText,
                isSelected: true,
                sourceRange: sourceRange
            )]
        }

        let lines = plainContent
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let sourceRanges = visibleSourceText.map(Self.lineSourceRanges(in:)) ?? []

        let visibleLines = visibleSourceText?.components(separatedBy: "\n")

        return lines.enumerated().map { index, line in
            // 原始行负责识别 `-` / `1.` 等列表；展示行使用编辑器实际可见文本，
            // 这样加粗、颜色和 Token 不会以 Markdown 存储语法出现在任务标题里。
            let displayLine = visibleLines?.indices.contains(index) == true
                ? visibleLines?[index] ?? line
                : MarkdownParser.stripFormatting(line)
            let cleaned = Self.stripListMarker(displayLine)
            return TaskCandidateRow(
                text: cleaned,
                isSelected: defaultSelected || Self.isListLine(line),
                sourceRange: sourceRanges.indices.contains(index) ? sourceRanges[index] : nil
            )
        }
        .filter { !$0.text.isEmpty }
    }

    /// 将编辑器显示文本按非空行切成范围，并排除列表符号，只标记真正的文字。
    nonisolated private static func lineSourceRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []
        var lineStart = 0

        while lineStart <= nsText.length {
            let remaining = nsText.length - lineStart
            let newlineOffset = remaining > 0
                ? nsText.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: lineStart, length: remaining)
                ).location
                : NSNotFound
            let lineLength = newlineOffset == NSNotFound ? remaining : newlineOffset
            let rawLine = nsText.substring(with: NSRange(location: lineStart, length: lineLength))
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if !trimmed.isEmpty {
                // 这里的偏移必须和 UITextView.selectedRange 一样使用 UTF-16；空格和 Tab
                // 都是单个 UTF-16 单元，因此逐单元扫描不会被 emoji/CJK 的 Character 数量干扰。
                var leadingWhitespace = 0
                while leadingWhitespace < rawLine.utf16.count {
                    let character = nsText.substring(
                        with: NSRange(location: lineStart + leadingWhitespace, length: 1)
                    )
                    guard character == " " || character == "\t" else { break }
                    leadingWhitespace += 1
                }
                var contentStart = lineStart + leadingWhitespace
                let contentLength = max(0, rawLine.utf16.count - leadingWhitespace)
                let contentLine = nsText.substring(with: NSRange(location: contentStart, length: contentLength))

                if let prefixLength = visibleListPrefixLength(in: contentLine) {
                    contentStart += prefixLength
                }

                let end = lineStart + lineLength
                if contentStart < end {
                    ranges.append(NSRange(location: contentStart, length: end - contentStart))
                }
            }

            guard newlineOffset != NSNotFound else { break }
            lineStart += lineLength + 1
        }

        return ranges
    }

    nonisolated private static func visibleListPrefixLength(in line: String) -> Int? {
        if line.hasPrefix("• ") { return ("• " as NSString).length }
        if let regex = try? NSRegularExpression(pattern: "^\\d+\\. ") {
            let range = NSRange(location: 0, length: line.utf16.count)
            return regex.firstMatch(in: line, range: range)?.range.length
        }
        return nil
    }

    /// 仅在标题在正文中唯一出现时自动建立 AI 结果的来源范围，避免重复句误标。
    private static func uniqueSourceRange(for title: String, in sourceText: String?) -> NSRange? {
        guard let sourceText, !title.isEmpty else { return nil }
        let nsSource = sourceText as NSString
        var matches: [NSRange] = []
        var searchLocation = 0
        while searchLocation < nsSource.length {
            let searchRange = NSRange(
                location: searchLocation,
                length: nsSource.length - searchLocation
            )
            let match = nsSource.range(of: title, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)
            searchLocation = NSMaxRange(match)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
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
        if s.hasPrefix("• ") {
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
