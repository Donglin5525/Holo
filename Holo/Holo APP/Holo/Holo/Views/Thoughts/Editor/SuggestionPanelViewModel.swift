//
//  SuggestionPanelViewModel.swift
//  Holo
//
//  观点模块 - 编辑器候选面板数据层
//  负责 # 标签 / @ 引用候选查询（150ms 防抖，并用请求序号防止旧结果覆盖新结果）
//

import Combine
import Foundation
import os.log

// MARK: - SuggestionPanelViewModel

@MainActor
final class SuggestionPanelViewModel: ObservableObject {

    /// 候选条目
    enum Item: Identifiable {
        /// 已有标签
        case tag(id: UUID, path: String)
        /// 创建新标签（无完全相同标签时出现）
        case createTag(path: String)
        /// 可引用的想法
        case reference(id: UUID, title: String, preview: String, snapshot: String, dateText: String)

        var id: String {
            switch self {
            case .tag(let id, _):
                return "tag-\(id.uuidString)"
            case .createTag(let path):
                return "create-\(path)"
            case .reference(let id, _, _, _, _):
                return "ref-\(id.uuidString)"
            }
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedIndex: Int? = nil

    /// 面板只展示前 6 条，键盘选择也必须使用同一份可见列表，避免选中隐藏条目。
    var visibleItems: [Item] {
        Array(items.prefix(6))
    }

    var selectedItem: Item? {
        guard let selectedIndex, visibleItems.indices.contains(selectedIndex) else { return nil }
        return visibleItems[selectedIndex]
    }

    /// 回车默认提交第一条；用户用上下键移动后则提交当前高亮项。
    var defaultCommitItem: Item? {
        selectedItem ?? visibleItems.first
    }

    private let repository = ThoughtRepository()
    private let logger = Logger(subsystem: "com.holo.app", category: "ThoughtSuggestion")
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private static let debounce: Duration = .milliseconds(150)

    // MARK: - 搜索

    /// 触发上下文变化时重新搜索；nil 时清空
    func search(context: EditorTriggerContext?, excludingThoughtId: UUID?) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        guard let context else {
            items = []
            selectedIndex = nil
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.performSearch(
                context: context,
                excludingThoughtId: excludingThoughtId,
                generation: generation
            )
        }
    }

    private func performSearch(
        context: EditorTriggerContext,
        excludingThoughtId: UUID?,
        generation: Int
    ) async {
        guard generation == searchGeneration else { return }

        let result: [Item]
        switch context {
        case .tag(_, let query):
            let tags: [ThoughtRepository.TagCandidateSnapshot]
            do {
                tags = try await repository.fetchTagCandidateSnapshots(query: query)
            } catch {
                logger.error("标签候选查询失败：\(error.localizedDescription, privacy: .public)")
                return
            }
            result = tagItems(for: tags, query: query)

        case .reference(_, let query):
            let thoughts: [ThoughtRepository.ReferenceCandidateSnapshot]
            do {
                thoughts = try await repository.fetchReferenceCandidateSnapshots(
                    query: query,
                    excludingThoughtId: excludingThoughtId
                )
            } catch {
                logger.error("引用候选查询失败：\(error.localizedDescription, privacy: .public)")
                return
            }
            result = thoughts.map(referenceItem)
        }

        // Core Data 查询可能在主线程上耗时；查询完成后再次确认请求仍然有效，避免旧结果覆盖新输入。
        guard generation == searchGeneration else { return }
        items = result
        selectedIndex = nil
    }

    // MARK: - 键盘选择

    func moveSelection(by offset: Int) {
        let count = visibleItems.count
        guard count > 0 else {
            selectedIndex = nil
            return
        }

        let current = selectedIndex ?? (offset >= 0 ? -1 : count)
        selectedIndex = (current + offset + count) % count
    }

    func clearSelection() {
        selectedIndex = nil
    }

    // MARK: - 创建标签

    /// 创建不存在的标签（用于 insertTagToken 的真实 tagId）
    func createTag(path: String) -> ThoughtTag? {
        try? repository.getOrCreateTagEntity(path: path)
    }

    // MARK: - Private

    private func tagItems(for tags: [ThoughtRepository.TagCandidateSnapshot], query: String) -> [Item] {
        var result: [Item] = tags.map { .tag(id: $0.id, path: $0.name) }

        let normalized = ThoughtTagNormalizer.displayPath(query)
        let queryKey = ThoughtTagNormalizer.key(normalized)
        let existsExact = tags.contains { ThoughtTagNormalizer.key($0.name) == queryKey }
        if !normalized.isEmpty, !existsExact {
            result.append(.createTag(path: normalized))
        }

        return result
    }

    private func referenceItem(for thought: ThoughtRepository.ReferenceCandidateSnapshot) -> Item {
        // 候选面板、插入后的 Token 和 Token 操作面板都应展示用户实际看到的文字，
        // 不能把 richContent 的 Markdown 存储标记（如 ** / {color:...}）泄漏出来。
        let nodes = RichContentSerializer.nodes(
            richJSON: thought.richContentJSON,
            fallbackPlainText: thought.content
        )
        let visibleContent = MarkdownTextView.visiblePlainText(from: nodes)
        let plain = visibleContent.replacingOccurrences(of: "\n", with: " ")
        // 候选行展示的标题必须和最终插入的 @Token 使用同一套长度规则，
        // 否则用户点选后，编辑器里会出现与候选项不同的文字，内外层看起来像引用错了。
        let rawTitle = RichContentSerializer.firstLine(fromPlainText: visibleContent)
        let displayTitle = RichContentSerializer.normalizedReferenceDisplayText(
            displayText: rawTitle,
            snapshot: visibleContent
        )
        return .reference(
            id: thought.id,
            title: displayTitle,
            preview: String(plain.prefix(40)),
            snapshot: String(plain.prefix(120)),
            dateText: Self.dateFormatter.string(from: thought.updatedAt)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
