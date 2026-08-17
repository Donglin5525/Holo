//
//  MemoryConfirmationQueueView.swift
//  Holo
//
//  记忆确认队列 — 待确认记忆的逐条轻确认（对 / 不对 / 进详情纠正）。
//  收件箱计数与「想和你确认的」分组都指向这里，保证「待确认 N 件」有路可走。
//

import SwiftUI

struct MemoryConfirmationQueueView: View {

    /// 每处理完一条（确认/否决/纠正/删除）回调一次，调用方同步自己的列表与计数。
    var onRecordHandled: ((String) -> Void)? = nil
    /// 队列清空时回调。
    var onQueueDrained: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var records: [HoloMemoryRecord] = []
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var workingIDs: Set<String> = []
    @State private var notice: String?
    @State private var selectedRecord: HoloMemoryRecord?

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HoloSpacing.md) {
                    if !hasLoaded {
                        // 首帧占位，避免空态闪现
                        Color.clear.frame(height: 200)
                    } else if loadFailed {
                        failureCard
                    } else if records.isEmpty {
                        drainedCard
                    } else {
                        Text("Holo 从你的记录里总结出了下面这些。点「对」或「不对」就好，确认后 Holo 回答会更准。")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .padding(.horizontal, HoloSpacing.xs)

                        ForEach(records) { record in
                            confirmCard(record)
                        }
                    }
                    Spacer(minLength: HoloSpacing.xxl)
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.sm)
            }
            .background(Color.holoBackground)
            .navigationTitle(
                !hasLoaded ? "待确认" : records.isEmpty ? "都确认完了" : "待确认 \(records.count) 条"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") { dismiss() }
                        .foregroundColor(.holoPrimary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !records.isEmpty {
                        Button("稍后再说") { dismiss() }
                            .foregroundColor(.holoTextSecondary)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    MemoryNoticeToast(text: notice) { self.notice = nil }
                        .padding(.top, 8)
                }
            }
            .sheet(item: $selectedRecord) { record in
                NavigationStack {
                    HoloMemoryRecordDetailView(record: record) { change in
                        applyDetailChange(change)
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - 卡片

    private func confirmCard(_ record: HoloMemoryRecord) -> some View {
        // 外层用 onTapGesture 而不是 Button：卡片内嵌「对/不对」按钮，Button 套 Button 会让两个动作同时触发。
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Text(record.displaySummary)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .top, spacing: HoloSpacing.xs) {
                    Image(systemName: HoloMemoryUserPresentation.durationIcon(for: record))
                        .frame(width: 14, alignment: .leading)

                    Text([
                        HoloMemoryUserPresentation.durationTitle(for: record),
                        HoloMemoryUserPresentation.sourceSummary(for: record)
                    ].joined(separator: " · "))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextPlaceholder)
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedRecord = record }

            HStack(spacing: HoloSpacing.sm) {
                quickButton("对", icon: "checkmark", color: .holoSuccess) {
                    Task { await quickConfirm(record, accurate: true) }
                }
                quickButton("不对", icon: "xmark", color: .orange) {
                    Task { await quickConfirm(record, accurate: false) }
                }
            }
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder.opacity(0.45), lineWidth: 1)
        )
        .opacity(workingIDs.contains(record.id) ? 0.55 : 1)
        .disabled(workingIDs.contains(record.id))
    }

    private func quickButton(
        _ title: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.holoCaption)
                .foregroundColor(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, HoloSpacing.sm)
                .background(color.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空态与失败

    private var drainedCard: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 32))
                .foregroundColor(.holoSuccess)
            Text("都确认完了")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
            Text("Holo 回答时会带上这些记忆。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(HoloSpacing.xl)
    }

    private var failureCard: some View {
        VStack(spacing: HoloSpacing.sm) {
            Label("没有加载出来", systemImage: "exclamationmark.triangle")
                .font(.holoCaption)
                .foregroundColor(.holoTextPrimary)
            Text("你原来的记录没有丢失，可以稍后重试。")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
            Button("重新加载") { Task { await load() } }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
    }

    // MARK: - 数据

    @MainActor
    private func load() async {
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            records = try await repository.query(.all).filter {
                HoloMemoryUserVisibility.isPendingConfirmation($0)
            }
            hasLoaded = true
        } catch {
            loadFailed = true
            hasLoaded = true
        }
    }

    @MainActor
    private func quickConfirm(_ record: HoloMemoryRecord, accurate: Bool) async {
        workingIDs.insert(record.id)
        do {
            let repository = try await HoloMemoryRuntime.shared.repository()
            let service = HoloMemoryFeedbackService(store: repository)
            _ = try await service.apply(accurate ? .accurate : .inaccurate, to: record.id)
            removeRecord(record.id)
        } catch {
            notice = "这次操作没有保存成功，请稍后重试。"
        }
        workingIDs.remove(record.id)
    }

    private func applyDetailChange(_ change: HoloMemoryRecordDetailChange) {
        switch change {
        case .updated(let record):
            if HoloMemoryUserVisibility.isPendingConfirmation(record) {
                // 仍是待确认（理论上确认动作都会转移状态，防御极端版本不一致）。
                selectedRecord = record
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = record
                }
            } else {
                // 已给出结论：关掉详情，回到队列继续下一条。
                selectedRecord = nil
                removeRecord(record.id)
            }
        case .removed(let id):
            selectedRecord = nil
            removeRecord(id)
        }
    }

    private func removeRecord(_ id: String) {
        withAnimation(.easeInOut(duration: 0.25)) {
            records.removeAll { $0.id == id }
        }
        onRecordHandled?(id)
        if records.isEmpty, hasLoaded {
            onQueueDrained?()
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            }
        }
    }
}

// MARK: - 轻提示

/// 确认流程共用的顶部轻提示，几秒后自动消失。
struct MemoryNoticeToast: View {
    let text: String
    var onDismiss: () -> Void

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.holoCaption)
            .foregroundColor(.holoTextPrimary)
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
            .background(Color.holoCardBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.holoBorder.opacity(0.5), lineWidth: 1))
            .task {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                onDismiss()
            }
    }
}
