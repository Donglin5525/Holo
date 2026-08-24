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

    // MARK: - 收藏

    /// 收藏总数（入口条计数）。独立于分页加载的 entries——档案只翻了前几页时
    /// 计数也不能少报。
    @Published private(set) var favoritesCount = 0

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

    /// 报告 Tab 视图树内的子页面（收藏夹）需要追问能力时取用；
    /// 未 bind（理论不可达）为 nil，追问条自动降级隐藏。
    var boundChatViewModel: ChatViewModel? { chatViewModel }

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
        async let fresh = repository.loadReportArchiveAsync(limit: pageSize, offset: 0)
        async let favorites = repository.countFavoriteReportsAsync()
        let (reports, count) = await (fresh, favorites)
        entries = reports
        favoritesCount = count
        hasLoadedOnce = true
        reachedEnd = reports.count < pageSize
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

    // MARK: - 场景筛选

    /// nil = 全部。筛选作用于非搜索态的档案展示（搜索态按关键词优先）。
    @Published var selectedScenarioFilter: ReportScenarioTag?

    /// 当前档案中实际存在的场景（按固定顺序），驱动筛选行动态出链
    var availableScenarioFilters: [ReportScenarioTag] {
        let present = Set(entries.map(\.scenarioTag))
        return ReportScenarioTag.allCases.filter { present.contains($0) && $0 != .general }
    }

    /// 筛选后的展示集（月份分组以此为准）
    var displayEntries: [ReportArchiveDTO] {
        guard let filter = selectedScenarioFilter else { return entries }
        return entries.filter { $0.scenarioTag == filter }
    }

    // MARK: - 月份分组

    /// 非搜索态的档案按月份分组（「档案越来越厚」的视觉节奏）。
    var groupedEntries: [(monthLabel: String, entries: [ReportArchiveDTO])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        var order: [String] = []
        var buckets: [String: [ReportArchiveDTO]] = [:]
        for entry in displayEntries {
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
        searchCancellable = Future { promise in
            Task { @MainActor in
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
        if entry.isFavorited {
            favoritesCount = max(0, favoritesCount - 1)
        }
        repository.deleteReportMessages(reportMessageID: entry.id)
    }

    // MARK: - 收藏

    /// 收藏/取消：界面先亮（乐观更新），再落库回填真实时间。
    /// 可逆操作不打断——无弹窗、无确认。
    func toggleFavorite(_ entry: ReportArchiveDTO) {
        let target = !entry.isFavorited
        applyFavoriteChange(messageID: entry.id, favoritedAt: target ? Date() : nil)
        let persisted = repository.setReportFavorited(target, reportMessageID: entry.id)
        applyFavoriteChange(messageID: entry.id, favoritedAt: persisted)
        favoritesCount = max(0, favoritesCount + (target ? 1 : -1))
    }

    /// 删除报告后由收藏夹侧同步计数（收藏夹删光时入口条要收起）。
    func refreshFavoritesCount() async {
        favoritesCount = await repository.countFavoriteReportsAsync()
    }

    private func applyFavoriteChange(messageID: UUID, favoritedAt: Date?) {
        if let index = entries.firstIndex(where: { $0.id == messageID }) {
            entries[index].favoritedAt = favoritedAt
        }
        if let index = searchResults.firstIndex(where: { $0.id == messageID }) {
            searchResults[index].favoritedAt = favoritedAt
        }
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
