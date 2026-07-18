//
//  SuggestionPanelViewModel.swift
//  Holo
//
//  观点模块 - 编辑器候选面板数据层
//  负责 # 标签 / @ 引用候选查询（150ms 防抖，旧任务取消防结果覆盖）
//

import Combine
import Foundation

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

    private let repository = ThoughtRepository()
    private var searchTask: Task<Void, Never>?
    private static let debounce: Duration = .milliseconds(150)

    // MARK: - 搜索

    /// 触发上下文变化时重新搜索；nil 时清空
    func search(context: EditorTriggerContext?, excludingThoughtId: UUID?) {
        searchTask?.cancel()
        guard let context else {
            items = []
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.performSearch(context: context, excludingThoughtId: excludingThoughtId)
        }
    }

    private func performSearch(context: EditorTriggerContext, excludingThoughtId: UUID?) {
        switch context {
        case .tag(_, let query):
            let tags = (try? repository.fetchTagCandidates(query: query)) ?? []
            items = tagItems(for: tags, query: query)

        case .reference(_, let query):
            let thoughts = (try? repository.fetchReferenceCandidates(
                query: query,
                excludingThoughtId: excludingThoughtId
            )) ?? []
            items = thoughts.map(referenceItem)
        }
    }

    // MARK: - 创建标签

    /// 创建不存在的标签（用于 insertTagToken 的真实 tagId）
    func createTag(path: String) -> ThoughtTag? {
        try? repository.getOrCreateTagEntity(path: path)
    }

    // MARK: - Private

    private func tagItems(for tags: [ThoughtTag], query: String) -> [Item] {
        var result: [Item] = tags.map { .tag(id: $0.id, path: $0.name) }

        let normalized = ThoughtTagNormalizer.displayPath(query)
        let queryKey = ThoughtTagNormalizer.key(normalized)
        let existsExact = tags.contains { ThoughtTagNormalizer.key($0.name) == queryKey }
        if !normalized.isEmpty, !existsExact {
            result.append(.createTag(path: normalized))
        }

        return result
    }

    private func referenceItem(for thought: Thought) -> Item {
        let plain = thought.content.replacingOccurrences(of: "\n", with: " ")
        return .reference(
            id: thought.id,
            title: thought.firstLine ?? RichContentSerializer.firstLine(fromPlainText: thought.content),
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
