//
//  MacSyncVerifyView.swift
//  HoloMac
//
//  Phase A 只读验证页：验证共享源码在 macOS 上可编译可运行、
//  CloudKit 可用性与想法数据（Thought/Topic/ThoughtTag）可正常读取。
//  本页不写任何数据。
//

import SwiftUI
import CoreData

struct MacSyncVerifyView: View {
    /// CloudKit 运行时可用性（静态值，启动时读一次即可）
    private let cloudKitAvailable = CloudKitRuntimeAvailability.isAvailable
    private let cloudKitEnvironment = CloudKitRuntimeAvailability.currentEnvironment?.displayName

    @State private var storeReady = false
    /// 写入验证：记录刚写入的测试想法，供「iPhone 确认收到」后一键软删清理
    @State private var testThoughtId: UUID?
    @State private var writeStatus: String?
    @State private var networkStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("CloudKit") {
                    LabeledContent("isAvailable") {
                        Text(cloudKitAvailable ? "true" : "false")
                            .foregroundStyle(cloudKitAvailable ? .green : .secondary)
                    }
                    LabeledContent("currentEnvironment") {
                        Text(cloudKitEnvironment ?? "nil（不可用/未判定）")
                    }
                }

                Section("数据规模") {
                    LabeledContent("想法（Thought，排除软删除）") {
                        StoreCountText(entityName: "Thought", excludingSoftDeleted: true, ready: storeReady)
                    }
                    LabeledContent("主题（Topic）") {
                        StoreCountText(entityName: "Topic", excludingSoftDeleted: false, ready: storeReady)
                    }
                    LabeledContent("标签（ThoughtTag）") {
                        StoreCountText(entityName: "ThoughtTag", excludingSoftDeleted: false, ready: storeReady)
                    }
                }

                Section("最近 5 条想法") {
                    RecentThoughtsList(ready: storeReady)
                }

                Section("写入验证（端到端同步）") {
                    if let testThoughtId {
                        Text("已写入测试想法，请在 iPhone 的想法列表查看（约 1 分钟内出现），确认后点下方按钮清理。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("确认 iPhone 已收到，软删测试想法") { cleanupTestThought(id: testThoughtId) }
                    } else {
                        Button("写入测试想法") { writeTestThought() }
                    }
                    if let writeStatus {
                        Text(writeStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("AI 后端连通（沙盒出站网络）") {
                    Button("测试连接 api.holoapp.cn") { testBackendConnectivity() }
                    if let networkStatus {
                        Text(networkStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Holo Mac · Phase A 验证")
            .task {
                // 与 iOS 端 HoloApp 一致：先触发容器懒加载，再等 store 就绪后刷新读取
                CoreDataStack.shared.prepareIfNeeded()
                await CoreDataStack.shared.waitUntilReady()
                storeReady = true
            }
        }
    }

    private func writeTestThought() {
        let repository = ThoughtRepository()
        let content = "【HoloMac 写入验证】\(Date.now.formatted(date: .abbreviated, time: .shortened)) —— 这条由 Mac 原生版写入，验证 iCloud 双向同步，可删除。"
        do {
            let thought = try repository.create(content: content)
            testThoughtId = thought.id
            writeStatus = "写入成功（\(thought.id.uuidString.prefix(8))…），等待 iCloud 上行…"
        } catch {
            writeStatus = "写入失败：\(error.localizedDescription)"
        }
    }

    private func cleanupTestThought(id: UUID) {
        do {
            try ThoughtRepository().delete(id)
            testThoughtId = nil
            writeStatus = "已软删测试想法（回收站可彻底清除）。"
        } catch {
            writeStatus = "清理失败：\(error.localizedDescription)"
        }
    }

    /// 沙盒出站网络实测：能收到任意 HTTP 状态码即证明 network.client 生效；
    /// 被沙盒拦截时 URLSession 会直接报错而非服务器错误。
    private func testBackendConnectivity() {
        networkStatus = "请求中…"
        var request = URLRequest(url: URL(string: "https://api.holoapp.cn/")!)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { _, response, error in
            let result: String
            if let error {
                result = "❌ 失败：\(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                result = "✅ 网络通（HTTP \(http.statusCode)）——沙盒出站网络正常"
            } else {
                result = "⚠️ 收到响应但非 HTTP"
            }
            Task { @MainActor in networkStatus = result }
        }.resume()
    }
}

/// 单实体计数行：store 就绪前显示占位，就绪后发起一次只读 FetchRequest
private struct StoreCountText: View {
    let entityName: String
    let excludingSoftDeleted: Bool
    let ready: Bool

    @State private var count: Int?

    var body: some View {
        Group {
            if let count {
                Text("\(count)")
                    .monospacedDigit()
            } else if ready {
                ProgressView()
                    .controlSize(.small)
                    .task { await refresh() }
            } else {
                Text("等待 store…").foregroundStyle(.secondary)
            }
        }
    }

    private func refresh() async {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
        if excludingSoftDeleted {
            request.predicate = NSPredicate(format: "isSoftDeleted == NO")
        }
        count = (try? context.count(for: request)) ?? 0
    }
}

/// 最近想法列表：firstLine（空则取 content 首行）+ createdAt 相对时间
private struct RecentThoughtsList: View {
    let ready: Bool

    @State private var thoughts: [Thought] = []

    var body: some View {
        Group {
            if ready {
                if thoughts.isEmpty {
                    Text("暂无想法").foregroundStyle(.secondary)
                } else {
                    ForEach(thoughts, id: \.objectID) { thought in
                        LabeledContent(titleText(of: thought)) {
                            Text(thought.createdAt, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("等待 store…").foregroundStyle(.secondary)
            }
        }
        .task(id: ready) {
            guard ready else { return }
            await refresh()
        }
    }

    private func refresh() async {
        let context = CoreDataStack.shared.viewContext
        let request = Thought.fetchRequest()
        request.predicate = NSPredicate(format: "isSoftDeleted == NO")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchLimit = 5
        thoughts = (try? context.fetch(request)) ?? []
    }

    private func titleText(of thought: Thought) -> String {
        if let firstLine = thought.firstLine, !firstLine.isEmpty {
            return firstLine
        }
        return thought.content.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? thought.content
    }
}

#Preview {
    MacSyncVerifyView()
}
