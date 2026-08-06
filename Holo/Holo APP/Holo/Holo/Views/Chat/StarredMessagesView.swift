//
//  StarredMessagesView.swift
//  Holo
//
//  「我的收藏」列表页
//  展示用户在对话中长按收藏的 AI 消息
//

import SwiftUI

struct StarredMessagesView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var starStore = ChatMessageStarStore.shared

    @State private var messages: [ChatMessageViewData] = []
    @State private var hasLoadedOnce = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            if messages.isEmpty && hasLoadedOnce {
                emptyStateView
                    .frame(minHeight: 420)
            } else {
                LazyVStack(spacing: HoloSpacing.sm) {
                    ForEach(messages) { message in
                        StarredMessageRow(message: message, onUnstar: { unstar(message) })
                    }
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 40)
            }
        }
        .background(Color.holoBackground)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .swipeBackToDismiss { dismiss() }
        .task(id: starStore.starredMessageIDs) {
            await loadMessages()
        }
    }

    // MARK: - 数据加载

    /// 加载收藏消息：按 id 从数据库查；查不到的（已被删除）从收藏列表清理掉，避免孤儿 ID 越积越多。
    private func loadMessages() async {
        let starredIDs = starStore.starredMessageIDs
        guard !starredIDs.isEmpty else {
            messages = []
            hasLoadedOnce = true
            return
        }

        let loaded = await ChatMessageRepository.shared.loadStarredMessages(ids: starredIDs)

        // 清理孤儿 ID：收藏了但消息已不在数据库（被删除/重新生成）。批量剔除，只触发一次刷新。
        let loadedIDs = Set(loaded.map(\.id))
        let orphans = starredIDs.subtracting(loadedIDs)
        if !orphans.isEmpty {
            starStore.prune(orphans)
        }

        // loadMessages 在 .task（MainActor）中调用，await 后仍回到主线程，可直接赋值。
        messages = loaded
        hasLoadedOnce = true
    }

    /// 取消收藏：只改 store，列表刷新交给 .task(id:) 自动驱动（store 变更即重载）。
    /// 这样 unstar 和重载不会同时改 messages，避免竞态和闪烁。
    private func unstar(_ message: ChatMessageViewData) {
        starStore.remove(message.id)
        HoloToastCenter.shared.show("已取消收藏", type: .info)
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "star")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.3))

            Text("还没有收藏内容")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)

            Text("在对话里长按 Holo 的回复，可以把有用的内容收藏到这里")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, HoloSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

// MARK: - 收藏行视图

private struct StarredMessageRow: View {

    let message: ChatMessageViewData
    let onUnstar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(alignment: .top, spacing: HoloSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoAI)
                    .frame(width: 20, height: 20)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                    if let title = cardTitle {
                        Text(title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(2)
                    }

                    Text(bodyText)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.holoPrimary)
                Text(StarredMessagesView.formatTimestamp(message.timestamp))
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary.opacity(0.7))
                Spacer()
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.lg).stroke(Color.holoBorder, lineWidth: 0.5))
        .contextMenu {
            Button(role: .destructive) {
                onUnstar()
            } label: {
                Label("取消收藏", systemImage: "star.slash")
            }
        }
    }

    /// 深度分析卡片取标题；普通文本消息返回 nil（直接展示正文）
    private var cardTitle: String? {
        guard let result = message.agentResult else { return nil }
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// 行展示正文：优先用卡片的摘要/结论，没有就用消息原文
    private var bodyText: String {
        if let result = message.agentResult {
            // 优先用「直接结论」（AI 总结的人话），其次「点题」，再退到 summary
            let candidates = [result.directAnswer, result.headline, result.summary]
            for candidate in candidates {
                let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { return text }
            }
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 时间格式化

extension StarredMessagesView {

    /// 分段时间格式（与聊天列表一致）：今天 HH:mm / 昨天 HH:mm / 今年 M月d日 HH:mm / 跨年 yyyy年M月d日 HH:mm
    static func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(timeFormatter.string(from: date))"
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return monthDayFormatter.string(from: date)
        }
        return fullDateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f
    }()
}
