//
//  ChatReportTabView.swift
//  Holo
//
//  Holo AI 页「报告」Tab：搜索栏 + 报告档案（按月分组）/ 空态橱窗。
//  发起不在本 Tab——报告只读，发起统一回对话页（预填话术、用户自己确认发送）。
//  Tab 切换由 ChatView 的 ZStack 常驻模式承载（本视图只在首次切到时构建）。
//

import SwiftUI

struct ChatReportTabView: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    @ObservedObject var viewModel: ChatReportTabViewModel
    /// 档案行点击：按类型分流（深度分析 → 全屏报告详情；周期回放 → 全屏阅读版）。
    var onOpenEntry: (ReportArchiveDTO) -> Void
    /// 空态橱窗 CTA：切回对话 Tab 并预填发起话术（不自动发送，确认权在用户）。
    var onLaunchInChat: () -> Void

    private var isSearchMode: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)

            if isSearchMode {
                searchResultList
            } else if shouldShowEmptyState {
                ReportEmptyStateView {
                    onLaunchInChat()
                }
            } else {
                archiveList
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .confirmationDialog(
            "删除这份报告？",
            isPresented: Binding(
                get: { viewModel.pendingDeleteEntry != nil },
                set: { if !$0 { viewModel.pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除报告与对应对话", role: .destructive) {
                if let entry = viewModel.pendingDeleteEntry {
                    viewModel.deleteReport(entry)
                }
                viewModel.pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                viewModel.pendingDeleteEntry = nil
            }
        } message: {
            if let entry = viewModel.pendingDeleteEntry {
                Text("「\(entry.scopeLabel ?? "报告")」及聊天里的提问和回答都会删除，此操作不可撤销。")
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.holoTextSecondary)

            TextField("搜索提问、结论或正文", text: $viewModel.searchText)
                .font(.system(size: 13.5))
                .foregroundColor(.holoTextPrimary)
                .autocorrectionDisabled()
                .accessibilityLabel("搜索报告")

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.holoCardBackground, in: Capsule())
        .overlay(
            Capsule().stroke(Color.holoDivider.opacity(0.5), lineWidth: 0.8)
        )
    }

    // MARK: - 列表

    /// 空态判定：首屏加载完成 + 无已完成报告 + 无生成中任务 + 不在搜索态。
    private var shouldShowEmptyState: Bool {
        viewModel.hasLoadedOnce
            && viewModel.entries.isEmpty
            && viewModel.inProgressAnalysis == nil
    }

    private var archiveList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if let inProgress = viewModel.inProgressAnalysis {
                    ReportInProgressCard(message: inProgress)
                }

                if viewModel.isLoading && viewModel.entries.isEmpty {
                    ProgressView("正在翻档案…")
                        .font(.system(size: 12))
                        .padding(.vertical, 28)
                } else {
                    // 按月分组：档案有「越攒越厚」的时间节奏
                    ForEach(viewModel.groupedEntries, id: \.monthLabel) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(group.monthLabel)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.holoTextSecondary)
                                Rectangle()
                                    .fill(Color.holoDivider.opacity(0.6))
                                    .frame(height: 0.7)
                            }
                            .padding(.top, 4)

                            ForEach(group.entries) { entry in
                                archiveRow(entry)
                            }
                        }
                    }

                    if !viewModel.reachedEnd {
                        // 触底哨兵：出现即加载下一页
                        Color.clear
                            .frame(height: 1)
                            .onAppear {
                                Task { await viewModel.loadNextPage() }
                            }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var searchResultList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                if viewModel.isSearching {
                    ProgressView()
                        .padding(.vertical, 24)
                } else if viewModel.searchResults.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(.holoTextSecondary.opacity(0.6))
                        Text("没有匹配「\(viewModel.searchText)」的报告")
                            .font(.system(size: 12.5))
                            .foregroundColor(.holoTextSecondary)
                        Text("试试换个关键词：提问里的词、结论里的词都能搜到")
                            .font(.system(size: 11))
                            .foregroundColor(.holoTextSecondary.opacity(0.8))
                    }
                    .padding(.vertical, 28)
                } else {
                    Text("找到 \(viewModel.searchResults.count) 份报告")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(viewModel.searchResults) { entry in
                        archiveRow(entry)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func archiveRow(_ entry: ReportArchiveDTO) -> some View {
        ReportArchiveCard(entry: entry) {
            onOpenEntry(entry)
        }
        .contextMenu {
            Button(role: .destructive) {
                viewModel.pendingDeleteEntry = entry
            } label: {
                Label("删除报告", systemImage: "trash")
            }
        }
    }
}
