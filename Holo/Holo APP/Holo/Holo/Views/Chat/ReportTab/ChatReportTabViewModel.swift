//
//  ChatReportTabViewModel.swift
//  Holo
//
//  「报告」Tab 的数据与状态：档案列表（分页/搜索/删除）、生成中状态、红点。
//  发起不在本 Tab——报告 Tab 只读档案，发起统一走对话（胶囊或自己输入），
//  用户对自己发出的内容有确认权。
//

import Foundation
import Combine

@MainActor
final class ChatReportTabViewModel: ObservableObject {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    // MARK: - 档案

    @Published private(set) var entries: [ReportArchiveDTO] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var reachedEnd = false

    // MARK: - 搜索

    /// 搜索词；非空时列表进入搜索结果态（平铺、不分月）
    @Published var searchText: String = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var searchResults: [ReportArchiveDTO] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearchedOnce = false
    private var searchCancellable: AnyCancellable?
    private var lastExecutedSearchKeyword: String = ""

    // MARK: - 删除

    /// 待删除的报告（驱动确认弹窗）
    @Published var pendingDeleteEntry: ReportArchiveDTO?

    // MARK: - 红点

    /// 正在生成的深度分析消息。数据源是 ChatViewModel 的消息流（持久化 streaming
    /// 状态 + 冷启动恢复），实时进度由消息快照自带的 Agent 状态同步驱动——
    /// 不单独维护内存态，避免杀 App 重开后两侧不一致。
    @Published private(set) var inProgressAnalysis: ChatMessageViewData?
    /// 报告生成完成且用户尚未切到报告 Tab 时亮红点；仅本次会话有效。
    @Published private(set) var hasUnreadReport = false
    /// 报告 Tab 是否正展示在前台（完成瞬间在前台则直接刷新、不打红点）。
    var isReportTabVisible = false

    private let repository = ChatMessageRepository.shared
    private var chatViewModel: ChatViewModel?
    private var cancellables: Set<AnyCancellable> = []
    private var didBind = false
    private let pageSize = 20

    // MARK: - 绑定聊天页

    func bind(chatViewModel: ChatViewModel) {
        guard !didBind else { return }
        didBind = true
        self.chatViewModel = chatViewModel

        chatViewModel.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                guard let self else { return }
                let wasGenerating = self.inProgressAnalysis != nil
                let current = messages.last(where: { $0.isQueryAnalysis && $0.isStreaming })
                self.inProgressAnalysis = current
                // 状态机落定：生成中 → 无。仅当消息真的带回了结果才算「完成」，
                // 用户取消/失败的消息不产报告、不亮红点。
                if wasGenerating, current == nil {
                    let completed = messages.last(where: { $0.isQueryAnalysis })
                    if completed?.agentResult != nil {
                        self.hasUnreadReport = !self.isReportTabVisible
                    }
                    Task { await self.reload() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 档案加载

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let fresh = await repository.loadReportArchiveAsync(limit: pageSize, offset: 0)
        entries = fresh
        hasLoadedOnce = true
        reachedEnd = fresh.count < pageSize
    }

    /// 上滑加载下一页（由列表末项出现触发）。
    func loadNextPage() async {
        guard hasLoadedOnce, !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let more = await repository.loadReportArchiveAsync(limit: pageSize, offset: entries.count)
        reachedEnd = more.count < pageSize
        let knownIDs = Set(entries.map(\.id))
        entries += more.filter { !knownIDs.contains($0.id) }
    }

    // MARK: - 月份分组

    /// 非搜索态的档案按月份分组（「档案越来越厚」的视觉节奏）。
    var groupedEntries: [(monthLabel: String, entries: [ReportArchiveDTO])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        var order: [String] = []
        var buckets: [String: [ReportArchiveDTO]] = [:]
        for entry in entries {
            let label = formatter.string(from: entry.timestamp)
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - 搜索

    /// 防抖 300ms：停止输入后再查，避免每个字符打一次库。
    private func scheduleSearch() {
        searchCancellable?.cancel()
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchResults = []
            isSearching = false
            hasSearchedOnce = false
            lastExecutedSearchKeyword = ""
            return
        }
        searchCancellable = Future { [weak self] promise in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                promise(.success(()))
            }
        }
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.executeSearch(keyword: keyword)
            }
        }
    }

    private func executeSearch(keyword: String) async {
        guard keyword == searchText.trimmingCharacters(in: .whitespacesAndNewlines),
              keyword != lastExecutedSearchKeyword else { return }
        lastExecutedSearchKeyword = keyword
        isSearching = true
        defer { isSearching = false }
        searchResults = await repository.searchReportArchive(keyword: keyword)
        hasSearchedOnce = true
    }

    // MARK: - 删除

    /// 删除报告：档案先移除（界面先清），再删库（回答消息 + 提问气泡一起删，
    /// 仓库发布会驱动聊天页同步移除）。
    func deleteReport(_ entry: ReportArchiveDTO) {
        entries.removeAll { $0.id == entry.id }
        searchResults.removeAll { $0.id == entry.id }
        repository.deleteReportMessages(reportMessageID: entry.id)
    }

    // MARK: - 红点

    func markSeen() {
        isReportTabVisible = true
        hasUnreadReport = false
    }

    func markHidden() {
        isReportTabVisible = false
    }

    // MARK: - 详情

    /// 档案行 → 完整消息快照（含完整分析结果）。
    func loadReportMessage(id: UUID) -> ChatMessageViewData? {
        repository.loadMessageViewData(id: id)
    }
}
