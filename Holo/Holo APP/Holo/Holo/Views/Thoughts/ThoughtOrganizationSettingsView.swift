import SwiftUI
import CoreData

/// 想法模块的唯一设置入口；主题管理、标签管理与 AI 处理状态集中在此。
struct ThoughtOrganizationSettingsView: View {
    @AppStorage(ThoughtSemanticFeatureFlags.automaticKey) private var automatic = ThoughtSemanticFeatureFlags.automaticEnabled
    @AppStorage(ThoughtSemanticFeatureFlags.newTopicsKey) private var newTopics = true
    @AppStorage(ThoughtSemanticFeatureFlags.relatedKey) private var related = true
    private enum Destination: String, Identifiable {
        case topics, tags, index, clear
        var id: String { rawValue }
    }
    @State private var destination: Destination?
    @State private var stats: ThoughtSemanticStore.IndexStats?
    @State private var granted = false
    @State private var busy = false
    @State private var message: String?
    @State private var discoveryMessage: String?
    /// 成果视角计数：已归类笔记数与可见主题数（与工程视角的索引/队列数互补）
    @State private var classifiedCount = 0
    @State private var topicCount = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("AI 智能整理", isOn: $automatic)
                        .accessibilityIdentifier("thoughts.settings.automatic")
                    Toggle("自动形成新主题", isOn: $newTopics).disabled(!automatic)
                        .accessibilityIdentifier("thoughts.settings.newTopics")
                    Toggle("显示相关笔记", isOn: $related).disabled(!automatic)
                        .accessibilityIdentifier("thoughts.settings.related")
                } header: { Text("智能整理") } footer: {
                    Text("随手记录时，Holo 根据笔记内容把笔记归入已有主题，积累同一方向后自动形成新主题；这些功能默认开启，关闭后停止新的 AI 处理，已形成的主题和手动标签保留。处理时会将必要的脱敏正文和少量相关笔记交给 AI 服务核对；需要你已授予 HoloAI 数据处理授权。")
                }
                // 小屏适配：内容管理是固定高度的高频入口，必须排在会随整理数据长高的
                // 「整理状态」之前——否则数据一多它就被推到折叠线以下，静止状态下页面
                // 看起来「到此为止」，管理入口像被裁掉。
                Section("内容管理") {
                    Button("主题管理") { destination = .topics }
                    Button("标签管理") { destination = .tags }
                    Button("设备智能索引与缓存") { destination = .index }
                }
                Section("整理状态") {
                    if !automatic { Text("已关闭自动处理") }
                    else if !granted {
                        NavigationLink("授权后开始整理") { AIDataProcessingConsentView() }
                    } else if let stats {
                        LabeledContent("已归类", value: "\(classifiedCount) 条笔记 · \(topicCount) 个主题")
                        LabeledContent("整理进度", value: stats.pendingJobs + stats.runningJobs > 0
                                       ? "\(stats.pendingJobs + stats.runningJobs) 条排队中" : "全部处理完成")
                        if let last = stats.lastFinishedAt {
                            LabeledContent("最近整理", value: last.formatted(.relative(presentation: .named)))
                        } else if stats.activeItems == 0 {
                            Text("还没有开始整理，保持 App 打开会自动进行")
                                .font(.holoCaption).foregroundStyle(Color.holoTextSecondary)
                        }
                        // 等待原因只保留一条：与主题发现状态撞同一文案时去重，避免同句提示重复出现
                        if let reason = stats.waitingReason {
                            Text(ThoughtSemanticRetryPolicy.userMessage(for: reason))
                                .font(.holoCaption).foregroundStyle(Color.holoTextSecondary)
                        } else if newTopics, let discoveryMessage, discoveryMessage != ThoughtSemanticRetryPolicy.userMessage(for: stats.waitingReason ?? "") {
                            Text(discoveryMessage).font(.holoCaption).foregroundStyle(Color.holoTextSecondary)
                        }
                        Text("处理完成的笔记不一定需要归类；只有原文支持具体主题时才会归入。")
                            .font(.holoCaption).foregroundStyle(Color.holoTextSecondary)
                    } else { Text("正在准备智能整理") }
                    // 未授权/已关闭时这个按钮永远不可用，藏掉而不是灰着占一行
                    if automatic && granted {
                        Button("核对全部笔记并重试失败项") {
                            busy = true
                            Task {
                                await ThoughtSemanticPipeline.shared.bootstrap()
                                if let store = await ThoughtSemanticPipeline.shared.store { try? await store.retryFailedJobs() }
                                await ThoughtAutomaticTopicDiscovery.shared.retryNow()
                                await ThoughtSemanticChangeFeed.shared.reconcileAllThoughts()
                                await refresh()
                                message = "已排入整理队列，返回后会继续处理。"
                                busy = false
                                Task { await ThoughtSemanticPipeline.shared.kickQueue() }
                            }
                        }.disabled(busy)
                        if let message { Text(message).font(.holoCaption).foregroundStyle(Color.holoTextSecondary) }
                    }
                }
                Section {
                    Button("清理想法数据") { destination = .clear }
                } footer: { Text("清理的数据进入回收站，自动整理不会代替你删除笔记。") }
            }
            .tint(.holoPrimary)
            .navigationTitle("想法设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .holoSheetShell()
            .sheet(item: $destination) { target in
                switch target {
                case .topics: NavigationStack { TopicManagementView(topicRepository: TopicRepository(), thoughtRepository: ThoughtRepository()) }
                case .tags: ThoughtTagManagementView()
                case .index: NavigationStack { DeviceIntelligenceIndexView().holoSheetShell() }
                case .clear: ModuleClearSheet(module: .thought)
                }
            }
            .task {
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                }
            }
            .onChange(of: automatic) { _, _ in ThoughtSemanticFeatureFlags.settingsChanged(); Task { await refresh() } }
            .onChange(of: newTopics) { _, _ in ThoughtSemanticFeatureFlags.settingsChanged() }
            .onChange(of: related) { _, _ in ThoughtSemanticFeatureFlags.settingsChanged() }
        }
    }
    @MainActor private func refresh() async {
        granted = HoloAIDataProcessingConsent.shared.isGranted
        if let store = await ThoughtSemanticPipeline.shared.store { stats = try? await store.indexStats() }
        discoveryMessage = await ThoughtAutomaticTopicDiscovery.shared.statusMessage
        await refreshOutcomeCounts()
    }

    /// 成果计数（已归类笔记/可见主题）。数据量在数百条级，直接投影统计。
    @MainActor private func refreshOutcomeCounts() async {
        let context = CoreDataStack.shared.viewContext
        let (classified, topics) = await context.perform {
            let request = Thought.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil AND isArchived == NO")
            let thoughts = (try? context.fetch(request)) ?? []
            let classified = thoughts.filter {
                !ThoughtTopicLinkProjection.effectiveTopics(for: $0).filter(\.isVisibleTopic).isEmpty
            }.count
            let topicRequest = Topic.fetchRequest()
            let topics = ((try? context.fetch(topicRequest)) ?? []).filter(\.isVisibleTopic).count
            return (classified, topics)
        }
        classifiedCount = classified
        topicCount = topics
    }
}
