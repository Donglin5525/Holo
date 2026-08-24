//
//  ReportFavoritesView.swift
//  Holo
//
//  「我的收藏」收藏夹（报告 Tab 入口条推入的全屏页）：
//  按收藏时间倒序陈列已收藏的报告，右滑取消收藏，点卡读报告。
//  深度分析报告在这里可直接追问（追问能力由 chatViewModel 提供）。
//

import SwiftUI

struct ReportFavoritesView: View {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    /// 追问能力（发送/取消/状态监听）。nil 时详情页追问条自动隐藏。
    let chatViewModel: ChatViewModel?
    /// 收藏集变化（取消收藏/删除）后同步报告 Tab 的入口条计数。
    var onFavoritesChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [ReportArchiveDTO] = []
    @State private var hasLoaded = false
    @State private var detailMessage: ChatMessageViewData?
    @State private var pendingDeleteEntry: ReportArchiveDTO?

    private let repository = ChatMessageRepository.shared

    var body: some View {
        VStack(spacing: 0) {
            navBar

            if !hasLoaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if entries.isEmpty {
                emptyState
            } else {
                favoriteList
            }
        }
        .background(Color.holoBackground.ignoresSafeArea())
        .holoEdgeSwipeBack { dismiss() }
        .task { await load() }
        .fullScreenCover(item: $detailMessage) { message in
            ReportDetailRoute(
                message: message,
                chatViewModel: chatViewModel,
                onDismiss: {
                    // 详情里可能追问出了新报告，回来刷新列表让「追问 ×N」计数准确
                    Task { await load() }
                    onFavoritesChanged()
                }
            )
        }
        .confirmationDialog(
            "删除这份报告？",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除报告与对应对话", role: .destructive) {
                if let entry = pendingDeleteEntry {
                    deleteReport(entry)
                }
                pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            if let entry = pendingDeleteEntry {
                Text("「\(entry.scopeLabel ?? "报告")」及聊天里的提问和回答都会删除，此操作不可撤销。")
            }
        }
    }

    // MARK: - 导航

    private var navBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("报告")
                        .font(.system(size: 12.5))
                }
                .foregroundColor(.holoTextSecondary)
                .frame(height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回报告")

            Spacer()

            Text("我的收藏")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Color.clear
                .frame(width: 48, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Color.holoBackground)
    }

    // MARK: - 列表

    private var favoriteList: some View {
        List {
            Text("按收藏时间排序 · 右滑可取消收藏 · 左侧边缘右滑返回")
                .font(.system(size: 11))
                .foregroundColor(.holoTextSecondary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .center)
                .reportFavoriteRowChrome()

            ForEach(entries) { entry in
                favoriteRow(entry)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func favoriteRow(_ entry: ReportArchiveDTO) -> some View {
        ReportArchiveCard(entry: entry) {
            openDetail(entry)
        }
        .reportFavoriteRowChrome()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                unfavorite(entry)
            } label: {
                Label("取消收藏", systemImage: "star.slash")
            }
            .tint(Color.holoTextSecondary)
        }
        .contextMenu {
            Button {
                unfavorite(entry)
            } label: {
                Label("取消收藏", systemImage: "star.slash")
            }
            Button(role: .destructive) {
                pendingDeleteEntry = entry
            } label: {
                Label("删除报告", systemImage: "trash")
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.holoStarTint.opacity(0.13))
                    .frame(width: 76, height: 76)
                Image(systemName: "star")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Color.holoStarTint.opacity(0.75))
            }
            .padding(.bottom, 16)

            Text("还没有收藏的报告")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.holoTextPrimary)
                .padding(.bottom, 7)

            Text("在报告列表里右滑一份好报告，\n把它收进来，随时翻出来看、接着问。")
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.bottom, 18)

            Button {
                dismiss()
            } label: {
                Text("去看看报告")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Color.holoPrimary, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 数据

    private func load() async {
        let fresh = await repository.loadFavoriteReportsAsync()
        entries = fresh
        hasLoaded = true
    }

    /// 界面先清再落库（可逆操作无弹窗）；收藏夹空了自然只剩空态。
    private func unfavorite(_ entry: ReportArchiveDTO) {
        entries.removeAll { $0.id == entry.id }
        repository.setReportFavorited(false, reportMessageID: entry.id)
        onFavoritesChanged()
    }

    /// 删除报告：与报告 Tab 同规则（报告 + 对应对话一起删，先清界面再删库）。
    private func deleteReport(_ entry: ReportArchiveDTO) {
        entries.removeAll { $0.id == entry.id }
        repository.deleteReportMessages(reportMessageID: entry.id)
        onFavoritesChanged()
    }

    private func openDetail(_ entry: ReportArchiveDTO) {
        guard let message = repository.loadMessageViewData(id: entry.id) else { return }
        detailMessage = message
    }
}

/// 收藏夹列表行的统一外观（与报告 Tab 的 reportRowChrome 同款间距）。
private extension View {
    func reportFavoriteRowChrome() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
